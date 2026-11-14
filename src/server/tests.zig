//! 服务层端到端与资源生命周期回归测试。
const std = @import("std");

const mox_io = @import("mox_io");
const router_mod = @import("../router.zig");

const Router = router_mod.Router;

const Loop = mox_io.Loop;
const Completion = mox_io.Completion;
const Timer = mox_io.Timer;
const Handle = mox_io.Handle;
const INVALID_HANDLE = mox_io.INVALID_HANDLE;

const types = @import("../types.zig");

pub const Response = types.Response;
pub const Context = types.Context;

const runtime = @import("runtime.zig");
const wsComputeAccept = @import("websocket.zig").computeAccept;
const Connection = runtime.Connection;
const Server = runtime.Server;
const abortConn = runtime.abortConn;
const getMetrics = @import("metrics.zig").getMetrics;
const noopDispose = runtime.noopDispose;
const postAccept = runtime.postAccept;
const postRecv = runtime.postRecv;
const registerConn = runtime.registerConn;
const serveWith = runtime.serveWith;
const startSend = runtime.startSend;

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

    var loop = try mox_io.open(alloc, .{});
    defer loop.deinit();

    var router = try Router.init(alloc, &.{});
    defer router.deinit();

    const conn = try alloc.create(Connection);
    conn.* = .{ .alloc = alloc, .loop = &loop, .router = &router, .socket = accepted.socket };
    try loop.io.associate(accepted.socket, 1);

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

    var loop = try mox_io.open(alloc, .{});
    defer loop.deinit();
    try loop.io.associate(accepted.socket, 1);
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

    var loop = try mox_io.open(alloc, .{});
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
    if (srv.accept_socket != INVALID_HANDLE) loop.io.close(srv.accept_socket);
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

    var loop = try mox_io.open(alloc, .{});
    defer loop.deinit();
    try loop.io.associate(accepted.socket, 1);
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
    if (srv.accept_socket != INVALID_HANDLE) loop.io.close(srv.accept_socket);

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

    var loop = try mox_io.open(alloc, .{});
    defer loop.deinit();
    try loop.io.associate(accepted.socket, 1);
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
            if (done.load(.acquire)) {
                loop.stop();
                return;
            }
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

    var loop = try mox_io.open(alloc, .{});
    defer loop.deinit();
    try loop.io.associate(accepted.socket, 1);

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
            if (done.load(.acquire)) {
                loop.stop();
                return;
            }
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

    var loop = try mox_io.open(alloc, .{});
    defer loop.deinit();
    try loop.io.associate(accepted.socket, 1);

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
            if (done.load(.acquire)) {
                loop.stop();
                return;
            }
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

    var loop = try mox_io.open(alloc, .{});
    defer loop.deinit();
    try loop.io.associate(accepted.socket, 1);

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
            if (mox_io.platform.tickCount() >= deadline) {
                loop.stop();
                return;
            }
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

    var loop = try mox_io.open(alloc, .{});
    defer loop.deinit();
    try loop.io.associate(accepted.socket, 1);

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
            if (mox_io.platform.tickCount() >= deadline) {
                loop.stop();
                return;
            }
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

    var loop = try mox_io.open(alloc, .{});
    defer loop.deinit();
    try loop.io.associate(accepted.socket, 1);

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
            if (done.load(.acquire)) {
                loop.stop();
                return;
            }
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

    var loop = try mox_io.open(alloc, .{});
    defer loop.deinit();
    try loop.io.associate(accepted.socket, 1);

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
            if (done.load(.acquire)) {
                loop.stop();
                return;
            }
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

    var loop = try mox_io.open(alloc, .{});
    defer loop.deinit();
    try loop.io.associate(accepted.socket, 1);

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

// 端到端响应拆分防护：handler 把含 CRLF 的不可信值放进响应头时，
// server 必须回一个干净的 500，绝不能把注入的第二个响应/头写到线上。
// 若 serialize 的校验被去掉，下面三条断言会全部变红（注入内容真的会发出）。
test "CRLF 注入端到端被拒绝，不写出伪造响应" {
    if (@import("builtin").os.tag == .windows) try mox_io.platform.startup();
    const alloc = std.heap.page_allocator;

    const S = struct {
        var got: [1024]u8 = undefined;
        var got_len: usize = 0;
        var done: std.atomic.Value(bool) = .init(false);

        fn handler(ctx: *Context) !Response {
            // 模拟把用户输入直接塞进响应头
            const hdrs = try ctx.gpa.alloc(types.Header, 1);
            hdrs[0] = .{ .name = "x-user", .value = "a\r\nX-Injected: pwned\r\n\r\nHTTP/1.1 200 OK" };
            return .{ .body = "ok", .headers = hdrs };
        }
        fn client(addr: std.Io.net.IpAddress) void {
            const s = mox_io.platform.createTcpSocket(addr) catch return;
            defer mox_io.platform.closeSocket(s);
            mox_io.platform.connectSocket(s, addr) catch return;
            const req = "GET /inject HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
            _ = mox_io.platform.sendBlocking(s, req) catch return;
            var n: usize = 0;
            while (n < got.len) {
                const r = mox_io.platform.recvBlocking(s, got[n..]) catch break;
                if (r == 0) break;
                n += r;
            }
            got_len = n;
            done.store(true, .release);
        }
        fn tick(loop: *Loop, c: *Completion) void {
            const t: *mox_io.Timer = @fieldParentPtr("c", c);
            if (done.load(.acquire)) {
                loop.stop();
                return;
            }
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

    var loop = try mox_io.open(alloc, .{});
    defer loop.deinit();
    try loop.io.associate(accepted.socket, 1);

    var router = try Router.init(alloc, &.{
        .{ .method = .GET, .path = "/inject", .handler = S.handler },
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
    try std.testing.expect(std.mem.indexOf(u8, resp, "500") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "X-Injected") == null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "HTTP/1.1 200 OK") == null);
}

// HTTP pipelining 端到端：一次 write 塞两个完整请求进同一个 TCP 段，
// 两个响应都必须回来。修复前 onSend 里 `recv_len = 0` 会丢掉第二个请求，
// 第二条断言会变红（只收到一个响应）。
test "HTTP pipelining：一次写入两个请求都得到响应" {
    if (@import("builtin").os.tag == .windows) try mox_io.platform.startup();
    const alloc = std.heap.page_allocator;

    const S = struct {
        var got: [4096]u8 = undefined;
        var got_len: usize = 0;
        var done: std.atomic.Value(bool) = .init(false);
        // 看门狗：最多等 5 秒。旧行为（丢弃第二个请求）会让客户端永远等不到
        // 第二个响应；没有上限时测试会挂死而不是失败，挂死比失败更难定位。
        var ticks: usize = 0;

        fn first(ctx: *Context) !Response {
            _ = ctx;
            return .{ .body = "AAA" };
        }
        fn second(ctx: *Context) !Response {
            _ = ctx;
            return .{ .body = "BBB" };
        }
        fn client(addr: std.Io.net.IpAddress) void {
            const s = mox_io.platform.createTcpSocket(addr) catch return;
            defer mox_io.platform.closeSocket(s);
            mox_io.platform.connectSocket(s, addr) catch return;
            // 两个请求拼成一次 send，尽量落在同一个段里。
            const reqs = "GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n";
            _ = mox_io.platform.sendBlocking(s, reqs) catch return;
            var n: usize = 0;
            // 读满两个响应（或对端关闭）为止。
            while (n < got.len) {
                const r = mox_io.platform.recvBlocking(s, got[n..]) catch break;
                if (r == 0) break;
                n += r;
                const have = got[0..n];
                // 两个响应都到齐就退出，不必等对端关闭。
                const c = std.mem.count(u8, have, "HTTP/1.1 200");
                if (c >= 2) break;
            }
            got_len = n;
            done.store(true, .release);
        }
        fn tick(loop: *Loop, c: *Completion) void {
            const t: *mox_io.Timer = @fieldParentPtr("c", c);
            ticks += 1;
            // 5 秒上限（20ms × 250）：旧行为下第二个响应永远不来，
            // 没有上限测试会挂死而不是失败，挂死更难定位。
            if (done.load(.acquire) or ticks > 250) {
                loop.stop();
                return;
            }
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
    S.ticks = 0;

    const cli = try std.Thread.spawn(.{}, S.client, .{bound});
    defer cli.join();

    const accepted = try mox_io.platform.acceptSocket(listener);
    defer mox_io.platform.closeSocket(accepted.socket);

    var loop = try mox_io.open(alloc, .{});
    defer loop.deinit();
    try loop.io.associate(accepted.socket, 1);

    var router = try Router.init(alloc, &.{
        .{ .method = .GET, .path = "/a", .handler = S.first },
        .{ .method = .GET, .path = "/b", .handler = S.second },
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
    try std.testing.expect(std.mem.count(u8, resp, "HTTP/1.1 200") == 2);
    try std.testing.expect(std.mem.indexOf(u8, resp, "AAA") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "BBB") != null);
    // 顺序必须保持（HTTP/1.1 要求响应与请求同序）。
    const ia = std.mem.indexOf(u8, resp, "AAA").?;
    const ib = std.mem.indexOf(u8, resp, "BBB").?;
    try std.testing.expect(ia < ib);
}

// HEAD 端到端：未注册 HEAD 路由时回退到 GET handler，响应只发头部、
// 但 content-length 必须等于同一 GET 的真实 body 长度（RFC 9110 §9.3.2）。
test "HEAD 回退 GET 路由且不发送 body" {
    if (@import("builtin").os.tag == .windows) try mox_io.platform.startup();
    const alloc = std.heap.page_allocator;

    const S = struct {
        var got: [2048]u8 = undefined;
        var got_len: usize = 0;
        var done: std.atomic.Value(bool) = .init(false);
        var ticks: usize = 0;

        fn onlyGet(ctx: *Context) !Response {
            _ = ctx;
            return .{ .body = "body-must-not-be-sent" }; // 21 字节
        }
        fn client(addr: std.Io.net.IpAddress) void {
            const s = mox_io.platform.createTcpSocket(addr) catch return;
            defer mox_io.platform.closeSocket(s);
            mox_io.platform.connectSocket(s, addr) catch return;
            _ = mox_io.platform.sendBlocking(s, "HEAD /only-get HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n") catch return;
            var n: usize = 0;
            while (n < got.len) {
                const r = mox_io.platform.recvBlocking(s, got[n..]) catch break;
                if (r == 0) break;
                n += r;
            }
            got_len = n;
            done.store(true, .release);
        }
        fn tick(loop: *Loop, c: *Completion) void {
            const t: *mox_io.Timer = @fieldParentPtr("c", c);
            ticks += 1;
            if (done.load(.acquire) or ticks > 250) {
                loop.stop();
                return;
            }
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
    S.ticks = 0;

    const cli = try std.Thread.spawn(.{}, S.client, .{bound});
    defer cli.join();

    const accepted = try mox_io.platform.acceptSocket(listener);
    defer mox_io.platform.closeSocket(accepted.socket);

    var loop = try mox_io.open(alloc, .{});
    defer loop.deinit();
    try loop.io.associate(accepted.socket, 1);

    // 只注册 GET，故意不注册 HEAD：验证路由器回退。
    var router = try Router.init(alloc, &.{
        .{ .method = .GET, .path = "/only-get", .handler = S.onlyGet },
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
    // 1) 回退到 GET handler：不是 404。
    try std.testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "404") == null);
    // 2) content-length 是真实长度 21，不是 0。
    try std.testing.expect(std.mem.indexOf(u8, resp, "content-length: 21\r\n") != null);
    // 3) body 一个字节都没发。
    try std.testing.expect(std.mem.indexOf(u8, resp, "body-must-not-be-sent") == null);
    try std.testing.expect(std.mem.endsWith(u8, resp, "\r\n\r\n"));
}

// chunked 请求体端到端：客户端发 Transfer-Encoding: chunked，handler 必须
// 拿到解码后的 body（不是原始分块编码），且响应正常。
test "chunked 请求体端到端解码" {
    if (@import("builtin").os.tag == .windows) try mox_io.platform.startup();
    const alloc = std.heap.page_allocator;

    const S = struct {
        var got: [2048]u8 = undefined;
        var got_len: usize = 0;
        var body_seen: [64]u8 = undefined;
        var body_len: usize = 0;
        var done: std.atomic.Value(bool) = .init(false);
        var ticks: usize = 0;

        fn echo(ctx: *Context) !Response {
            // 把收到的 body 抄下来，测试结束后断言
            const n = @min(ctx.body.len, body_seen.len);
            @memcpy(body_seen[0..n], ctx.body[0..n]);
            body_len = n;
            return .{ .body = "ok" };
        }
        fn client(addr: std.Io.net.IpAddress) void {
            const s = mox_io.platform.createTcpSocket(addr) catch return;
            defer mox_io.platform.closeSocket(s);
            mox_io.platform.connectSocket(s, addr) catch return;
            // "hello world" 拆成 "hello" + " world" 两个块
            const req = "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" ++
                "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n";
            _ = mox_io.platform.sendBlocking(s, req) catch return;
            var n: usize = 0;
            while (n < got.len) {
                const r = mox_io.platform.recvBlocking(s, got[n..]) catch break;
                if (r == 0) break;
                n += r;
            }
            got_len = n;
            done.store(true, .release);
        }
        fn tick(loop: *Loop, c: *Completion) void {
            const t: *mox_io.Timer = @fieldParentPtr("c", c);
            ticks += 1;
            if (done.load(.acquire) or ticks > 250) {
                loop.stop();
                return;
            }
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
    S.body_len = 0;
    S.ticks = 0;

    const cli = try std.Thread.spawn(.{}, S.client, .{bound});
    defer cli.join();

    const accepted = try mox_io.platform.acceptSocket(listener);
    defer mox_io.platform.closeSocket(accepted.socket);

    var loop = try mox_io.open(alloc, .{});
    defer loop.deinit();
    try loop.io.associate(accepted.socket, 1);

    var router = try Router.init(alloc, &.{
        .{ .method = .POST, .path = "/echo", .handler = S.echo },
    });
    defer router.deinit();

    const conn = try alloc.create(Connection);
    conn.* = .{ .alloc = alloc, .loop = &loop, .router = &router, .socket = accepted.socket };
    postRecv(conn);

    var hb = mox_io.Timer.init(20);
    hb.c.callback = S.tick;
    loop.add(&hb.c);
    try loop.run();

    // handler 必须看到解码后的 "hello world"，而不是 "5\r\nhello\r\n6\r\n world..."
    try std.testing.expectEqualStrings("hello world", S.body_seen[0..S.body_len]);
    // 响应正常（不是 501 / 400）
    const resp = S.got[0..S.got_len];
    try std.testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
}

// chunked 大 body：远超 8 KB recv_buf 的请求体必须靠跨多次 recv 累积才能解出。
// 修复前（不累积、只解码单次 recv_buf）这里会 400/413，handler 拿不到 body。
test "chunked 大请求体跨多次 recv 累积解码" {
    if (@import("builtin").os.tag == .windows) try mox_io.platform.startup();
    const alloc = std.testing.allocator; // 顺带验证 chunked 路径无泄漏
    const total: usize = 20000; // 远大于 8 KB recv_buf

    const S = struct {
        var got: [512]u8 = undefined;
        var got_len: usize = 0;
        var body_len: usize = 0;
        var body_ok: bool = false;
        var done: std.atomic.Value(bool) = .init(false);
        var ticks: usize = 0;

        fn echo(ctx: *Context) !Response {
            body_len = ctx.body.len;
            // 校验内容：必须全是 'z'
            var ok = ctx.body.len == total;
            for (ctx.body) |c| {
                if (c != 'z') {
                    ok = false;
                    break;
                }
            }
            body_ok = ok;
            return .{ .body = "ok" };
        }
        fn client(addr: std.Io.net.IpAddress) void {
            const s = mox_io.platform.createTcpSocket(addr) catch return;
            defer mox_io.platform.closeSocket(s);
            mox_io.platform.connectSocket(s, addr) catch return;
            var hdr: [128]u8 = undefined;
            const h = std.fmt.bufPrint(&hdr, "POST /big HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n", .{}) catch return;
            _ = mox_io.platform.sendBlocking(s, h) catch return;
            // 分多个块发：每块 4096 字节
            var sent: usize = 0;
            var line: [32]u8 = undefined;
            while (sent < total) {
                const n = @min(@as(usize, 4096), total - sent);
                const sz = std.fmt.bufPrint(&line, "{x}\r\n", .{n}) catch return;
                _ = mox_io.platform.sendBlocking(s, sz) catch return;
                var chunk: [4096]u8 = undefined;
                @memset(chunk[0..n], 'z');
                _ = mox_io.platform.sendBlocking(s, chunk[0..n]) catch return;
                _ = mox_io.platform.sendBlocking(s, "\r\n") catch return;
                sent += n;
            }
            _ = mox_io.platform.sendBlocking(s, "0\r\n\r\n") catch return;
            var k: usize = 0;
            while (k < got.len) {
                const r = mox_io.platform.recvBlocking(s, got[k..]) catch break;
                if (r == 0) break;
                k += r;
            }
            got_len = k;
            done.store(true, .release);
        }
        fn tick(loop: *Loop, c: *Completion) void {
            const t: *mox_io.Timer = @fieldParentPtr("c", c);
            ticks += 1;
            if (done.load(.acquire) or ticks > 500) {
                loop.stop();
                return;
            }
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
    S.body_len = 0;
    S.body_ok = false;
    S.ticks = 0;

    const cli = try std.Thread.spawn(.{}, S.client, .{bound});
    defer cli.join();

    const accepted = try mox_io.platform.acceptSocket(listener);
    defer mox_io.platform.closeSocket(accepted.socket);

    var loop = try mox_io.open(alloc, .{});
    defer loop.deinit();
    try loop.io.associate(accepted.socket, 1);

    var router = try Router.init(alloc, &.{
        .{ .method = .POST, .path = "/big", .handler = S.echo },
    });
    defer router.deinit();

    const conn = try alloc.create(Connection);
    conn.* = .{ .alloc = alloc, .loop = &loop, .router = &router, .socket = accepted.socket };
    postRecv(conn);

    var hb = mox_io.Timer.init(20);
    hb.c.callback = S.tick;
    loop.add(&hb.c);
    try loop.run();

    // 关键断言：handler 收到完整的 20000 字节，内容正确。
    try std.testing.expectEqual(total, S.body_len);
    try std.testing.expect(S.body_ok);
    try std.testing.expect(std.mem.indexOf(u8, S.got[0..S.got_len], "200 OK") != null);
}
