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
    };
    postAccept(&server);
    try loop.run();

    // 停机：取消仍在飞的 AcceptEx，等它的完成包回收后再让 `server` 出栈。
    // `dispose` 为空操作——Server 在栈上，由调用栈负责销毁。
    const Noop = struct {
        fn dispose(p: *anyopaque) void {
            _ = p;
        }
    };
    loop.cancel(&server.accept.c, @ptrCast(&server), Noop.dispose);
    loop.drainRetired(1000);
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
};

fn postAccept(server: *Server) void {
    server.accept_socket = server.loop.createSocket(server.address) catch return;
    server.accept = NetAccept.init(server.listener, server.accept_socket);
    server.accept.c.callback = onAccept;
    server.loop.add(&server.accept.c);
}

fn onAccept(loop: *Loop, c: *Completion) void {
    _ = loop;
    const accept: *NetAccept = @fieldParentPtr("c", c);
    const server: *Server = @fieldParentPtr("accept", accept);

    const client = accept.getResult() catch {
        server.loop.close(server.accept_socket);
        postAccept(server);
        return;
    };
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
    postRecv(conn);

    postAccept(server); // arm the next one before we block in the loop
}

// ---- connection：recv -> 解析 -> 路由 -> send ->（keep-alive | 关闭） -------

const Connection = struct {
    alloc: std.mem.Allocator,
    loop: *Loop,
    router: *const Router,
    socket: Handle,

    recv_buf: [8 * 1024]u8 = undefined,
    send_buf: [16 * 1024]u8 = undefined,
    recv_len: usize = 0,
    keep_alive: bool = false,

    recv: NetRecv = undefined,
    send: NetSend = undefined,
    close: NetClose = undefined,

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
    conn.recv = NetRecv.init(conn.socket, conn.recv_buf[conn.recv_len..]);
    conn.recv.c.callback = onRecv;
    conn.loop.add(&conn.recv.c);
}

fn onRecv(loop: *Loop, c: *Completion) void {
    _ = loop;
    const conn: *Connection = @fieldParentPtr("recv", @as(*NetRecv, @fieldParentPtr("c", c)));

    const n = conn.recv.getResult() catch {
        destroyConn(conn);
        return;
    };
    if (n == 0) { // peer closed cleanly
        destroyConn(conn);
        return;
    }
    conn.recv_len += n;

    switch (http.parse(conn.recv_buf[0..conn.recv_len])) {
        .incomplete => {
            if (conn.recv_len == conn.recv_buf.len) {
                respond(conn, .{ .status = .bad_request, .body = "request too large\n" }, false);
                return;
            }
            postRecv(conn);
        },
        .malformed => respond(conn, .{ .status = .bad_request, .body = "bad request\n" }, false),
        .request => |req| handleRequest(conn, req),
    }
}

fn handleRequest(conn: *Connection, req: http.Request) void {
    var params: Params = .{};
    const handler = conn.router.match(req.method, req.path, &params) orelse {
        respond(conn, .{ .status = .not_found, .body = "not found\n" }, req.keep_alive);
        return;
    };

    var ctx: Context = .{ .gpa = conn.alloc, .request = &req, .params = &params };
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
    conn.file_work = mox_io.ReadFile.init(conn.loop.io, path, conn.file_buf, conn.loop.memory_fs.lookup(path));
    conn.file_work.work.c.callback = onFileRead;
    conn.loop.add(&conn.file_work.work.c);
}

fn onFileRead(loop: *Loop, c: *Completion) void {
    _ = loop;
    const w: *mox_io.Work = @fieldParentPtr("c", c);
    const conn: *Connection = @fieldParentPtr("file_work", @as(*mox_io.ReadFile, @fieldParentPtr("work", w)));
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
    conn.send = NetSend.init(conn.socket, conn.send_wire[conn.sent_len..]);
    conn.send.c.callback = onSend;
    conn.loop.add(&conn.send.c);
}

fn onSend(loop: *Loop, c: *Completion) void {
    _ = loop;
    const conn: *Connection = @fieldParentPtr("send", @as(*NetSend, @fieldParentPtr("c", c)));

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

fn destroyConn(conn: *Connection) void {
    conn.close = NetClose.init(conn.socket);
    conn.close.c.callback = onClose;
    conn.loop.add(&conn.close.c);
}

fn onClose(loop: *Loop, c: *Completion) void {
    _ = loop;
    const conn: *Connection = @fieldParentPtr("close", @as(*NetClose, @fieldParentPtr("c", c)));
    if (conn.file_buf.len != 0) conn.alloc.free(conn.file_buf);
    if (conn.send_owned) |b| conn.alloc.free(b);
    const alloc = conn.alloc;
    alloc.destroy(conn);
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
