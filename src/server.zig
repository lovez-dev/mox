//! 构建在 `mox_io` 完成循环之上的 HTTP 服务。
//!
//! `std.http.Server` 围绕阻塞式 `std.Io` reader/writer 构建，
//! 与完成循环不合；因此 mox 用 `http.zig` 直接从接收缓冲解析请求，
//! 并把 accept/recv/解析/路由/发送/关闭整个流程
//! 都走侵入式 `Completion` 节点：每连接一次分配，
//! 无 future、无每连接纤程。

const std = @import("std");

const mox_io = @import("mox_io");
const http = @import("http.zig");
const router_mod = @import("router.zig");

const Route = router_mod.Route;
const Router = router_mod.Router;
const Params = types.Params;

const Loop = mox_io.Loop;
const Completion = mox_io.Completion;
const NetRecv = mox_io.NetRecv;
const NetSend = mox_io.NetSend;
const NetClose = mox_io.NetClose;
const NetAccept = mox_io.NetAccept;
const Timer = mox_io.Timer;
const Handle = mox_io.Handle;
const INVALID_HANDLE = mox_io.INVALID_HANDLE;

const types = @import("types.zig");

pub const Response = types.Response;
pub const Context = types.Context;
pub const Handler = types.Handler;
pub const Config = types.Config;

/// `Loop` 建好、监听开始之前调用的钩子：用于把编译期嵌入的静态资源
/// 挂到 `loop.memory_fs`。生成的 `embed.mount` 是泛型函数（`anytype`），
/// 不能直接当函数指针传，调用方包一层即可：
///     fn mountAll(l: *mox_io.Loop) !void { return embed.mount(l); }
///     try mox.serveWith(cfg, mountAll);
pub const MountHook = *const fn (*Loop) anyerror!void;

pub fn serve(config: Config) !void {
    return serveWith(config, null);
}

pub fn serveWith(config: Config, mount_hook: ?MountHook) !void {
    var router = try Router.init(config.gpa, config.routes);
    defer router.deinit();

    var loop = try mox_io.open(config.gpa);
    defer loop.deinit();

    if (mount_hook) |hook| try hook(&loop);

    const listener = try loop.createSocket(config.address);
    defer loop.close(listener);
    try loop.setReuseAddress(listener, true);
    try loop.bind(listener, config.address);
    try loop.listen(listener, 128);
    // 让接受完成经由本后端；必须早于第一次 AcceptEx。
    try loop.associate(listener, 0);

    var server = Server{
        .alloc = config.gpa,
        .loop = &loop,
        .router = &router,
        .address = config.address,
        .listener = listener,
        .max_conns = config.max_connections,
        .idle_timeout_ms = config.idle_timeout_ms,
        .backoff_ms = config.accept_backoff_ms,
        .max_body_size = config.max_body_size,
    };
    // 订阅停机信号（POSIX only；Windows 返回 Unsupported，comptime 跳过整段）。
    // 信号到达时回调 `onSignal` → `loop.stop()`，`loop.run()` 返回后走优雅停机段。
    const builtin = @import("builtin");
    var sig_int: ?mox_io.Signal = null;
    var sig_term: ?mox_io.Signal = null;
    if (comptime builtin.os.tag != .windows) {
        sig_int = mox_io.Signal.init(mox_io.Signals.INT) catch null;
        sig_term = mox_io.Signal.init(mox_io.Signals.TERM) catch null;
        defer if (sig_int) |*s| s.deinit();
        defer if (sig_term) |*s| s.deinit();
        if (sig_int) |*s| {
            s.work.c.callback = onSignal;
            loop.add(&s.work.c);
        }
        if (sig_term) |*s| {
            s.work.c.callback = onSignal;
            loop.add(&s.work.c);
        }
    }
    postAccept(&server);
    try loop.run();

    // ---- 优雅停机 ----
    // 1. 停止接受新连接：取消仍在飞的 accept，等它的完成包回收（`accept` 节点
    //    在栈上，必须等回收完才能让 `server` 出栈）。
    if (server.accepting) {
        loop.cancel(&server.accept.c, @ptrCast(&server), noopDispose);
        server.accepting = false;
    }
    server.shutting_down = true;

    // 2. 逐个中止在飞连接：取消在飞 recv/send、对空闲连接直接关闭。
    //    连接对象在各自的完成包回来的 `dispose`（或 `NetClose` 的 `onClose`）
    //    里释放，绝不在这里 sync 释放——否则后端可能还持有指向它的节点。
    var it = server.conns;
    while (it) |conn| {
        const next = conn.next;
        abortConn(conn);
        it = next;
    }

    // 3. 继续跑循环把收尾完成包收干净，直到所有连接释放或超时。
    loop.drainOpen(config.shutdown_timeout_ms, @ptrCast(&server), Server.allClosed);

    // 4. 兜底：accept 取消项的完成包（若第 3 步里没跑到）也要回收。
    loop.drainRetired(1000);
}

/// 取消项 / 已交出所有权后的空操作回收。
fn noopDispose(_: *anyopaque) void {}

/// SIGINT / SIGTERM 回调：停止循环，触发优雅停机。
fn onSignal(lp: *Loop, _: *Completion) void {
    lp.stop();
}

// ---- server：持有监听套接字与待完成的 accept -------------------------------

const Server = struct {
    alloc: std.mem.Allocator,
    loop: *Loop,
    router: *const Router,
    address: std.Io.net.IpAddress,
    listener: Handle,
    accept_socket: Handle = INVALID_HANDLE,
    accept: NetAccept = undefined,

    /// 并发连接上限（来自 `Config.max_connections`）。
    max_conns: usize = 1024,
    /// 当前活跃连接数。
    active_conns: usize = 0,
    /// 是否已有一个 `accept` 在飞。用布尔量代替「靠 accept 节点是否有效」，
    /// 避免重复投递同一个节点。
    accepting: bool = false,
    /// `accept` 失败退避定时器。
    backoff: Timer = undefined,
    backoff_armed: bool = false,
    backoff_ms: u32 = 50,
    /// 每连接空闲超时（毫秒）；0 = 不设。
    idle_timeout_ms: u32 = 60_000,
    /// 优雅停机进行中：不再接受新连接。
    shutting_down: bool = false,
    /// 请求体上限（字节）。来自 Config.max_body_size。0 = 不限。
    max_body_size: usize = 4 * 1024 * 1024,
    /// 活跃连接的双向链表头（侵入式，`Connection.prev/next`）。
    conns: ?*Connection = null,

    fn allClosed(ctx: *anyopaque) bool {
        const s: *Server = @ptrCast(@alignCast(ctx));
        return s.active_conns == 0;
    }
};

fn registerConn(server: *Server, conn: *Connection) void {
    conn.server = server;
    conn.prev = null;
    conn.next = server.conns;
    if (server.conns) |head| head.prev = conn;
    server.conns = conn;
    server.active_conns += 1;
}

fn unregisterConn(server: *Server, conn: *Connection) void {
    if (conn.prev) |p| p.next = conn.next else server.conns = conn.next;
    if (conn.next) |n| n.prev = conn.prev;
    conn.prev = null;
    conn.next = null;
    if (server.active_conns > 0) server.active_conns -= 1;
}

/// 投递一次 accept。三条前置条件任一不满足就**不**投：
/// - 正在停机；
/// - 已有一个 accept 在飞（防止重复投同一节点）；
/// - 连接数已达上限（停止接受形成内核 backlog 背压，而非无限吃 fd）。
///
/// 连接释放或退避到期后会再次调用本函数恢复接受。
fn postAccept(server: *Server) void {
    if (server.shutting_down or server.accepting) return;
    if (server.active_conns >= server.max_conns) return;
    server.accept_socket = server.loop.createSocket(server.address) catch {
        scheduleBackoff(server);
        return;
    };
    server.accept = NetAccept.init(server.listener, server.accept_socket);
    server.accept.c.callback = onAccept;
    server.accepting = true;
    server.loop.add(&server.accept.c);
}

/// `accept` 失败（典型 EMFILE / ENFILE）后的退避：**不能立即重试**，
/// 否则 fd 耗尽的错误持续期间会把循环线程的 CPU 打满。用一个短定时器
/// 延时后再试，期间循环照常处理已有连接。
fn scheduleBackoff(server: *Server) void {
    if (server.shutting_down or server.backoff_armed) return;
    if (server.accept_socket != INVALID_HANDLE) {
        server.loop.close(server.accept_socket);
        server.accept_socket = INVALID_HANDLE;
    }
    server.backoff = Timer.init(server.backoff_ms);
    server.backoff.c.callback = onBackoff;
    server.backoff_armed = true;
    server.loop.add(&server.backoff.c);
}

fn onBackoff(loop: *Loop, c: *Completion) void {
    _ = loop;
    const t: *Timer = @fieldParentPtr("c", c);
    const server: *Server = @fieldParentPtr("backoff", t);
    server.backoff_armed = false;
    postAccept(server);
}

fn onAccept(loop: *Loop, c: *Completion) void {
    _ = loop;
    const accept: *NetAccept = @fieldParentPtr("c", c);
    const server: *Server = @fieldParentPtr("accept", accept);
    server.accepting = false;

    const client = accept.getResult() catch {
        // EMFILE 等：退避后再试，绝不立即重投（否则忙循环）。
        if (server.accept_socket != INVALID_HANDLE) {
            server.loop.close(server.accept_socket);
            server.accept_socket = INVALID_HANDLE;
        }
        scheduleBackoff(server);
        return;
    };
    // 成功：accept_socket 的所有权已转成 client，复位避免后续误关。
    server.accept_socket = INVALID_HANDLE;

    // 理论上前置条件已挡住超限；仍再做一次防御性检查（例如上限被动态调小）。
    if (server.active_conns >= server.max_conns) {
        server.loop.close(client);
        // 不恢复 accept：等有连接关闭腾出名额。
        return;
    }

    server.loop.associate(client, 1) catch {
        server.loop.close(client);
        postAccept(server);
        return;
    };

    const conn = server.alloc.create(Connection) catch {
        server.loop.close(client);
        postAccept(server);
        return;
    };
    conn.* = .{
        .alloc = server.alloc,
        .loop = server.loop,
        .router = server.router,
        .socket = client,
    };
    registerConn(server, conn);
    postRecv(conn);

    postAccept(server); // arm the next one before we block in the loop
}

// ---- connection：recv -> 解析 -> 路由 -> send ->（keep-alive | 关闭） -------

/// 连接所处的阶段。停机时据此决定该取消哪个在飞操作。
const ConnState = enum {
    /// 建立后 / keep-alive 间隙，正在等下一个请求（`recv` 已投递）。
    receiving,
    /// 正在发送响应（`send` 已投递）。
    sending,
    /// 正在异步读取文件（`ReadFile` 的 `Work` 已投递）。
    reading_file,
    /// 同步处理中（解析 / 路由 / handler）。此时没有后端在飞 op。
    handling,
    /// 关闭进行中，等待完成包释放。
    closing,
};

const Connection = struct {
    alloc: std.mem.Allocator,
    loop: *Loop,
    router: *const Router,
    socket: Handle,
    server: ?*Server = null,

    /// 活跃连接双向链表（侵入式，由 `Server` 维护）。
    prev: ?*Connection = null,
    next: ?*Connection = null,
    state: ConnState = .handling,

    recv_buf: [8 * 1024]u8 = undefined,
    send_buf: [16 * 1024]u8 = undefined,
    recv_len: usize = 0,
    keep_alive: bool = false,

    recv: NetRecv = undefined,
    send: NetSend = undefined,
    close: NetClose = undefined,

    /// 空闲超时定时器：等请求期间到点未收到新数据即关闭。
    idle: Timer = undefined,
    idle_armed: bool = false,

    // 静态文件状态（仅在文件响应进行中使用）。
    file_work: mox_io.ReadFile = undefined,
    file_buf: []u8 = &.{},
    file_path_buf: [512]u8 = undefined,
    defer_status: std.http.Status = .ok,
    defer_ctype: []const u8 = "",
    send_owned: ?[]u8 = null,
    // 本次响应待写的完整切片，与已写入字节数：内核部分写入时靠它们续发尾部。
    send_wire: []const u8 = &.{},
    sent_len: usize = 0,
};

fn postRecv(conn: *Connection) void {
    conn.state = .receiving;
    armIdle(conn);
    conn.recv = NetRecv.init(conn.socket, conn.recv_buf[conn.recv_len..]);
    conn.recv.c.callback = onRecv;
    conn.loop.add(&conn.recv.c);
}

/// 武装空闲超时。每次进入「等请求」都重新计时（先撤旧的再上新）。
fn armIdle(conn: *Connection) void {
    const server = conn.server orelse return;
    const ms = server.idle_timeout_ms;
    if (ms == 0) return;
    disarmIdle(conn);
    conn.idle = Timer.init(ms);
    conn.idle.c.callback = onIdle;
    conn.idle_armed = true;
    conn.loop.add(&conn.idle.c);
}

/// 撤销空闲超时。定时器还在堆里，`cancel` 会把它摘除并同步回收
/// （`dispose` = 空操作，连接本身不在这里释放）。
fn disarmIdle(conn: *Connection) void {
    if (!conn.idle_armed) return;
    conn.idle_armed = false;
    conn.loop.cancel(&conn.idle.c, @ptrCast(conn), noopDispose);
}

fn onIdle(loop: *Loop, c: *Completion) void {
    _ = loop;
    const t: *Timer = @fieldParentPtr("c", c);
    const conn: *Connection = @fieldParentPtr("idle", t);
    conn.idle_armed = false; // 已从堆里弹出
    // 到点仍静默：中止连接（含取消在飞 recv）。
    abortConn(conn);
}

fn onRecv(loop: *Loop, c: *Completion) void {
    _ = loop;
    const conn: *Connection = @fieldParentPtr("recv", @as(*NetRecv, @fieldParentPtr("c", c)));
    // recv 已完成：退出「等请求」阶段，撤掉空闲计时；后续路径按需重挂。
    conn.state = .handling;
    disarmIdle(conn);

    const n = conn.recv.getResult() catch {
        destroyConn(conn);
        return;
    };
    if (n == 0) { // peer closed cleanly
        destroyConn(conn);
        return;
    }
    conn.recv_len += n;

    const max_body = if (conn.server) |s| s.max_body_size else 4 * 1024 * 1024;
    switch (http.parseWithLimit(conn.recv_buf[0..conn.recv_len], max_body)) {
        .incomplete => {
            if (conn.recv_len == conn.recv_buf.len) {
                respond(conn, .{ .status = .bad_request, .body = "request too large\n" }, false);
                return;
            }
            postRecv(conn);
        },
        .malformed => respond(conn, .{ .status = .bad_request, .body = "bad request\n" }, false),
        .body_too_large => respond(conn, .{ .status = .payload_too_large, .body = "payload too large\n" }, false),
        .request => |req| {
            if (req.chunked) {
                respond(conn, .{ .status = .not_implemented, .body = "chunked transfer not supported\n" }, false);
                return;
            }
            handleRequest(conn, req);
        },
    }
}

fn handleRequest(conn: *Connection, req: http.Request) void {
    var params: Params = .{};
    const handler = conn.router.match(req.method, req.path, &params) orelse {
        respond(conn, .{ .status = .not_found, .body = "not found\n" }, req.keep_alive);
        return;
    };

    var ctx: Context = .{ .gpa = conn.alloc, .request = &req, .params = &params, .body = req.body };
    const response = handler(&ctx) catch {
        respond(conn, .{ .status = .internal_server_error, .body = "internal error\n" }, false);
        return;
    };
    if (response.file_path.len != 0)
        serveFile(conn, response, req.keep_alive)
    else
        respond(conn, response, req.keep_alive);
}

fn serveFile(conn: *Connection, response: Response, keep_alive: bool) void {
    const owned = response.file_path_owned;
    const src = response.file_path;
    if (src.len == 0 or src.len >= conn.file_path_buf.len) {
        if (owned) conn.alloc.free(@constCast(src));
        respond(conn, .{ .status = .internal_server_error, .body = "bad file path\n" }, false);
        return;
    }
    @memcpy(conn.file_path_buf[0..src.len], src);
    const path = conn.file_path_buf[0..src.len];
    if (owned) conn.alloc.free(@constCast(src));

    const size = conn.loop.fileSize(path) catch {
        respond(conn, .{ .status = .not_found, .body = "not found\n" }, keep_alive);
        return;
    };
    conn.file_buf = conn.alloc.alloc(u8, @intCast(size)) catch {
        respond(conn, .{ .status = .internal_server_error, .body = "out of memory\n" }, false);
        return;
    };
    conn.keep_alive = keep_alive;
    conn.defer_status = response.status;
    conn.defer_ctype = response.content_type;
    conn.state = .reading_file;
    conn.file_work = mox_io.ReadFile.init(conn.loop.io, path, conn.file_buf, conn.loop.memory_fs.lookup(path));
    conn.file_work.work.c.callback = onFileRead;
    conn.loop.add(&conn.file_work.work.c);
}

fn onFileRead(loop: *Loop, c: *Completion) void {
    _ = loop;
    const w: *mox_io.Work = @fieldParentPtr("c", c);
    const conn: *Connection = @fieldParentPtr("file_work", @as(*mox_io.ReadFile, @fieldParentPtr("work", w)));
    conn.state = .handling;
    const data = conn.file_work.getResult() catch {
        conn.alloc.free(conn.file_buf);
        conn.file_buf = &.{};
        respond(conn, .{ .status = .internal_server_error, .body = "read error\n" }, false);
        return;
    };
    const wirebuf = conn.alloc.alloc(u8, data.len + 512) catch {
        conn.alloc.free(conn.file_buf);
        conn.file_buf = &.{};
        respond(conn, .{ .status = .internal_server_error, .body = "out of memory\n" }, false);
        return;
    };
    const wire = http.serialize(.{
        .status = conn.defer_status,
        .body = data,
        .content_type = conn.defer_ctype,
        .headers = &.{},
    }, conn.keep_alive, wirebuf) catch {
        conn.alloc.free(wirebuf);
        conn.alloc.free(conn.file_buf);
        conn.file_buf = &.{};
        respond(conn, .{ .status = .internal_server_error, .body = "response too large\n" }, false);
        return;
    };
    conn.alloc.free(conn.file_buf);
    conn.file_buf = &.{};
    conn.send_owned = wirebuf;
    startSend(conn, wire);
}

fn respond(conn: *Connection, response: Response, keep_alive: bool) void {
    const wire = http.serialize(.{
        .status = response.status,
        .body = response.body,
        .content_type = response.content_type,
        .headers = response.headers,
    }, keep_alive, &conn.send_buf) catch {
        // 序列化后的响应放不进每连接的缓冲区。
        const fallback = http.serialize(
            .{ .status = .internal_server_error, .body = "response too large\n", .content_type = "text/plain" },
            false,
            &conn.send_buf,
        ) catch {
            destroyConn(conn);
            return;
        };
        conn.keep_alive = false;
        startSend(conn, fallback);
        return;
    };
    conn.keep_alive = keep_alive;
    conn.send_owned = null;
    startSend(conn, wire);
}

fn startSend(conn: *Connection, wire: []const u8) void {
    conn.send_wire = wire;
    conn.sent_len = 0;
    sendPending(conn);
}

/// 投递 `send_wire` 里尚未发出的尾部。发生部分写入时由 `onSend` 反复调用，
/// 直到全部写完；每次只提交剩余字节，因此不需要额外的等待队列。
fn sendPending(conn: *Connection) void {
    conn.state = .sending;
    conn.send = NetSend.init(conn.socket, conn.send_wire[conn.sent_len..]);
    conn.send.c.callback = onSend;
    conn.loop.add(&conn.send.c);
}

fn onSend(loop: *Loop, c: *Completion) void {
    _ = loop;
    const conn: *Connection = @fieldParentPtr("send", @as(*NetSend, @fieldParentPtr("c", c)));
    conn.state = .handling;

    const n = conn.send.getResult() catch {
        releaseWire(conn);
        destroyConn(conn);
        return;
    };

    conn.sent_len += n;
    if (conn.sent_len < conn.send_wire.len) {
        // 内核只吃掉了一部分（发送缓冲已满）。这就是天然的背压信号：本轮
        // 立刻让出循环线程，等该 socket 再次可写时续发剩余字节，不丢弃。
        if (n == 0) {
            // 零进展：对端不会再来收，继续等只会空转，直接断开。
            releaseWire(conn);
            destroyConn(conn);
            return;
        }
        sendPending(conn);
        return;
    }

    releaseWire(conn);
    if (conn.keep_alive) {
        conn.recv_len = 0;
        postRecv(conn);
    } else {
        // 不再复用连接：先半关闭发送方向，让对端把响应读完再收到 FIN，
        // 直接 close 有可能在响应还在内核缓冲里时被 RST 掉。
        // 后端不提供该能力时退回原来的直接关闭，行为不退化。
        conn.loop.shutdownSend(conn.socket) catch {};
        destroyConn(conn);
    }
}

/// 一次响应的发送彻底结束（或失败）后，释放动态缓冲区并复位游标。
/// `send_buf` 是每连接内联数组，无需释放。
fn releaseWire(conn: *Connection) void {
    if (conn.send_owned) |b| {
        conn.alloc.free(b);
        conn.send_owned = null;
    }
    conn.send_wire = &.{};
    conn.sent_len = 0;
}

/// 正常关闭路径（从 recv/send 回调内调用）：此时没有别的后端在飞 op，
/// 直接投 `NetClose`（同步 close + `onClose` 释放连接）。
fn destroyConn(conn: *Connection) void {
    if (conn.state == .closing) return;
    conn.state = .closing;
    disarmIdle(conn);
    conn.close = NetClose.init(conn.socket);
    conn.close.c.callback = onClose;
    conn.loop.add(&conn.close.c);
}

/// 中止一个可能带在飞操作的连接（空闲超时 / 优雅停机用）。
///
/// **不能**在这里同步释放连接：后端可能还持有指向 `conn.recv` / `conn.send`
/// 的节点，立即 `destroy` 会造成 use-after-free。正确做法是 `cancel` 那个在飞
/// 操作、把释放在它的完成包回来时（`freeConnCtx`）做。空闲连接没有在飞 op，
/// 直接走 `destroyConn` 的同步关闭即可。
fn abortConn(conn: *Connection) void {
    if (conn.state == .closing) return;
    disarmIdle(conn);
    switch (conn.state) {
        .receiving => {
            conn.state = .closing;
            conn.loop.shutdownSend(conn.socket) catch {};
            conn.loop.cancel(&conn.recv.c, @ptrCast(conn), freeConnCtx);
        },
        .sending => {
            conn.state = .closing;
            releaseWire(conn);
            conn.loop.shutdownSend(conn.socket) catch {};
            conn.loop.cancel(&conn.send.c, @ptrCast(conn), freeConnCtx);
        },
        .reading_file => {
            // `Work` 在池线程上跑；取消后其完成项由 `invoke` 走 reclaim →
            // `freeConnCtx` 释放，绝不能在池线程还持有节点时同步释放。
            conn.state = .closing;
            conn.loop.shutdownSend(conn.socket) catch {};
            conn.loop.cancel(&conn.file_work.work.c, @ptrCast(conn), freeConnCtx);
        },
        .handling => {
            // 同步处理中调用 abort 只可能来自停机（不可能是重入回调），
            // 没有后端在飞 op，走同步关闭。
            destroyConn(conn);
        },
        .closing => {},
    }
}

/// 在飞操作被取消后，其完成包到达时执行：关掉 fd 并释放连接。
fn freeConnCtx(ctx: *anyopaque) void {
    const conn: *Connection = @ptrCast(@alignCast(ctx));
    conn.loop.close(conn.socket);
    releaseConn(conn);
}

/// 释放连接：从 Server 的活跃链表摘除、归还缓冲区与对象本身、恢复 accept。
/// 调用前必须保证该连接的 socket 已被关闭、且没有后端在飞 op 指向它。
fn releaseConn(conn: *Connection) void {
    const server = conn.server;
    if (server) |s| unregisterConn(s, conn);
    if (conn.file_buf.len != 0) conn.alloc.free(conn.file_buf);
    if (conn.send_owned) |b| conn.alloc.free(b);
    const alloc = conn.alloc;
    alloc.destroy(conn);
    // 腾出名额：若之前因容量上限停掉了 accept，这里恢复。
    if (server) |s| {
        if (!s.shutting_down) postAccept(s);
    }
}

fn onClose(loop: *Loop, c: *Completion) void {
    _ = loop;
    const conn: *Connection = @fieldParentPtr("close", @as(*NetClose, @fieldParentPtr("c", c)));
    // `NetClose` 已在后端同步 close 掉 fd，这里只需释放内存与登记。
    releaseConn(conn);
}

// ---- 部分写入（背压）回归测试 --------------------------------------------

/// 循环跑在主线程，慢读者在子线程。回环上几 KB 的响应会被内核一次性吞下，
/// 测不到部分写；因此这里用远大于两端 socket 缓冲区的载荷，逼 `send` 完成
/// 只给出部分字节数。若把返回值丢掉，客户端就会收到截断响应。
const partial = struct {
    var received: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
    var finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
    var deadline: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    /// 每 20ms 醒来看一眼慢读者是否收工，收工就退出循环。
    /// 停止必须由循环线程自己发起：跨线程翻 `running` 唤不醒 `waitBatch`。
    fn tick(loop: *Loop, c: *Completion) void {
        const t: *mox_io.Timer = @fieldParentPtr("c", c);
        if (finished.load(.acquire) or
            mox_io.platform.tickCount() >= deadline.load(.acquire))
        {
            loop.stop();
            return;
        }
        t.* = mox_io.Timer.init(20);
        t.c.callback = tick;
        loop.add(&t.c);
    }

    /// 本仓库不引入 std.Io 运行时句柄，测试里用 tickCount 轮询做毫秒等待。
    fn waitMs(ms: u64) void {
        const start = mox_io.platform.tickCount();
        while (mox_io.platform.tickCount() - start < ms) {
            std.Thread.yield() catch {};
        }
    }

    fn client(addr: std.Io.net.IpAddress, expect: usize) void {
        var total: usize = 0;
        // 任何退出路径都把结果交回主线程，并放行循环收尾。
        defer {
            received.store(total, .release);
            finished.store(true, .release);
        }

        const s = mox_io.platform.createTcpSocket(addr) catch return;
        defer mox_io.platform.closeSocket(s);
        mox_io.platform.connectSocket(s, addr) catch return;

        var buf: [64 * 1024]u8 = undefined;
        // 先只取 4 KB，然后按住不读，把服务端的发送缓冲区顶满。
        total += mox_io.platform.recvBlocking(s, buf[0..4096]) catch return;
        waitMs(200);
        while (total < expect) {
            const want = @min(buf.len, expect - total);
            const n = mox_io.platform.recvBlocking(s, buf[0..want]) catch break;
            if (n == 0) break; // 对端提前关闭：说明有字节根本没发出去
            total += n;
        }
    }
};

test "响应发生部分写入时续发剩余字节，不静默丢弃" {
    if (@import("builtin").os.tag == .windows) try mox_io.platform.startup();
    const alloc = std.heap.page_allocator;
    const payload = 32 * 1024 * 1024;

    const bind_addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const listener = try mox_io.platform.createTcpSocket(bind_addr);
    defer mox_io.platform.closeSocket(listener);
    try mox_io.platform.setReuseAddress(listener, true);
    try mox_io.platform.bindSocket(listener, bind_addr);
    const bound = try mox_io.platform.localAddress(listener);
    try mox_io.platform.listenSocket(listener, 8);

    // 连接由子线程自己建立，主线程只 accept。若主线程也 connect，就会存在
    // 两条连接，数据全发到没人读的那条上，慢读者将永久等待。
    partial.received.store(0, .release);
    partial.finished.store(false, .release);
    partial.deadline.store(mox_io.platform.tickCount() + 30_000, .release);

    const t = try std.Thread.spawn(.{}, partial.client, .{ bound, payload });
    defer t.join();

    const accepted = try mox_io.platform.acceptSocket(listener);
    defer mox_io.platform.closeSocket(accepted.socket);

    var loop = try mox_io.open(alloc);
    defer loop.deinit();

    var router = try Router.init(alloc, &.{});
    defer router.deinit();

    const conn = try alloc.create(Connection);
    conn.* = .{ .alloc = alloc, .loop = &loop, .router = &router, .socket = accepted.socket };
    try loop.associate(accepted.socket, 1);

    // 载荷远超每连接内联缓冲区，走动态缓冲区路径（发完由 releaseWire 释放）。
    const wire = try alloc.alloc(u8, payload);
    @memset(wire, 'x');
    conn.send_owned = wire;
    conn.keep_alive = false;
    startSend(conn, wire);

    var heartbeat = mox_io.Timer.init(20);
    heartbeat.c.callback = partial.tick;
    loop.add(&heartbeat.c);

    try loop.run();

    try std.testing.expectEqual(payload, partial.received.load(.acquire));
}

// 静态路由 + 内存文件端到端：挂载一个磁盘上不存在的路径，走完整的
// recv → 解析 → 路由 → serveFile → ReadFile → send 链路。
// 这条测试也是 `serveFile` 把 `memory_fs.lookup(path)` 传给 `ReadFile.init`
// 的接线证据：若那里被改回 `null`，本测试会因 FileNotFound 而变红。
test "静态路由命中内存文件时不触碰磁盘" {
    if (@import("builtin").os.tag == .windows) try mox_io.platform.startup();
    const alloc = std.heap.page_allocator;

    const vfs_path = "/virtual/does-not-exist-on-disk.html";
    const vfs_body = "<h1>from memory</h1>";

    const S = struct {
        var received: [4096]u8 = undefined;
        var received_len: usize = 0;
        var done: std.atomic.Value(bool) = .init(false);

        fn handler(ctx: *Context) !Response {
            _ = ctx;
            return .{ .file_path = vfs_path, .content_type = "text/html" };
        }

        fn client(addr: std.Io.net.IpAddress) void {
            const s = mox_io.platform.createTcpSocket(addr) catch return;
            defer mox_io.platform.closeSocket(s);
            mox_io.platform.connectSocket(s, addr) catch return;
            const req = "GET /asset HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
            _ = mox_io.platform.sendBlocking(s, req) catch return;
            var n: usize = 0;
            while (n < received.len) {
                const got = mox_io.platform.recvBlocking(s, received[n..]) catch break;
                if (got == 0) break;
                n += got;
            }
            received_len = n;
            done.store(true, .release);
        }

        fn tick(loop: *Loop, c: *Completion) void {
            const t: *mox_io.Timer = @fieldParentPtr("c", c);
            if (done.load(.acquire)) {
                loop.stop();
                return;
            }
            // 原地重新武装同一个节点；新建栈上 Timer 会让 completion 悬空。
            t.* = mox_io.Timer.init(20);
            t.c.callback = tick;
            loop.add(&t.c);
        }
    };

    const bind_addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const listener = try mox_io.platform.createTcpSocket(bind_addr);
    defer mox_io.platform.closeSocket(listener);
    try mox_io.platform.setReuseAddress(listener, true);
    try mox_io.platform.bindSocket(listener, bind_addr);
    const bound = try mox_io.platform.localAddress(listener);
    try mox_io.platform.listenSocket(listener, 8);

    S.done.store(false, .release);
    S.received_len = 0;
    const t = try std.Thread.spawn(.{}, S.client, .{bound});
    defer t.join();

    const accepted = try mox_io.platform.acceptSocket(listener);
    defer mox_io.platform.closeSocket(accepted.socket);

    var loop = try mox_io.open(alloc);
    defer loop.deinit();
    try loop.associate(accepted.socket, 1);
    try loop.mountMemory(vfs_path, vfs_body);

    var router = try Router.init(alloc, &.{
        .{ .method = .GET, .path = "/asset", .handler = S.handler },
    });
    defer router.deinit();

    const conn = try alloc.create(Connection);
    conn.* = .{ .alloc = alloc, .loop = &loop, .router = &router, .socket = accepted.socket };
    postRecv(conn);

    var heartbeat = mox_io.Timer.init(20);
    heartbeat.c.callback = S.tick;
    loop.add(&heartbeat.c);

    try loop.run();

    const wire = S.received[0..S.received_len];
    try std.testing.expect(std.mem.indexOf(u8, wire, "200") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, vfs_body) != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "text/html") != null);
}

// `serveWith` 的挂载钩子必须在 `loop.run()` 之前被调用，且能改写
// memory_fs。钩子提交一个短定时器，由它在 run 内部 stop，无需网络连接。
test "serveWith 在启动前调用 VFS 挂载钩子" {
    if (@import("builtin").os.tag == .windows) try mox_io.platform.startup();

    const Ctx = struct {
        var called: usize = 0;
        var mounted: bool = false;
        var timer: mox_io.Timer = undefined;

        fn hook(loop: *Loop) anyerror!void {
            called += 1;
            try loop.mountMemory("/probe.txt", "embedded");
            mounted = loop.memory_fs.lookup("/probe.txt") != null;
            // run() 会重置 running，所以 stop 必须由 run 内部的回调触发。
            timer = mox_io.Timer.init(10);
            timer.c.callback = onTick;
            loop.add(&timer.c);
        }
        fn onTick(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    };

    try serveWith(.{
        .gpa = std.heap.page_allocator,
        .address = try std.Io.net.IpAddress.parse("127.0.0.1", 0),
        .routes = &.{},
    }, Ctx.hook);

    try std.testing.expectEqual(@as(usize, 1), Ctx.called);
    try std.testing.expect(Ctx.mounted);
}

// ---- 生产可用性回归：连接上限、空闲超时、优雅停机 -------------------------

/// 绑定一个本地监听套接字，返回 (listener, bound_addr)。
fn testListen() !struct { Handle, std.Io.net.IpAddress } {
    if (@import("builtin").os.tag == .windows) try mox_io.platform.startup();
    const bind_addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const listener = try mox_io.platform.createTcpSocket(bind_addr);
    try mox_io.platform.setReuseAddress(listener, true);
    try mox_io.platform.bindSocket(listener, bind_addr);
    const bound = try mox_io.platform.localAddress(listener);
    try mox_io.platform.listenSocket(listener, 8);
    return .{ listener, bound };
}

test "连接数达上限时停止 accept（内核 backlog 背压）" {
    const alloc = std.heap.page_allocator;
    const l = try testListen();
    const listener = l[0];
    const bound = l[1];
    defer mox_io.platform.closeSocket(listener);

    var loop = try mox_io.open(alloc);
    defer loop.deinit();
    var router = try Router.init(alloc, &.{});
    defer router.deinit();

    var srv = Server{
        .alloc = alloc,
        .loop = &loop,
        .router = &router,
        .address = bound,
        .listener = listener,
        .max_conns = 1,
    };
    // 已达上限：postAccept 必须不投递（否则无限制吃 fd）。
    srv.active_conns = 1;
    postAccept(&srv);
    try std.testing.expect(!srv.accepting);

    // 腾出名额：恢复正常接受。
    srv.active_conns = 0;
    postAccept(&srv);
    try std.testing.expect(srv.accepting);

    // 收尾：取消在飞的 accept，回收其完成包，关掉预备 socket。
    loop.cancel(&srv.accept.c, @ptrCast(&srv), noopDispose);
    srv.accepting = false;
    loop.drainRetired(500);
    if (srv.accept_socket != INVALID_HANDLE) loop.close(srv.accept_socket);
}

test "空闲超时关闭静默连接" {
    const alloc = std.heap.page_allocator;
    const l = try testListen();
    const listener = l[0];
    const bound = l[1];
    defer mox_io.platform.closeSocket(listener);

    const H = struct {
        var done: std.atomic.Value(bool) = .init(false);
        var deadline: u64 = 0;
        fn client(addr: std.Io.net.IpAddress) void {
            const s = mox_io.platform.createTcpSocket(addr) catch return;
            defer mox_io.platform.closeSocket(s);
            mox_io.platform.connectSocket(s, addr) catch return;
            // 连接建立后不发任何数据，直到主线程收工。
            while (!done.load(.acquire)) std.Thread.yield() catch {};
        }
        fn tick(loop: *Loop, c: *Completion) void {
            const t: *Timer = @fieldParentPtr("c", c);
            if (mox_io.platform.tickCount() >= deadline) {
                loop.stop();
                return;
            }
            t.* = Timer.init(20);
            t.c.callback = tick;
            loop.add(&t.c);
        }
    };
    H.done.store(false, .release);
    const cli = try std.Thread.spawn(.{}, H.client, .{bound});

    const accepted = try mox_io.platform.acceptSocket(listener);
    // accepted.socket 交给 Connection 持有，由它负责关闭，勿在此重复关。

    var loop = try mox_io.open(alloc);
    defer loop.deinit();
    try loop.associate(accepted.socket, 1);
    var router = try Router.init(alloc, &.{});
    defer router.deinit();

    var srv = Server{
        .alloc = alloc,
        .loop = &loop,
        .router = &router,
        .address = bound,
        .listener = listener,
        .idle_timeout_ms = 100, // 100ms 无数据即关闭
    };
    const conn = try alloc.create(Connection);
    conn.* = .{ .alloc = alloc, .loop = &loop, .router = &router, .socket = accepted.socket };
    registerConn(&srv, conn);
    postRecv(conn);

    var hb = Timer.init(20);
    hb.c.callback = H.tick;
    H.deadline = mox_io.platform.tickCount() + 900; // 远大于 idle 超时
    loop.add(&hb.c);
    try loop.run();

    H.done.store(true, .release);
    cli.join();

    if (srv.accepting) {
        loop.cancel(&srv.accept.c, @ptrCast(&srv), noopDispose);
        srv.accepting = false;
    }
    loop.drainRetired(500);
    if (srv.accept_socket != INVALID_HANDLE) loop.close(srv.accept_socket);

    // 关键断言：静默连接已被空闲超时释放（若 idle 失效则仍挂在这里）。
    try std.testing.expectEqual(@as(usize, 0), srv.active_conns);
}

test "drainOpen 停机后关闭在飞连接并回收内存" {
    const alloc = std.heap.page_allocator;
    const l = try testListen();
    const listener = l[0];
    const bound = l[1];
    defer mox_io.platform.closeSocket(listener);

    const H = struct {
        var done: std.atomic.Value(bool) = .init(false);
        fn client(addr: std.Io.net.IpAddress) void {
            const s = mox_io.platform.createTcpSocket(addr) catch return;
            defer mox_io.platform.closeSocket(s);
            mox_io.platform.connectSocket(s, addr) catch return;
            while (!done.load(.acquire)) std.Thread.yield() catch {};
        }
    };
    H.done.store(false, .release);
    const cli = try std.Thread.spawn(.{}, H.client, .{bound});
    const accepted = try mox_io.platform.acceptSocket(listener);

    var loop = try mox_io.open(alloc);
    defer loop.deinit();
    try loop.associate(accepted.socket, 1);
    var router = try Router.init(alloc, &.{});
    defer router.deinit();

    var srv = Server{
        .alloc = alloc,
        .loop = &loop,
        .router = &router,
        .address = bound,
        .listener = listener,
        .idle_timeout_ms = 0, // 关掉 idle，专测 drainOpen
        .shutting_down = true, // 模拟已进入停机：不恢复 accept
    };
    const conn = try alloc.create(Connection);
    conn.* = .{ .alloc = alloc, .loop = &loop, .router = &router, .socket = accepted.socket };
    registerConn(&srv, conn);
    postRecv(conn);

    // 模拟停机：中止在飞连接，再驱动循环把收尾完成包跑完。
    abortConn(conn);
    loop.drainOpen(2000, @ptrCast(&srv), Server.allClosed);
    try std.testing.expectEqual(@as(usize, 0), srv.active_conns);

    H.done.store(true, .release);
    cli.join();
}
