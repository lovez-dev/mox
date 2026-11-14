//! 服务与连接生命周期、HTTP 请求调度。协议模块共用同一连接及回收路径。
const std = @import("std");
const websocket = @import("websocket.zig");
const sse = @import("sse.zig");
const file_response = @import("file_response.zig");
const metrics = @import("metrics.zig");

const mox_io = @import("mox_io");
const http = @import("../http.zig");
const router_mod = @import("../router.zig");

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

const types = @import("../types.zig");

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

    const listener = try loop.io.createSocket(config.address);
    defer loop.io.close(listener);
    try loop.io.setReuseAddress(listener, true);
    try loop.io.bind(listener, config.address);
    try loop.io.listen(listener, 128);
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
        .request_timeout_ms = config.request_timeout_ms,
        .error_handler = config.error_handler,
        .not_found_handler = config.not_found,
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
pub fn noopDispose(_: *anyopaque) void {}

/// SIGINT / SIGTERM 回调：停止循环，触发优雅停机。
fn onSignal(lp: *Loop, _: *Completion) void {
    lp.stop();
}

// ---- server：持有监听套接字与待完成的 accept -------------------------------

pub const Server = struct {
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
    /// 单次请求最长处理时间（毫秒）。来自 Config.request_timeout_ms。0 = 不限。
    request_timeout_ms: u32 = 30_000,
    /// handler 返回错误时的兜底响应。
    error_handler: types.ErrorHandler = types.defaultErrorHandler,
    /// 路由未命中时的兜底响应。
    not_found_handler: types.Handler = types.defaultNotFound,
    /// 活跃连接的双向链表头（侵入式，`Connection.prev/next`）。
    conns: ?*Connection = null,

    pub fn allClosed(ctx: *anyopaque) bool {
        const s: *Server = @ptrCast(@alignCast(ctx));
        return s.active_conns == 0;
    }
};

// ---- 活跃连接登记 --------------------------------------------------------
pub fn registerConn(server: *Server, conn: *Connection) void {
    conn.server = server;
    conn.prev = null;
    conn.next = server.conns;
    if (server.conns) |head| head.prev = conn;
    server.conns = conn;
    server.active_conns += 1;
    metrics.connectionOpened();
}

fn unregisterConn(server: *Server, conn: *Connection) void {
    if (conn.prev) |p| p.next = conn.next else server.conns = conn.next;
    if (conn.next) |n| n.prev = conn.prev;
    conn.prev = null;
    conn.next = null;
    if (server.active_conns > 0) server.active_conns -= 1;
    metrics.connectionClosed();
}

/// 投递一次 accept。三条前置条件任一不满足就**不**投：
/// - 正在停机；
/// - 已有一个 accept 在飞（防止重复投同一节点）；
/// - 连接数已达上限（停止接受形成内核 backlog 背压，而非无限吃 fd）。
///
/// 连接释放或退避到期后会再次调用本函数恢复接受。
pub fn postAccept(server: *Server) void {
    if (server.shutting_down or server.accepting) return;
    if (server.active_conns >= server.max_conns) return;
    server.accept_socket = server.loop.io.createSocket(server.address) catch {
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
        server.loop.io.close(server.accept_socket);
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
            server.loop.io.close(server.accept_socket);
            server.accept_socket = INVALID_HANDLE;
        }
        scheduleBackoff(server);
        return;
    };
    // 成功：accept_socket 的所有权已转成 client，复位避免后续误关。
    server.accept_socket = INVALID_HANDLE;

    // 理论上前置条件已挡住超限；仍再做一次防御性检查（例如上限被动态调小）。
    if (server.active_conns >= server.max_conns) {
        server.loop.io.close(client);
        // 不恢复 accept：等有连接关闭腾出名额。
        return;
    }

    server.loop.associate(client, 1) catch {
        server.loop.io.close(client);
        postAccept(server);
        return;
    };

    const conn = server.alloc.create(Connection) catch {
        server.loop.io.close(client);
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
    /// WebSocket 升级后，正在收/发 WS 帧。
    ws,
    /// SSE 流式推送中（send 在飞或等待 handler 写入）。
    sse,
    /// 关闭进行中，等待完成包释放。
    closing,
};

pub const Connection = struct {
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
    /// 当前请求是否为 HEAD：响应照常生成头部（含真实 content-length），
    /// 但 `respond()` / `onFileRead()` 不写出 body 字节。
    head_only: bool = false,
    /// 当前请求在 recv_buf 中占用的字节数（HTTP pipelining 用）。
    /// 响应发完后按它前移剩余字节，继续解析下一个请求。
    consumed: usize = 0,
    /// chunked 请求体解码结果（由 conn.alloc 分配）。null 表示本次请求
    /// 不是 chunked，或已释放。响应发完后由 releaseWire 释放。
    chunked_body: ?[]u8 = null,
    /// chunked 请求的原始字节累积区（含头部）。因为 chunked body 可以远超
    /// 8 KB 的 recv_buf，必须跨多次 recv 累积到堆上再解码。
    /// `chunked_head_len` 是头部（含结尾空行）的长度，body 从这里开始。
    chunked_accum: std.ArrayList(u8) = .empty,
    chunked_head_len: usize = 0,
    /// continueChunked 是否已经把 recv_buf 的增量追加过（避免首轮重复追加）。
    chunked_appended: bool = false,
    /// 解析出的 chunked 请求（头部信息），body 稍后由解码结果填充。
    pending_chunked_req: http.Request = undefined,
    /// chunked 请求头部块的稳定拷贝（recv_buf 会被后续 recv 覆写）。
    chunked_head_copy: ?[]u8 = null,

    /// 每请求 arena：handler 通过 ctx.gpa 分配的内存在此统一回收。
    /// 惰性创建，keep-alive 下每个请求开始时 reset（retain_capacity 复用大块）。
    arena: ?std.heap.ArenaAllocator = null,

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
    /// 请求超时定时器：handler 执行期间到点则强制关闭连接。
    req_timeout: Timer = undefined,
    req_timeout_armed: bool = false,

    // ---- WebSocket 状态 ----
    /// WS 握手后的回调 handler（由 Response.ws_handler 传入）。
    ws_handler: ?types.WsHandler = null,
    /// WS 接收缓冲区（独立于 HTTP recv_buf，帧解码用）。
    ws_recv_buf: [4096]u8 = undefined,
    /// WS 当前已收到的字节数。
    ws_recv_len: usize = 0,
    /// WS 发送缓冲区（帧编码用）。
    ws_send_buf: [4096]u8 = undefined,

    // ---- SSE 状态 ----
    /// SSE handler（由 Response.sse_handler 传入）。
    sse_handler: ?types.SseHandler = null,
    /// SSE 发送缓冲区。
    sse_send_buf: [4096]u8 = undefined,
    /// 自动 pump 周期（毫秒）。0 = 关闭，由 handler 用 writer.setTick 调整。
    sse_tick_ms: u32 = 1000,
    /// 每连接独占的 tick 定时器节点（原地重新武装，不能在栈上新建）。
    sse_tick: Timer = undefined,
    sse_tick_armed: bool = false,
};

pub fn postRecv(conn: *Connection) void {
    conn.state = .receiving;
    armIdle(conn);
    // chunked 累积模式下，recv_buf 只当「新增字节」的暂存区：累积区已存了
    // 之前收到的全部字节，所以每次都从缓冲区起点写，读到的就是纯增量。
    const off: usize = if (conn.chunked_head_len > 0) 0 else conn.recv_len;
    conn.recv = NetRecv.init(conn.socket, conn.recv_buf[off..]);
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
pub fn disarmIdle(conn: *Connection) void {
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

/// 武装请求超时计时器。handler 执行期间到点则强制关闭连接。
fn armRequestTimeout(conn: *Connection, ms: u32) void {
    disarmRequestTimeout(conn);
    conn.req_timeout = Timer.init(ms);
    conn.req_timeout.c.callback = onRequestTimeout;
    conn.req_timeout_armed = true;
    conn.loop.add(&conn.req_timeout.c);
}

/// 撤销请求超时计时器。
pub fn disarmRequestTimeout(conn: *Connection) void {
    if (!conn.req_timeout_armed) return;
    conn.req_timeout_armed = false;
    conn.loop.cancel(&conn.req_timeout.c, @ptrCast(conn), noopDispose);
}

fn onRequestTimeout(loop: *Loop, c: *Completion) void {
    _ = loop;
    const t: *Timer = @fieldParentPtr("c", c);
    const conn: *Connection = @fieldParentPtr("req_timeout", t);
    conn.req_timeout_armed = false;
    // 请求处理超时：中止连接（含取消在飞 recv/send）。
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
    // chunked 累积模式下 recv_buf 只装本次增量（累积区已存了之前的字节），
    // 所以是覆盖而不是追加。
    if (conn.chunked_head_len > 0) {
        conn.recv_len = n;
    } else {
        conn.recv_len += n;
    }
    tryParseAndHandle(conn);
}

/// 从 `conn.recv_buf[0..recv_len]` 尝试解析并处理一个请求。
///
/// HTTP pipelining：客户端可能在一个 TCP 段里塞多个请求。处理完一个后
/// 由 `onSend`（发送彻底结束、`send_buf` 可安全复用）调回这里继续解析
/// 缓冲区里剩下的字节，而不是像以前那样直接 `recv_len = 0` 丢掉。
fn tryParseAndHandle(conn: *Connection) void {
    const max_body = if (conn.server) |s| s.max_body_size else 4 * 1024 * 1024;
    // chunked 累积模式：recv_buf 里只有本次新增的 body 字节，头部已在
    // 累积区里解析过了。直接追加增量并重试解码，不再重新解析头部。
    if (conn.chunked_head_len > 0) {
        continueChunked(conn, max_body);
        return;
    }
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
                // chunked 请求体是流式的：`parse` 只确认了头部，body 还没解出来。
                startChunked(conn, req, max_body);
                return;
            }
            // 记下本请求占用的字节数；handleRequest 异步完成，剩余字节
            // 要等响应发完才能安全处理（否则会覆写 send_buf）。
            conn.consumed = req.consumed;
            handleRequest(conn, req);
        },
    }
}

/// chunked 请求的第一步：把已收到的字节（头部 + 可能的部分 body）搬进
/// 累积区，然后尝试解码。body 可以远超 8 KB 的 recv_buf，所以必须累积。
fn startChunked(conn: *Connection, req: http.Request, max_body: usize) void {
    const body_start = @intFromPtr(req.body.ptr) - @intFromPtr(conn.recv_buf[0..].ptr);
    conn.chunked_head_len = body_start;
    conn.chunked_accum.clearRetainingCapacity();
    conn.chunked_accum.appendSlice(conn.alloc, conn.recv_buf[0..conn.recv_len]) catch {
        respond(conn, .{ .status = .internal_server_error, .body = "out of memory\n" }, false);
        return;
    };
    // 关键：req 的 path/target 指向 recv_buf，而累积模式下后续 recv 每轮都从
    // recv_buf 起点覆写。大 body 场景下路径会被后到的字节盖掉，导致路由匹配
    // 失败（实测：20000 字节请求体时 handler 根本没被调用）。
    // 把头部拷到一块稳定内存，再按偏移量重建 path/target/head 切片。
    const head_copy = conn.alloc.dupe(u8, req.head) catch {
        respond(conn, .{ .status = .internal_server_error, .body = "out of memory\n" }, false);
        return;
    };
    conn.chunked_head_copy = head_copy;
    const base = @intFromPtr(req.head.ptr);
    var req2 = req;
    // target/path 都是 head 内部的切片，按偏移量重建。
    req2.target = head_copy[@intFromPtr(req.target.ptr) - base ..][0..req.target.len];
    req2.path = head_copy[@intFromPtr(req.path.ptr) - base ..][0..req.path.len];
    req2.head = head_copy;
    conn.pending_chunked_req = req2;
    continueChunked(conn, max_body);
}

/// chunked 请求的后续步骤：把 recv_buf 里的增量追加进累积区并重试解码。
/// 由 `startChunked` 与后续 `onRecv` 调用。
fn continueChunked(conn: *Connection, max_body: usize) void {
    // 首次调用时 recv_buf 的内容已由 startChunked 搬过；后续调用才是纯增量。
    // 用 `chunked_appended` 区分，避免首轮重复追加。
    if (conn.chunked_appended) {
        conn.chunked_accum.appendSlice(conn.alloc, conn.recv_buf[0..conn.recv_len]) catch {
            respond(conn, .{ .status = .internal_server_error, .body = "out of memory\n" }, false);
            return;
        };
    }
    conn.chunked_appended = true;

    const accum = conn.chunked_accum.items;
    switch (http.decodeChunked(conn.alloc, accum[conn.chunked_head_len..], max_body)) {
        .incomplete => {
            // 累积区远超上限还没凑够完整请求 → 拒绝，避免无限增长。
            if (accum.len > max_body + conn.chunked_head_len + 1024) {
                respond(conn, .{ .status = .payload_too_large, .body = "payload too large\n" }, false);
                return;
            }
            // 继续收：新字节写进 recv_buf，下一轮 onRecv 追加进累积区。
            postRecv(conn);
        },
        .malformed => respond(conn, .{ .status = .bad_request, .body = "bad chunked encoding\n" }, false),
        .body_too_large => respond(conn, .{ .status = .payload_too_large, .body = "payload too large\n" }, false),
        .done => |d| {
            conn.chunked_body = d.body;
            // 请求在累积区里占用的总字节数（用于 pipelining 前移）。
            conn.consumed = conn.chunked_head_len + d.consumed;
            // recv_buf 里的字节已全部搬进累积区，没有剩余可前移。
            conn.recv_len = 0;
            var full_req = conn.pending_chunked_req;
            full_req.body = d.body;
            full_req.consumed = 0;
            handleRequest(conn, full_req);
        },
    }
}

/// 把缓冲区里剩下的字节（pipelining 的后续请求）前移覆盖已消费部分。
fn shiftRemaining(conn: *Connection) void {
    const used = @min(conn.consumed, conn.recv_len);
    const remaining = conn.recv_len - used;
    if (remaining > 0) {
        std.mem.copyForwards(u8, conn.recv_buf[0..remaining], conn.recv_buf[used..conn.recv_len]);
    }
    conn.recv_len = remaining;
    conn.consumed = 0;
}

fn handleRequest(conn: *Connection, req: http.Request) void {
    // 每个请求开始：重置上一请求的 arena（保留容量复用），并让 ctx.gpa 指向它。
    // 修复 problem()/metricsHandler()/setCookieHeader()/示例 allocPrint 等通过
    // ctx.gpa 分配却从未释放的请求级内存泄漏。
    if (conn.arena) |*a| {
        _ = a.reset(.retain_capacity);
    } else {
        conn.arena = std.heap.ArenaAllocator.init(conn.alloc);
    }
    const req_alloc = conn.arena.?.allocator();
    // 获取 Server 指针（测试中直连 Connection 时为 null，降级为默认行为）。
    // req_alloc 覆盖 handler 与 respond()：后者同步把 body/headers 拷进 send_buf，
    // 因此下次请求 reset arena 时，上一响应的数据已不再被引用。
    const srv = conn.server;
    // 武装请求超时计时器（如果配置了的话）
    if (srv) |s| {
        if (s.request_timeout_ms > 0) armRequestTimeout(conn, s.request_timeout_ms);
    }

    // HEAD 请求：路由回退到 GET handler（见 router.entryAt），响应只发头部。
    conn.head_only = req.method == .HEAD;

    // 全局请求计数
    metrics.requestStarted();
    var params: Params = .{};
    const handler = conn.router.match(req.method, req.path, &params) orelse {
        // 路由未命中：调用可自定义的 not_found handler
        var ctx: Context = .{ .gpa = req_alloc, .request = &req, .params = &params, .body = req.body };
        const nf_resp = if (srv) |s|
            s.not_found_handler(&ctx) catch Response{ .status = .not_found, .body = "not found\n" }
        else
            Response{ .status = .not_found, .body = "not found\n" };
        disarmRequestTimeout(conn);
        respond(conn, nf_resp, req.keep_alive);
        return;
    };

    var ctx: Context = .{ .gpa = req_alloc, .request = &req, .params = &params, .body = req.body };
    const response = handler(&ctx) catch |err| {
        // handler 出错：调用可自定义的 error_handler
        disarmRequestTimeout(conn);
        metrics.requestFailed();
        const err_resp = if (srv) |s|
            s.error_handler(&ctx, err)
        else
            Response{ .status = .internal_server_error, .body = @errorName(err) };
        respond(conn, err_resp, false);
        return;
    };
    disarmRequestTimeout(conn);
    if (response.ws_handler) |wsh| {
        websocket.upgrade(conn, &req, wsh);
    } else if (response.sse_handler) |sseh| {
        sse.start(conn, &req, sseh);
    } else if (response.file_path.len != 0) {
        file_response.serve(conn, response, req.keep_alive);
    } else {
        respond(conn, response, req.keep_alive);
    }
}

// ---- HTTP 响应发送与背压 -------------------------------------------------

pub fn respond(conn: *Connection, response: Response, keep_alive: bool) void {
    const wire = http.serialize(.{
        .status = response.status,
        .body = response.body,
        .content_type = response.content_type,
        .headers = response.headers,
    }, keep_alive, conn.head_only, &conn.send_buf) catch |err| {
        // NoSpaceLeft：响应放不下每连接缓冲。
        // InvalidHeader：头名/头值含 CRLF，可能是注入尝试；绝不写出该响应，
        // 统一回一个干净的 500（不回显攻击内容）。
        const msg: []const u8 = switch (err) {
            error.InvalidHeader => "invalid response header\n",
            error.NoSpaceLeft => "response too large\n",
        };
        const fallback = http.serialize(
            .{ .status = .internal_server_error, .body = msg, .content_type = "text/plain" },
            false,
            conn.head_only,
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

pub fn startSend(conn: *Connection, wire: []const u8) void {
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
        // pipelining：本次响应已彻底发完，send_buf 可安全复用。
        // 先把已消费的字节移出缓冲区，若还剩完整请求就接着处理，
        // 否则重新挂 recv 等下一批数据。
        shiftRemaining(conn);
        if (conn.recv_len > 0) {
            tryParseAndHandle(conn);
        } else {
            postRecv(conn);
        }
    } else {
        // 不再复用连接：先半关闭发送方向，让对端把响应读完再收到 FIN，
        // 直接 close 有可能在响应还在内核缓冲里时被 RST 掉。
        // 后端不提供该能力时退回原来的直接关闭，行为不退化。
        conn.loop.io.shutdownSend(conn.socket) catch {};
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
    // chunked 解码出的 body 与本次请求同生命周期，响应发完即释放。
    if (conn.chunked_body) |b| {
        conn.alloc.free(b);
        conn.chunked_body = null;
    }
    if (conn.chunked_head_copy) |h| {
        conn.alloc.free(h);
        conn.chunked_head_copy = null;
    }
    // 累积区与累积状态复位（内存保留复用，下次 chunked 请求 clear 即可）。
    conn.chunked_accum.clearRetainingCapacity();
    conn.chunked_head_len = 0;
    conn.chunked_appended = false;
    conn.send_wire = &.{};
    conn.sent_len = 0;
}

/// 正常关闭路径（从 recv/send 回调内调用）：此时没有别的后端在飞 op，
/// 直接投 `NetClose`（同步 close + `onClose` 释放连接）。
pub fn destroyConn(conn: *Connection) void {
    if (conn.state == .closing) return;
    conn.state = .closing;
    disarmIdle(conn);
    disarmRequestTimeout(conn);
    sse.disarmTick(conn); // SSE tick 到点回调不能再触碰正在关闭的连接
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
pub fn abortConn(conn: *Connection) void {
    if (conn.state == .closing) return;
    disarmIdle(conn);
    switch (conn.state) {
        .receiving => {
            conn.state = .closing;
            conn.loop.io.shutdownSend(conn.socket) catch {};
            conn.loop.cancel(&conn.recv.c, @ptrCast(conn), freeConnCtx);
        },
        .sending => {
            conn.state = .closing;
            releaseWire(conn);
            conn.loop.io.shutdownSend(conn.socket) catch {};
            conn.loop.cancel(&conn.send.c, @ptrCast(conn), freeConnCtx);
        },
        .reading_file => {
            // `Work` 在池线程上跑；取消后其完成项由 `invoke` 走 reclaim →
            // `freeConnCtx` 释放，绝不能在池线程还持有节点时同步释放。
            conn.state = .closing;
            conn.loop.io.shutdownSend(conn.socket) catch {};
            conn.loop.cancel(&conn.file_work.work.c, @ptrCast(conn), freeConnCtx);
        },
        .handling => {
            // 同步处理中调用 abort 只可能来自停机（不可能是重入回调），
            // 没有后端在飞 op，走同步关闭。
            destroyConn(conn);
        },
        .ws => {
            // WS 状态：recv 在飞，取消它即可
            conn.state = .closing;
            conn.loop.io.shutdownSend(conn.socket) catch {};
            conn.loop.cancel(&conn.recv.c, @ptrCast(conn), freeConnCtx);
        },
        .sse => {
            // SSE 状态：可能挂着 tick 定时器（已由 destroyConn 撤销），
            // 没有在飞 recv；若恰好在 send 中则交给 sending 分支处理。
            destroyConn(conn);
        },
        .closing => {},
    }
}

/// 在飞操作被取消后，其完成包到达时执行：关掉 fd 并释放连接。
fn freeConnCtx(ctx: *anyopaque) void {
    const conn: *Connection = @ptrCast(@alignCast(ctx));
    conn.loop.io.close(conn.socket);
    releaseConn(conn);
}

/// 释放连接：从 Server 的活跃链表摘除、归还缓冲区与对象本身、恢复 accept。
/// 调用前必须保证该连接的 socket 已被关闭、且没有后端在飞 op 指向它。
fn releaseConn(conn: *Connection) void {
    // 兜底：任何绕过 destroyConn 的释放路径都不能留下在飞 tick 定时器。
    sse.disarmTick(conn);
    const server = conn.server;
    if (server) |s| unregisterConn(s, conn);
    if (conn.file_buf.len != 0) conn.alloc.free(conn.file_buf);
    if (conn.send_owned) |b| conn.alloc.free(b);
    // chunked 累积区是堆上的动态数组，必须显式释放。
    conn.chunked_accum.deinit(conn.alloc);
    if (conn.chunked_body) |b| conn.alloc.free(b);
    if (conn.chunked_head_copy) |h| conn.alloc.free(h);
    if (conn.arena) |*a| a.deinit();
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
