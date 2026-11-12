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
    /// 单次请求最长处理时间（毫秒）。来自 Config.request_timeout_ms。0 = 不限。
    request_timeout_ms: u32 = 30_000,
    /// handler 返回错误时的兜底响应。
    error_handler: types.ErrorHandler = types.defaultErrorHandler,
    /// 路由未命中时的兜底响应。
    not_found_handler: types.Handler = types.defaultNotFound,
    /// 活跃连接的双向链表头（侵入式，`Connection.prev/next`）。
    conns: ?*Connection = null,

    fn allClosed(ctx: *anyopaque) bool {
        const s: *Server = @ptrCast(@alignCast(ctx));
        return s.active_conns == 0;
    }
};

// ============================================================================
// 全局请求指标（原子计数器，单节点内存统计）
// ============================================================================
/// 总请求数（所有连接累计）
var metrics_total_requests = std.atomic.Value(u64).init(0);
/// 总错误数（handler 返回错误 + not_found 兜底算作 4xx，不计入）
var metrics_total_errors = std.atomic.Value(u64).init(0);
/// 当前活跃连接数（register/unregister 同步）
var metrics_active_conns = std.atomic.Value(u64).init(0);

/// 读取当前指标快照（非事务性，各字段独立 load）。
pub const Metrics = struct {
    total_requests: u64,
    total_errors: u64,
    active_conns: u64,
};
pub fn getMetrics() Metrics {
    return .{
        .total_requests = metrics_total_requests.load(.monotonic),
        .total_errors = metrics_total_errors.load(.monotonic),
        .active_conns = metrics_active_conns.load(.monotonic),
    };
}

/// 可直接注册为路由 handler 的指标端点。
/// 返回 JSON：{"total_requests":N,"total_errors":N,"active_conns":N}
pub fn metricsHandler(ctx: *types.Context) anyerror!types.Response {
    const m = getMetrics();
    const body = try std.fmt.allocPrint(
        ctx.gpa,
        "{{\"total_requests\":{d},\"total_errors\":{d},\"active_conns\":{d}}}",
        .{ m.total_requests, m.total_errors, m.active_conns },
    );
    return .{ .body = body, .content_type = "application/json" };
}


fn registerConn(server: *Server, conn: *Connection) void {
    conn.server = server;
    conn.prev = null;
    conn.next = server.conns;
    if (server.conns) |head| head.prev = conn;
    server.conns = conn;
    server.active_conns += 1;
    _ = metrics_active_conns.fetchAdd(1, .monotonic);
}

fn unregisterConn(server: *Server, conn: *Connection) void {
    if (conn.prev) |p| p.next = conn.next else server.conns = conn.next;
    if (conn.next) |n| n.prev = conn.prev;
    conn.prev = null;
    conn.next = null;
    if (server.active_conns > 0) server.active_conns -= 1;
    _ = metrics_active_conns.fetchSub(1, .monotonic);
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
    /// WebSocket 升级后，正在收/发 WS 帧。
    ws,
    /// SSE 流式推送中（send 在飞或等待 handler 写入）。
    sse,
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

/// 武装请求超时计时器。handler 执行期间到点则强制关闭连接。
fn armRequestTimeout(conn: *Connection, ms: u32) void {
    disarmRequestTimeout(conn);
    conn.req_timeout = Timer.init(ms);
    conn.req_timeout.c.callback = onRequestTimeout;
    conn.req_timeout_armed = true;
    conn.loop.add(&conn.req_timeout.c);
}

/// 撤销请求超时计时器。
fn disarmRequestTimeout(conn: *Connection) void {
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

    // 全局请求计数
    _ = metrics_total_requests.fetchAdd(1, .monotonic);
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
        _ = metrics_total_errors.fetchAdd(1, .monotonic);
        const err_resp = if (srv) |s|
            s.error_handler(&ctx, err)
        else
            Response{ .status = .internal_server_error, .body = @errorName(err) };
        respond(conn, err_resp, false);
        return;
    };
    disarmRequestTimeout(conn);
    if (response.ws_handler) |wsh| {
        wsUpgrade(conn, &req, wsh);
    } else if (response.sse_handler) |sseh| {
        sseStart(conn, &req, sseh);
    } else if (response.file_path.len != 0) {
        serveFile(conn, response, req.keep_alive);
    } else {
        respond(conn, response, req.keep_alive);
    }
}


// ============================================================================
// WebSocket 实现
// ============================================================================

/// WebSocket 握手魔数（RFC 6455 §1.3）。
const WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
/// 101 Switching Protocols 响应模板（固定头，不经过 respond 路径）。
const WS_HANDSHAKE_HEAD =
    "HTTP/1.1 101 Switching Protocols\r\n" ++
    "Upgrade: websocket\r\n" ++
    "Connection: Upgrade\r\n" ++
    "Sec-WebSocket-Accept: ";

/// 接受到 WebSocket 升级请求：验证头、计算 Accept、发 101、转为 ws 状态。
fn wsUpgrade(conn: *Connection, req: *const http.Request, handler: types.WsHandler) void {
    // 检查必要头部
    const key = req.header("sec-websocket-key") orelse {
        respond(conn, .{ .status = .bad_request, .body = "missing Sec-WebSocket-Key\n" }, false);
        return;
    };
    const upgrade_hdr = req.header("upgrade") orelse "";
    if (!std.ascii.eqlIgnoreCase(upgrade_hdr, "websocket")) {
        respond(conn, .{ .status = .bad_request, .body = "not a WebSocket upgrade\n" }, false);
        return;
    }

    // 计算 Sec-WebSocket-Accept = Base64(SHA1(key + MAGIC))
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key);
    sha.update(WS_MAGIC);
    var digest: [20]u8 = undefined;
    sha.final(&digest);

    var accept_buf: [32]u8 = undefined; // ceil(20/3)*4 = 28 bytes + 保余
    const accept = std.base64.standard.Encoder.encode(&accept_buf, &digest);

    // 组装 101 响应
    var hsbuf: [256]u8 = undefined;
    const hs = std.fmt.bufPrint(&hsbuf, "{s}{s}\r\n\r\n", .{ WS_HANDSHAKE_HEAD, accept }) catch {
        respond(conn, .{ .status = .internal_server_error, .body = "ws handshake too large\n" }, false);
        return;
    };

    // 切换状态并保存 handler
    conn.ws_handler = handler;
    conn.ws_recv_len = 0;
    conn.state = .ws;
    disarmIdle(conn);

    // 把握手响应复制到 send_owned 缓冲发出
    const wire = conn.alloc.dupe(u8, hs) catch {
        respond(conn, .{ .status = .internal_server_error, .body = "out of memory\n" }, false);
        return;
    };
    conn.send_owned = wire;
    // 101 发完后 onSend → wsPostHandshake（不再走 HTTP keep-alive 路径）
    conn.keep_alive = false; // 标记：onSend 不 postRecv
    conn.send_wire = wire;
    conn.sent_len = 0;
    conn.send = NetSend.init(conn.socket, wire);
    conn.send.c.callback = wsOnHandshakeSent;
    conn.loop.add(&conn.send.c);
}

/// 101 握手发完后，立刻投递 WS 帧 recv。
fn wsOnHandshakeSent(loop: *Loop, c: *Completion) void {
    _ = loop;
    const conn: *Connection = @fieldParentPtr("send", @as(*NetSend, @fieldParentPtr("c", c)));
    if (conn.send_owned) |b| { conn.alloc.free(b); conn.send_owned = null; }
    conn.send_wire = &.{};
    conn.sent_len = 0;
    if (conn.send.getResult()) |_| {} else |_| { destroyConn(conn); return; }
    wsPostRecv(conn);
}

/// 投递 WS 帧 recv（持续接收）。
fn wsPostRecv(conn: *Connection) void {
    conn.state = .ws;
    conn.recv = NetRecv.init(conn.socket, conn.ws_recv_buf[conn.ws_recv_len..]);
    conn.recv.c.callback = wsOnRecv;
    conn.loop.add(&conn.recv.c);
}

/// WS 帧数据到达：解析并派发给 ws_handler。
fn wsOnRecv(loop: *Loop, c: *Completion) void {
    _ = loop;
    const conn: *Connection = @fieldParentPtr("recv", @as(*NetRecv, @fieldParentPtr("c", c)));
    const n = conn.recv.getResult() catch {
        destroyConn(conn);
        return;
    };
    if (n == 0) { destroyConn(conn); return; }
    conn.ws_recv_len += n;

    var pos: usize = 0;
    while (true) {
        const buf = conn.ws_recv_buf[0..conn.ws_recv_len];
        // 最小帧头 2 字节
        if (buf.len - pos < 2) break;
        const b0 = buf[pos];
        const b1 = buf[pos + 1];
        // final = b0 >> 7, opcode = b0 & 0xf
        const opcode: types.WsOpcode = @enumFromInt(b0 & 0x0f);
        const masked = (b1 & 0x80) != 0;
        var payload_len: usize = b1 & 0x7f;
        var hdr_len: usize = 2;
        if (payload_len == 126) {
            if (buf.len - pos < 4) break;
            payload_len = std.mem.readInt(u16, buf[pos + 2 ..][0..2], .big);
            hdr_len = 4;
        } else if (payload_len == 127) {
            if (buf.len - pos < 10) break;
            payload_len = @intCast(std.mem.readInt(u64, buf[pos + 2 ..][0..8], .big));
            hdr_len = 10;
        }
        const mask_len: usize = if (masked) 4 else 0;
        const total = hdr_len + mask_len + payload_len;
        if (buf.len - pos < total) break;
        // 解掩码（原地）
        const payload = buf[pos + hdr_len + mask_len ..][0..payload_len];
        if (masked) {
            const mask = buf[pos + hdr_len ..][0..4];
            for (payload, 0..) |*byte, i| byte.* ^= mask[i % 4];
        }
        const msg = types.WsMessage{ .opcode = opcode, .data = payload };
        // 调用 ws_handler
        if (conn.ws_handler) |wsh| {
            const ws_conn = types.WsConn{ .ptr = conn, .vtable = &ws_vtable };
            wsh(ws_conn, msg);
        }
        // close 帧：关连接
        if (opcode == .close) { destroyConn(conn); return; }
        pos += total;
    }

    // 把未处理的字节移到头部
    const remaining = conn.ws_recv_len - pos;
    if (pos > 0 and remaining > 0) {
        std.mem.copyForwards(u8, conn.ws_recv_buf[0..remaining], conn.ws_recv_buf[pos..conn.ws_recv_len]);
    }
    conn.ws_recv_len = remaining;

    if (conn.state == .ws) wsPostRecv(conn);
}

/// WsVtable 实现：发送帧。
fn wsSend(ptr: *anyopaque, opcode: types.WsOpcode, data: []const u8) void {
    const conn: *Connection = @ptrCast(@alignCast(ptr));
    if (conn.state != .ws) return;
    // 编码帧到 ws_send_buf（服务端不加掩码）
    var buf = &conn.ws_send_buf;
    var hdr_len: usize = 2;
    buf[0] = 0x80 | @intFromEnum(opcode); // FIN + opcode
    if (data.len < 126) {
        buf[1] = @intCast(data.len);
    } else if (data.len < 65536) {
        buf[1] = 126;
        std.mem.writeInt(u16, buf[2..4], @intCast(data.len), .big);
        hdr_len = 4;
    } else {
        buf[1] = 127;
        std.mem.writeInt(u64, buf[2..10], @intCast(data.len), .big);
        hdr_len = 10;
    }
    const total = hdr_len + data.len;
    if (total > buf.len) return; // 超缓冲区：静默丢弃（生产应分片）
    @memcpy(buf[hdr_len..][0..data.len], data);
    // 同步发送（WS 帧发送走同一 conn.send / startSend 路径）
    // 为简化：先用 send_owned 路径（alloc 分配，onSend 释放，发完后继续 wsPostRecv）
    const wire = conn.alloc.dupe(u8, buf[0..total]) catch return;
    conn.send_owned = wire;
    conn.send_wire = wire;
    conn.sent_len = 0;
    conn.send = NetSend.init(conn.socket, wire);
    conn.send.c.callback = wsOnFrameSent;
    conn.loop.add(&conn.send.c);
}

fn wsOnFrameSent(loop: *Loop, c: *Completion) void {
    _ = loop;
    const conn: *Connection = @fieldParentPtr("send", @as(*NetSend, @fieldParentPtr("c", c)));
    if (conn.send_owned) |b| { conn.alloc.free(b); conn.send_owned = null; }
    conn.send_wire = &.{};
    conn.sent_len = 0;
    _ = conn.send.getResult() catch { destroyConn(conn); return; };
    // 发完后不重新 recv（recv 已在飞），什么都不做。
}

/// WsVtable 实现：发 close 帧并销毁连接。
fn wsClose(ptr: *anyopaque) void {
    const conn: *Connection = @ptrCast(@alignCast(ptr));
    destroyConn(conn);
}

const ws_vtable = types.WsVtable{
    .send = wsSend,
    .close = wsClose,
};

// ============================================================================
// SSE 实现
// ============================================================================

/// SSE 响应头（Content-Type + no-cache + keep-alive）。
const SSE_HEADERS =
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Type: text/event-stream; charset=utf-8\r\n" ++
    "Cache-Control: no-cache\r\n" ++
    "Connection: keep-alive\r\n" ++
    "X-Accel-Buffering: no\r\n" ++
    "\r\n";

/// 开启 SSE 流：发 SSE 头，然后进入 SSE 推送循环。
fn sseStart(conn: *Connection, req: *const http.Request, handler: types.SseHandler) void {
    _ = req;
    conn.sse_handler = handler;
    conn.sse_tick_ms = 1000;
    conn.sse_tick_armed = false;
    conn.state = .sse;
    disarmIdle(conn);
    disarmRequestTimeout(conn); // SSE 是长连接，不能被单次请求超时打断

    const wire = conn.alloc.dupe(u8, SSE_HEADERS) catch {
        respond(conn, .{ .status = .internal_server_error, .body = "out of memory\n" }, false);
        return;
    };
    conn.send_owned = wire;
    conn.send_wire = wire;
    conn.sent_len = 0;
    conn.send = NetSend.init(conn.socket, wire);
    conn.send.c.callback = sseOnHeadersSent;
    conn.loop.add(&conn.send.c);
}
fn sseOnHeadersSent(loop: *Loop, c: *Completion) void {
    _ = loop;
    const conn: *Connection = @fieldParentPtr("send", @as(*NetSend, @fieldParentPtr("c", c)));
    if (conn.send_owned) |b| { conn.alloc.free(b); conn.send_owned = null; }
    conn.send_wire = &.{};
    _ = conn.send.getResult() catch { destroyConn(conn); return; };
    conn.state = .sse;
    ssePump(conn);
}

/// 撤销 SSE tick 定时器。定时器还在堆里时 `Loop.cancel` 会同步摘除并回收，
/// 不会留下指向已释放 conn 的完成包；`noopDispose` 不触碰连接对象。
fn disarmSseTick(conn: *Connection) void {
    if (!conn.sse_tick_armed) return;
    conn.sse_tick_armed = false;
    conn.loop.cancel(&conn.sse_tick.c, @ptrCast(conn), noopDispose);
}

/// 武装一次 SSE tick：原地复用每连接的 `sse_tick` 节点（栈上新建会悬空）。
fn armSseTick(conn: *Connection) void {
    if (conn.sse_tick_ms == 0) return;
    disarmSseTick(conn);
    conn.sse_tick = Timer.init(conn.sse_tick_ms);
    conn.sse_tick.c.callback = onSseTick;
    conn.sse_tick_armed = true;
    conn.loop.add(&conn.sse_tick.c);
}

/// tick 到点：重新 pump 一次 handler。
fn onSseTick(loop: *Loop, c: *Completion) void {
    _ = loop;
    const t: *Timer = @fieldParentPtr("c", c);
    const conn: *Connection = @fieldParentPtr("sse_tick", t);
    conn.sse_tick_armed = false; // 已从定时器堆弹出
    if (conn.state != .sse or conn.sse_handler == null) {
        destroyConn(conn);
        return;
    }
    ssePump(conn);
}

/// 调用一次 sse_handler，并按结果安排下一步：
/// - 返回 false：结束流（若 send 在飞则延迟到发送完成再关）。
/// - 返回 true 且本次调用了 writer.send()：由 sseOnEventSent 重新 pump。
/// - 返回 true 且本次没有 send：武装 tick 定时器，到点重新 pump。
fn ssePump(conn: *Connection) void {
    disarmSseTick(conn); // 每次 pump 先撤掉上一轮可能残留的 tick
    if (conn.sse_handler == null or conn.state != .sse) {
        if (conn.state != .closing) destroyConn(conn);
        return;
    }
    const writer = types.SseWriter{ .ptr = conn, .vtable = &sse_vtable };
    // 记录调用前的状态：send 会把 state 改成 .sending。
    const state_before = conn.state;
    const keep_going = conn.sse_handler.?(writer);
    if (!keep_going) {
        if (conn.state == state_before) {
            // 没有发送在飞：立即关
            destroyConn(conn);
        } else {
            // send 在飞：清 handler，sseOnEventSent 看到 null 后关闭。
            conn.sse_handler = null;
        }
        return;
    }
    if (conn.state == .sse) {
        // handler 返回 true 但本次没有 send：靠 tick 定时器驱动下一次。
        armSseTick(conn);
    }
    // 否则 send 在飞，由 sseOnEventSent 驱动下一次 pump。
}

/// SseVtable 实现：推送一个 event。
fn sseSend(ptr: *anyopaque, event: []const u8, data: []const u8) void {
    const conn: *Connection = @ptrCast(@alignCast(ptr));
    if (conn.state != .sse) return;
    // 本次 pump 内已有 send 提交，撤销可能存在的 tick（到点回调会重复 pump）。
    disarmSseTick(conn);
    // 格式：event: <name>\r\ndata: <data>\r\n\r\n
    // 若 event 为空只写 data: 行
    var buf = &conn.sse_send_buf;
    var n: usize = 0;
    if (event.len > 0) {
        const s = std.fmt.bufPrint(buf[n..], "event: {s}\r\n", .{event}) catch return;
        n += s.len;
    }
    const s2 = std.fmt.bufPrint(buf[n..], "data: {s}\r\n\r\n", .{data}) catch return;
    n += s2.len;

    const wire = conn.alloc.dupe(u8, buf[0..n]) catch return;
    conn.send_owned = wire;
    conn.send_wire = wire;
    conn.sent_len = 0;
    conn.state = .sending;
    conn.send = NetSend.init(conn.socket, wire);
    conn.send.c.callback = sseOnEventSent;
    conn.loop.add(&conn.send.c);
}

fn sseOnEventSent(loop: *Loop, c: *Completion) void {
    _ = loop;
    const conn: *Connection = @fieldParentPtr("send", @as(*NetSend, @fieldParentPtr("c", c)));
    if (conn.send_owned) |b| { conn.alloc.free(b); conn.send_owned = null; }
    conn.send_wire = &.{};
    _ = conn.send.getResult() catch { disarmSseTick(conn); destroyConn(conn); return; };
    conn.state = .sse;
    if (conn.sse_handler == null) { disarmSseTick(conn); destroyConn(conn); return; }
    ssePump(conn);
}

fn sseSetTick(ptr: *anyopaque, interval_ms: u32) void {
    const conn: *Connection = @ptrCast(@alignCast(ptr));
    conn.sse_tick_ms = interval_ms;
    // 若当前正挂着一个 tick，用新周期立即重挂，避免旧周期再触发一次。
    if (conn.sse_tick_armed) armSseTick(conn);
}

fn sseClose(ptr: *anyopaque) void {
    const conn: *Connection = @ptrCast(@alignCast(ptr));
    disarmSseTick(conn);
    if (conn.state == .sending) {
        // 发送在飞，推迟到 sseOnEventSent
        conn.sse_handler = null;
    } else {
        destroyConn(conn);
    }
}

const sse_vtable = types.SseVtable{
    .send = sseSend,
    .set_tick = sseSetTick,
    .close = sseClose,
};

fn serveFile(conn: *Connection, response: Response, keep_alive: bool) void {
    // file_path 若由 handler 用 ctx.gpa 分配，已由每请求 arena 统一回收；
    // 这里只复制到内联缓冲，不做 free（避免把 arena 内存交还给底层分配器）。
    const src = response.file_path;
    if (src.len == 0 or src.len >= conn.file_path_buf.len) {
        respond(conn, .{ .status = .internal_server_error, .body = "bad file path\n" }, false);
        return;
    }
    @memcpy(conn.file_path_buf[0..src.len], src);
    const path = conn.file_path_buf[0..src.len];

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
    disarmRequestTimeout(conn);
    disarmSseTick(conn); // SSE tick 到点回调不能再触碰正在关闭的连接
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
        .ws => {
            // WS 状态：recv 在飞，取消它即可
            conn.state = .closing;
            conn.loop.shutdownSend(conn.socket) catch {};
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
    conn.loop.close(conn.socket);
    releaseConn(conn);
}

/// 释放连接：从 Server 的活跃链表摘除、归还缓冲区与对象本身、恢复 accept。
/// 调用前必须保证该连接的 socket 已被关闭、且没有后端在飞 op 指向它。
fn releaseConn(conn: *Connection) void {
    // 兜底：任何绕过 destroyConn 的释放路径都不能留下在飞 tick 定时器。
    disarmSseTick(conn);
    const server = conn.server;
    if (server) |s| unregisterConn(s, conn);
    if (conn.file_buf.len != 0) conn.alloc.free(conn.file_buf);
    if (conn.send_owned) |b| conn.alloc.free(b);
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

// ============================================================================
// WebSocket / SSE / metrics 测试
// ============================================================================

/// 提取握手 Accept 计算，供测试和 wsUpgrade 共用。
fn wsComputeAccept(key: []const u8, out: *[32]u8) []const u8 {
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key);
    sha.update(WS_MAGIC);
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    return std.base64.standard.Encoder.encode(out, &digest);
}

test "WS 握手 Accept 值符合 RFC 6455 §1.3 测试向量" {
    // RFC 6455 §1.3 规定的标准测试向量
    // key = "dGhlIHNhbXBsZSBub25jZQ==" → accept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    var buf: [32]u8 = undefined;
    const accept = wsComputeAccept("dGhlIHNhbXBsZSBub25jZQ==", &buf);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept);
}

test "WS 完整握手：客户端发 Upgrade 请求，服务端回 101 + 正确 Accept" {
    if (@import("builtin").os.tag == .windows) try mox_io.platform.startup();
    const alloc = std.heap.page_allocator;

    const S = struct {
        var got: [1024]u8 = undefined;
        var got_len: usize = 0;
        var done: std.atomic.Value(bool) = .init(false);

        fn wsHandler(_: types.WsConn, _: types.WsMessage) void {}

        fn handler(ctx: *Context) !Response {
            _ = ctx;
            return Response.upgrade(wsHandler);
        }

        fn client(addr: std.Io.net.IpAddress) void {
            const s = mox_io.platform.createTcpSocket(addr) catch return;
            defer mox_io.platform.closeSocket(s);
            mox_io.platform.connectSocket(s, addr) catch return;
            const req =
                "GET /ws HTTP/1.1\r\n" ++
                "Host: localhost\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
                "Sec-WebSocket-Version: 13\r\n" ++
                "\r\n";
            _ = mox_io.platform.sendBlocking(s, req) catch return;
            var n: usize = 0;
            while (n < got.len) {
                const r = mox_io.platform.recvBlocking(s, got[n..]) catch break;
                if (r == 0) break;
                n += r;
                // 收到 "\r\n\r\n" 结尾即可
                if (std.mem.indexOf(u8, got[0..n], "\r\n\r\n") != null) break;
            }
            got_len = n;
            done.store(true, .release);
        }

        fn tick(loop: *Loop, c: *Completion) void {
            const t: *mox_io.Timer = @fieldParentPtr("c", c);
            if (done.load(.acquire)) { loop.stop(); return; }
            t.* = mox_io.Timer.init(20);
            t.c.callback = tick;
            loop.add(&t.c);
        }
    };

    const l = try testListen();
    const listener = l[0];
    const bound = l[1];
    defer mox_io.platform.closeSocket(listener);
    S.done.store(false, .release);
    S.got_len = 0;

    const cli = try std.Thread.spawn(.{}, S.client, .{bound});
    defer cli.join();

    const accepted = try mox_io.platform.acceptSocket(listener);
    defer mox_io.platform.closeSocket(accepted.socket);

    var loop = try mox_io.open(alloc);
    defer loop.deinit();
    try loop.associate(accepted.socket, 1);

    var router = try Router.init(alloc, &.{
        .{ .method = .GET, .path = "/ws", .handler = S.handler },
    });
    defer router.deinit();

    const conn = try alloc.create(Connection);
    conn.* = .{ .alloc = alloc, .loop = &loop, .router = &router, .socket = accepted.socket };
    postRecv(conn);

    var hb = mox_io.Timer.init(20);
    hb.c.callback = S.tick;
    loop.add(&hb.c);
    try loop.run();

    const resp = S.got[0..S.got_len];
    try std.testing.expect(std.mem.indexOf(u8, resp, "101") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Upgrade: websocket") != null);
}

test "SSE 响应头包含 text/event-stream 且推送首条事件" {
    if (@import("builtin").os.tag == .windows) try mox_io.platform.startup();
    const alloc = std.heap.page_allocator;

    const S = struct {
        var got: [2048]u8 = undefined;
        var got_len: usize = 0;
        var done: std.atomic.Value(bool) = .init(false);

        fn sseHandler(w: types.SseWriter) bool {
            w.send("msg", "hello-sse");
            w.close();
            return false;
        }
        fn handler(ctx: *Context) !Response {
            _ = ctx;
            return Response.sse(sseHandler);
        }
        fn client(addr: std.Io.net.IpAddress) void {
            const s = mox_io.platform.createTcpSocket(addr) catch return;
            defer mox_io.platform.closeSocket(s);
            mox_io.platform.connectSocket(s, addr) catch return;
            const req = "GET /events HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
            _ = mox_io.platform.sendBlocking(s, req) catch return;
            var n: usize = 0;
            while (n < got.len) {
                const r = mox_io.platform.recvBlocking(s, got[n..]) catch break;
                if (r == 0) break;
                n += r;
                if (std.mem.indexOf(u8, got[0..n], "hello-sse") != null) break;
            }
            got_len = n;
            done.store(true, .release);
        }
        fn tick(loop: *Loop, c: *Completion) void {
            const t: *mox_io.Timer = @fieldParentPtr("c", c);
            if (done.load(.acquire)) { loop.stop(); return; }
            t.* = mox_io.Timer.init(20);
            t.c.callback = tick;
            loop.add(&t.c);
        }
    };

    const l = try testListen();
    const listener = l[0];
    const bound = l[1];
    defer mox_io.platform.closeSocket(listener);
    S.done.store(false, .release);
    S.got_len = 0;

    const cli = try std.Thread.spawn(.{}, S.client, .{bound});
    defer cli.join();

    const accepted = try mox_io.platform.acceptSocket(listener);
    defer mox_io.platform.closeSocket(accepted.socket);

    var loop = try mox_io.open(alloc);
    defer loop.deinit();
    try loop.associate(accepted.socket, 1);

    var router = try Router.init(alloc, &.{
        .{ .method = .GET, .path = "/events", .handler = S.handler },
    });
    defer router.deinit();

    const conn = try alloc.create(Connection);
    conn.* = .{ .alloc = alloc, .loop = &loop, .router = &router, .socket = accepted.socket };
    postRecv(conn);

    var hb = mox_io.Timer.init(20);
    hb.c.callback = S.tick;
    loop.add(&hb.c);
    try loop.run();

    const resp = S.got[0..S.got_len];
    try std.testing.expect(std.mem.indexOf(u8, resp, "text/event-stream") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "data: hello-sse") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "event: msg") != null);
}


// tick 钩子回归测试：handler 每次返回 true 且**不调用 send**，仅靠
// setTick(30) 的定时器驱动；第 3 次时发一条数据并结束。
// 若 tick 没接线，客户端永远等不到 "tick-3"，测试会超时失败。
test "SSE setTick 在无 send 时自动重新 pump" {
    if (@import("builtin").os.tag == .windows) try mox_io.platform.startup();
    const alloc = std.heap.page_allocator;

    const S = struct {
        var got: [2048]u8 = undefined;
        var got_len: usize = 0;
        var done: std.atomic.Value(bool) = .init(false);
        var calls: std.atomic.Value(u32) = .init(0);

        fn sseHandler(w: types.SseWriter) bool {
            w.setTick(30);
            const n = calls.fetchAdd(1, .monotonic) + 1;
            if (n < 3) return true; // 关键：本次不 send，只能靠 tick 再次触发
            w.send("done", "tick-3");
            w.close();
            return false;
        }
        fn handler(ctx: *Context) !Response {
            _ = ctx;
            return Response.sse(sseHandler);
        }
        fn client(addr: std.Io.net.IpAddress) void {
            const s = mox_io.platform.createTcpSocket(addr) catch return;
            defer mox_io.platform.closeSocket(s);
            mox_io.platform.connectSocket(s, addr) catch return;
            const req = "GET /events HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
            _ = mox_io.platform.sendBlocking(s, req) catch return;
            var n: usize = 0;
            while (n < got.len) {
                const r = mox_io.platform.recvBlocking(s, got[n..]) catch break;
                if (r == 0) break;
                n += r;
                if (std.mem.indexOf(u8, got[0..n], "tick-3") != null) break;
            }
            got_len = n;
            done.store(true, .release);
        }
        fn tick(loop: *Loop, c: *Completion) void {
            const t: *mox_io.Timer = @fieldParentPtr("c", c);
            if (done.load(.acquire)) { loop.stop(); return; }
            t.* = mox_io.Timer.init(20);
            t.c.callback = tick;
            loop.add(&t.c);
        }
    };

    const l = try testListen();
    const listener = l[0];
    const bound = l[1];
    defer mox_io.platform.closeSocket(listener);
    S.done.store(false, .release);
    S.got_len = 0;
    S.calls.store(0, .release);

    const cli = try std.Thread.spawn(.{}, S.client, .{bound});
    defer cli.join();

    const accepted = try mox_io.platform.acceptSocket(listener);
    defer mox_io.platform.closeSocket(accepted.socket);

    var loop = try mox_io.open(alloc);
    defer loop.deinit();
    try loop.associate(accepted.socket, 1);

    var router = try Router.init(alloc, &.{
        .{ .method = .GET, .path = "/events", .handler = S.handler },
    });
    defer router.deinit();

    const conn = try alloc.create(Connection);
    conn.* = .{ .alloc = alloc, .loop = &loop, .router = &router, .socket = accepted.socket };
    postRecv(conn);

    var hb = mox_io.Timer.init(20);
    hb.c.callback = S.tick;
    loop.add(&hb.c);
    try loop.run();

    const resp = S.got[0..S.got_len];
    try std.testing.expect(std.mem.indexOf(u8, resp, "data: tick-3") != null);
    // 确证 handler 被定时器驱动了多次，而不是一次就发出数据
    try std.testing.expectEqual(@as(u32, 3), S.calls.load(.acquire));
}

// setTick(0) 关闭自动 pump：handler 返回 true 但不 send 时不再被调用，
// 连接保持空闲（不崩溃、不重复 pump）。这里用 drainOpen 主动收尾验证
// tick 定时器确实没有被武装。
test "SSE setTick(0) 关闭自动 pump 且不泄漏定时器" {
    if (@import("builtin").os.tag == .windows) try mox_io.platform.startup();
    const alloc = std.testing.allocator;

    const S = struct {
        var calls: std.atomic.Value(u32) = .init(0);
        var client_done: std.atomic.Value(bool) = .init(false);
        var ready: std.atomic.Value(bool) = .init(false);

        fn sseHandler(w: types.SseWriter) bool {
            w.setTick(0);
            _ = calls.fetchAdd(1, .monotonic);
            ready.store(true, .release);
            return true; // 不 send、不 close，故意让连接挂着
        }
        fn handler(ctx: *Context) !Response {
            _ = ctx;
            return Response.sse(sseHandler);
        }
        fn client(addr: std.Io.net.IpAddress) void {
            const s = mox_io.platform.createTcpSocket(addr) catch return;
            defer mox_io.platform.closeSocket(s);
            mox_io.platform.connectSocket(s, addr) catch return;
            const req = "GET /events HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
            _ = mox_io.platform.sendBlocking(s, req) catch return;
            var tmp: [256]u8 = undefined;
            _ = mox_io.platform.recvBlocking(s, &tmp) catch {}; // 收到 SSE 头
            // 等一小段时间，让潜在的 tick 有机会触发
            var spins: usize = 0;
            while (spins < 200) : (spins += 1) std.Thread.yield() catch {};
            client_done.store(true, .release);
        }
        fn tick(loop: *Loop, c: *Completion) void {
            const t: *mox_io.Timer = @fieldParentPtr("c", c);
            if (!ready.load(.acquire)) {
                t.* = mox_io.Timer.init(20);
                t.c.callback = tick;
                loop.add(&t.c);
                return;
            }
            // 再给 200ms 让（若存在的）tick 触发几次
            if (mox_io.platform.tickCount() >= deadline) { loop.stop(); return; }
            t.* = mox_io.Timer.init(20);
            t.c.callback = tick;
            loop.add(&t.c);
        }
        var deadline: u64 = 0;
    };

    const l = try testListen();
    const listener = l[0];
    const bound = l[1];
    defer mox_io.platform.closeSocket(listener);
    S.calls.store(0, .release);
    S.client_done.store(false, .release);
    S.ready.store(false, .release);

    const cli = try std.Thread.spawn(.{}, S.client, .{bound});
    defer cli.join();

    const accepted = try mox_io.platform.acceptSocket(listener);

    var loop = try mox_io.open(alloc);
    defer loop.deinit();
    try loop.associate(accepted.socket, 1);

    var router = try Router.init(alloc, &.{
        .{ .method = .GET, .path = "/events", .handler = S.handler },
    });
    defer router.deinit();

    var srv = Server{
        .alloc = alloc,
        .loop = &loop,
        .router = &router,
        .address = bound,
        .listener = listener,
        .idle_timeout_ms = 0,
        .request_timeout_ms = 0,
        .shutting_down = true,
    };
    const conn = try alloc.create(Connection);
    conn.* = .{ .alloc = alloc, .loop = &loop, .router = &router, .socket = accepted.socket };
    registerConn(&srv, conn);
    postRecv(conn);

    var hb = mox_io.Timer.init(20);
    hb.c.callback = S.tick;
    S.deadline = mox_io.platform.tickCount() + 300;
    loop.add(&hb.c);
    try loop.run();

    // 只应调用一次：setTick(0) 后没有定时器重新 pump
    try std.testing.expectEqual(@as(u32, 1), S.calls.load(.acquire));

    // 主动收尾：撤销可能残留的定时器、释放连接，testing.allocator 记账无泄漏。
    abortConn(conn);
    loop.drainOpen(2000, @ptrCast(&srv), Server.allClosed);
    try std.testing.expectEqual(@as(usize, 0), srv.active_conns);
}


// tick 定时器在飞时中止连接：验证 disarmSseTick 会同步摘除定时器，
// 完成包不会打到已释放的 conn（UAF 回归）。用 testing.allocator 记账，
// 若残留定时器或连接没释放都会失败。
test "SSE tick 在飞时中止连接不 UAF、不泄漏" {
    if (@import("builtin").os.tag == .windows) try mox_io.platform.startup();
    const alloc = std.testing.allocator;

    const S = struct {
        var ready: std.atomic.Value(bool) = .init(false);
        var deadline: u64 = 0;

        fn sseHandler(w: types.SseWriter) bool {
            w.setTick(5000); // 长周期，保证中止时定时器仍在堆里
            ready.store(true, .release);
            return true;
        }
        fn handler(ctx: *Context) !Response {
            _ = ctx;
            return Response.sse(sseHandler);
        }
        fn client(addr: std.Io.net.IpAddress) void {
            const s = mox_io.platform.createTcpSocket(addr) catch return;
            defer mox_io.platform.closeSocket(s);
            mox_io.platform.connectSocket(s, addr) catch return;
            const req = "GET /events HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
            _ = mox_io.platform.sendBlocking(s, req) catch return;
            var tmp: [256]u8 = undefined;
            _ = mox_io.platform.recvBlocking(s, &tmp) catch {};
        }
        fn tick(loop: *Loop, c: *Completion) void {
            const t: *mox_io.Timer = @fieldParentPtr("c", c);
            if (!ready.load(.acquire)) {
                t.* = mox_io.Timer.init(10);
                t.c.callback = tick;
                loop.add(&t.c);
                return;
            }
            // handler 已运行、tick 已武装：再跑一小会儿后停机
            if (mox_io.platform.tickCount() >= deadline) { loop.stop(); return; }
            t.* = mox_io.Timer.init(10);
            t.c.callback = tick;
            loop.add(&t.c);
        }
    };

    const l = try testListen();
    const listener = l[0];
    const bound = l[1];
    defer mox_io.platform.closeSocket(listener);
    S.ready.store(false, .release);

    const cli = try std.Thread.spawn(.{}, S.client, .{bound});
    defer cli.join();

    const accepted = try mox_io.platform.acceptSocket(listener);

    var loop = try mox_io.open(alloc);
    defer loop.deinit();
    try loop.associate(accepted.socket, 1);

    var router = try Router.init(alloc, &.{
        .{ .method = .GET, .path = "/events", .handler = S.handler },
    });
    defer router.deinit();

    var srv = Server{
        .alloc = alloc,
        .loop = &loop,
        .router = &router,
        .address = bound,
        .listener = listener,
        .idle_timeout_ms = 0,
        .request_timeout_ms = 0,
        .shutting_down = true,
    };
    const conn = try alloc.create(Connection);
    conn.* = .{ .alloc = alloc, .loop = &loop, .router = &router, .socket = accepted.socket };
    registerConn(&srv, conn);
    postRecv(conn);

    var hb = mox_io.Timer.init(10);
    hb.c.callback = S.tick;
    S.deadline = mox_io.platform.tickCount() + 120;
    loop.add(&hb.c);
    try loop.run();

    try std.testing.expect(S.ready.load(.acquire));
    // 关键：此时 SSE tick（5s）仍在定时器堆里。中止连接必须同步摘掉它。
    abortConn(conn);
    loop.drainOpen(2000, @ptrCast(&srv), Server.allClosed);
    try std.testing.expectEqual(@as(usize, 0), srv.active_conns);
}

test "metrics 计数器在每次请求后递增" {
    if (@import("builtin").os.tag == .windows) try mox_io.platform.startup();
    const alloc = std.heap.page_allocator;

    // 记录基线（可能其他测试已经累积了请求）
    const before = getMetrics().total_requests;

    const S = struct {
        var done: std.atomic.Value(bool) = .init(false);
        fn handler(ctx: *Context) !Response {
            _ = ctx;
            return .{ .body = "ok\n" };
        }
        fn client(addr: std.Io.net.IpAddress) void {
            const s = mox_io.platform.createTcpSocket(addr) catch return;
            defer mox_io.platform.closeSocket(s);
            mox_io.platform.connectSocket(s, addr) catch return;
            const req = "GET /ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
            _ = mox_io.platform.sendBlocking(s, req) catch return;
            var tmp: [256]u8 = undefined;
            _ = mox_io.platform.recvBlocking(s, &tmp) catch {};
            done.store(true, .release);
        }
        fn tick(loop: *Loop, c: *Completion) void {
            const t: *mox_io.Timer = @fieldParentPtr("c", c);
            if (done.load(.acquire)) { loop.stop(); return; }
            t.* = mox_io.Timer.init(20);
            t.c.callback = tick;
            loop.add(&t.c);
        }
    };

    const l = try testListen();
    const listener = l[0];
    const bound = l[1];
    defer mox_io.platform.closeSocket(listener);
    S.done.store(false, .release);

    const cli = try std.Thread.spawn(.{}, S.client, .{bound});
    defer cli.join();

    const accepted = try mox_io.platform.acceptSocket(listener);
    defer mox_io.platform.closeSocket(accepted.socket);

    var loop = try mox_io.open(alloc);
    defer loop.deinit();
    try loop.associate(accepted.socket, 1);

    var router = try Router.init(alloc, &.{
        .{ .method = .GET, .path = "/ping", .handler = S.handler },
    });
    defer router.deinit();

    const conn = try alloc.create(Connection);
    conn.* = .{ .alloc = alloc, .loop = &loop, .router = &router, .socket = accepted.socket };
    postRecv(conn);

    var hb = mox_io.Timer.init(20);
    hb.c.callback = S.tick;
    loop.add(&hb.c);
    try loop.run();

    const after = getMetrics().total_requests;
    try std.testing.expect(after > before);
}

// 每请求 arena 回归测试：handler 通过 ctx.gpa 分配（problem() 的 JSON body、
// setCookieHeader 的头值、自定义 allocPrint）。整个连接生命周期用
// std.testing.allocator 记账，若框架没回收 arena，测试会因泄漏而失败。
test "每请求 arena 回收 ctx.gpa 分配，无泄漏" {
    if (@import("builtin").os.tag == .windows) try mox_io.platform.startup();
    const alloc = std.testing.allocator;

    const S = struct {
        var done: std.atomic.Value(bool) = .init(false);

        fn handler(ctx: *Context) !Response {
            // 走 problem()：valueAlloc 用 ctx.gpa 分配 JSON body
            var resp = try types.problem(ctx.gpa, .bad_request, "bad", "detail");
            // 再分配一个 Set-Cookie 头 + headers 数组，全部走 ctx.gpa
            const ck = try types.setCookieHeader(ctx.gpa, "sid", "abc", .{});
            const hdrs = try ctx.gpa.alloc(types.Header, 1);
            hdrs[0] = ck;
            resp.headers = hdrs;
            return resp;
        }
        fn client(addr: std.Io.net.IpAddress) void {
            const s = mox_io.platform.createTcpSocket(addr) catch return;
            defer mox_io.platform.closeSocket(s);
            mox_io.platform.connectSocket(s, addr) catch return;
            const req = "GET /leak HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
            _ = mox_io.platform.sendBlocking(s, req) catch return;
            var tmp: [512]u8 = undefined;
            _ = mox_io.platform.recvBlocking(s, &tmp) catch {};
            done.store(true, .release);
        }
        fn tick(loop: *Loop, c: *Completion) void {
            const t: *mox_io.Timer = @fieldParentPtr("c", c);
            if (done.load(.acquire)) { loop.stop(); return; }
            t.* = mox_io.Timer.init(20);
            t.c.callback = tick;
            loop.add(&t.c);
        }
    };

    const l = try testListen();
    const listener = l[0];
    const bound = l[1];
    defer mox_io.platform.closeSocket(listener);
    S.done.store(false, .release);

    const cli = try std.Thread.spawn(.{}, S.client, .{bound});
    defer cli.join();

    const accepted = try mox_io.platform.acceptSocket(listener);

    var loop = try mox_io.open(alloc);
    defer loop.deinit();
    try loop.associate(accepted.socket, 1);

    var router = try Router.init(alloc, &.{
        .{ .method = .GET, .path = "/leak", .handler = S.handler },
    });
    defer router.deinit();

    var srv = Server{
        .alloc = alloc,
        .loop = &loop,
        .router = &router,
        .address = bound,
        .listener = listener,
        .idle_timeout_ms = 0,
        .shutting_down = true, // 不恢复 accept
    };
    const conn = try alloc.create(Connection);
    conn.* = .{ .alloc = alloc, .loop = &loop, .router = &router, .socket = accepted.socket };
    registerConn(&srv, conn);
    postRecv(conn);

    var hb = mox_io.Timer.init(20);
    hb.c.callback = S.tick;
    loop.add(&hb.c);
    try loop.run();

    // 驱动收尾完成包，确保连接对象与 arena 都已释放。
    loop.drainOpen(2000, @ptrCast(&srv), Server.allClosed);
    try std.testing.expectEqual(@as(usize, 0), srv.active_conns);
}
