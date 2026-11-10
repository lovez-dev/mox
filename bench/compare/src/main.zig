// SPDX-License-Identifier: MIT
//! mox_io vs zio.ev 同构性能对照。
//!
//! ## 比的是什么
//! 两边都只比**低层 callback 事件循环**：`mox_io.Loop` vs `zio.ev.Loop`。
//! zio 的 `Runtime`（栈式协程 / work-stealing）不参与——那是不同抽象层级，
//! 把协程切换开销算进 I/O 对比不公平。
//!
//! ## workload
//! 每次 `benchFn` 调用 = 一整个 TCP echo 会话：建监听 → 起客户端线程 →
//! accept → 串行 `recv → send` 往返 `rounds` 次 → 拆连。
//! 两边用各自框架的原生 socket 建立路径（mox 同步 accept + `associate`；
//! zio 必须用异步 `NetOpen/NetAccept` 才会自动关联后端），但**建立路径
//! 在计时之外**：oktest 的 `benchFn` 整体计时，此处无差别地包含两边。
//!
//! ## 计时
//! 两边都由 `oktest` 用同一个 `std.Io.Clock.awake` 测量，`std.Io.Threaded`
//! 仅提供时钟 vtable，不参与任何 I/O，与 mox「不使用 std.Io 异步运行时
//! 句柄」的产品约束不冲突。
//!
//! ## 边界（务必如实理解）
//! - zio.ev 功能远多于 mox_io（cancellation、epoll 回退、buffer 抽象、
//!   结构化并发）；数字差异**不能**解读为「设计优劣」。
//! - GitHub-hosted runner 是共享虚拟机，oktest 的 `noisy` / RSD / CI95
//!   标记正是用来暴露这一点。绝对值不可跨机器比较，只看同机比值。
//! - 建连/拆连开销混进每个样本，对两边一致，但会稀释 I/O 路径差异。

const std = @import("std");
const oktest = @import("oktest");
const io = @import("mox_io");
const zio = @import("zio");

const ev = zio.ev;
const znet = zio.os.net;
const platform = io.platform;

const rounds: usize = 2000;
const payload: [64]u8 = @splat('x');

// ── 通用选项 ────────────────────────────────────────────────────────────
// 每个会话约几十毫秒；warmup 与样本数都压低，避免 5 平台 CI 拉太长。
// `target_batch_ns` 保持 2ms：慢函数会把 batch 压到 1，这正是想要的。
const bench_opts = .{
    .warmup_iters = 3,
    .sample_count = 20,
    .target_batch_ns = @as(u64, 2_000_000),
    .bootstrap_seed = @as(u64, 0xDEADBEEF),
};

// ── mox_io 会话 ─────────────────────────────────────────────────────────

const MoxEcho = struct {
    loop: *io.Loop,
    socket: io.Handle,
    buf: [256]u8 = undefined,
    recv: io.NetRecv = undefined,
    send: io.NetSend = undefined,
    done: usize = 0,

    fn postRecv(self: *MoxEcho) void {
        self.recv = io.NetRecv.init(self.socket, &self.buf);
        self.recv.c.callback = onRecv;
        self.loop.add(&self.recv.c);
    }

    fn onRecv(l: *io.Loop, c: *io.Completion) void {
        const r: *io.NetRecv = @fieldParentPtr("c", c);
        const self: *MoxEcho = @fieldParentPtr("recv", r);
        const n = r.getResult() catch {
            l.stop();
            return;
        };
        if (n == 0) {
            l.stop();
            return;
        }
        self.send = io.NetSend.init(self.socket, self.buf[0..n]);
        self.send.c.callback = onSend;
        l.add(&self.send.c);
    }

    fn onSend(l: *io.Loop, c: *io.Completion) void {
        const s: *io.NetSend = @fieldParentPtr("c", c);
        const self: *MoxEcho = @fieldParentPtr("send", s);
        _ = s.getResult() catch {
            l.stop();
            return;
        };
        self.done += 1;
        if (self.done >= rounds) {
            l.stop();
            return;
        }
        self.postRecv();
    }
};

fn moxSession(ctx: *Ctx, unused_io: std.Io) anyerror!void {
    _ = unused_io;
    const bind_addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const listener = try platform.createTcpSocket(bind_addr);
    defer platform.closeSocket(listener);
    try platform.setReuseAddress(listener, true);
    try platform.bindSocket(listener, bind_addr);
    const bound = try platform.localAddress(listener);
    try platform.listenSocket(listener, 16);

    const Client = struct {
        fn run(addr: std.Io.net.IpAddress) void {
            const s = platform.createTcpSocket(addr) catch return;
            defer platform.closeSocket(s);
            platform.connectSocket(s, addr) catch return;
            var buf: [256]u8 = undefined;
            var i: usize = 0;
            while (i < rounds) : (i += 1) {
                _ = platform.sendBlocking(s, &payload) catch return;
                const got = platform.recvBlocking(s, &buf) catch return;
                if (got != payload.len) return;
            }
        }
    };

    const t = try std.Thread.spawn(.{}, Client.run, .{bound});
    const accepted = try platform.acceptSocket(listener);
    defer platform.closeSocket(accepted.socket);

    var loop = try io.open(ctx.gpa);
    defer loop.deinit();
    try loop.associate(accepted.socket, 1);

    var echo: MoxEcho = .{ .loop = &loop, .socket = accepted.socket };
    echo.postRecv();
    try loop.run();
    t.join();
    if (echo.done != rounds) return error.IncompleteEcho;
}

// ── zio.ev 会话 ─────────────────────────────────────────────────────────

const ZioEcho = struct {
    loop: *ev.Loop,
    socket: znet.fd_t,
    buf: [256]u8 = undefined,
    iov: [1]znet.iovec = undefined,
    wiov: [1]znet.iovec_const = undefined,
    recv: ev.NetRecv = undefined,
    send: ev.NetSend = undefined,
    done: usize = 0,

    fn postRecv(self: *ZioEcho) void {
        self.recv = ev.NetRecv.init(self.socket, ev.ReadBuf.fromSlice(&self.buf, &self.iov), .{});
        self.recv.c.userdata = self;
        self.recv.c.callback = onRecv;
        self.loop.add(&self.recv.c);
    }

    fn onRecv(l: *ev.Loop, c: *ev.Completion) void {
        const r: *ev.NetRecv = @fieldParentPtr("c", c);
        const self: *ZioEcho = @ptrCast(@alignCast(c.userdata.?));
        const n = r.getResult() catch {
            l.stop();
            return;
        };
        if (n == 0) {
            l.stop();
            return;
        }
        self.send = ev.NetSend.init(self.socket, ev.WriteBuf.fromSlice(self.buf[0..n], &self.wiov), .{});
        self.send.c.userdata = self;
        self.send.c.callback = onSend;
        l.add(&self.send.c);
    }

    fn onSend(l: *ev.Loop, c: *ev.Completion) void {
        const s: *ev.NetSend = @fieldParentPtr("c", c);
        _ = s.getResult() catch {
            l.stop();
            return;
        };
        const self: *ZioEcho = @ptrCast(@alignCast(c.userdata.?));
        self.done += 1;
        if (self.done >= rounds) {
            l.stop();
            return;
        }
        self.postRecv();
    }
};

const ZioServer = struct {
    loop: *ev.Loop,
    open: ev.NetOpen = undefined,
    bind: ev.NetBind = undefined,
    listen: ev.NetListen = undefined,
    accept: ev.NetAccept = undefined,
    echo: ZioEcho = undefined,
    addr: znet.sockaddr.in = .{
        .family = znet.AF.INET,
        .port = 0,
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
        .zero = @splat(0),
    },
    addr_len: znet.socklen_t = @sizeOf(znet.sockaddr.in),
    client_addr: znet.sockaddr.in = undefined,
    client_thread: ?std.Thread = null,

    fn start(self: *ZioServer) void {
        self.open = ev.NetOpen.init(.ipv4, .stream, .ip, .{ .nonblocking = true });
        self.open.c.userdata = self;
        self.open.c.callback = onOpen;
        self.loop.add(&self.open.c);
    }

    fn onOpen(l: *ev.Loop, c: *ev.Completion) void {
        const self: *ZioServer = @ptrCast(@alignCast(c.userdata.?));
        const listener = c.getResult(.net_open) catch {
            l.stop();
            return;
        };
        self.bind = ev.NetBind.init(listener, @ptrCast(&self.addr), &self.addr_len);
        self.bind.c.userdata = self;
        self.bind.c.callback = onBind;
        l.add(&self.bind.c);
    }

    fn onBind(l: *ev.Loop, c: *ev.Completion) void {
        const self: *ZioServer = @ptrCast(@alignCast(c.userdata.?));
        _ = c.getResult(.net_bind) catch {
            l.stop();
            return;
        };
        self.client_addr = self.addr;
        self.listen = ev.NetListen.init(self.bind.handle, 16);
        self.listen.c.userdata = self;
        self.listen.c.callback = onListen;
        l.add(&self.listen.c);
    }

    fn onListen(l: *ev.Loop, c: *ev.Completion) void {
        const self: *ZioServer = @ptrCast(@alignCast(c.userdata.?));
        _ = c.getResult(.net_listen) catch {
            l.stop();
            return;
        };
        const t = std.Thread.spawn(.{}, ZioClient.run, .{self.client_addr}) catch {
            l.stop();
            return;
        };
        self.client_thread = t;
        self.accept = ev.NetAccept.init(self.listen.handle, null, null);
        self.accept.c.userdata = self;
        self.accept.c.callback = onAccept;
        l.add(&self.accept.c);
    }

    fn onAccept(l: *ev.Loop, c: *ev.Completion) void {
        const self: *ZioServer = @ptrCast(@alignCast(c.userdata.?));
        const accepted = c.getResult(.net_accept) catch {
            l.stop();
            return;
        };
        self.echo = .{ .loop = l, .socket = accepted };
        self.echo.postRecv();
    }

    const ZioClient = struct {
        fn run(addr: znet.sockaddr.in) void {
            const s = znet.socket(.ipv4, .stream, .tcp, .{ .nonblocking = false }) catch return;
            defer znet.close(s);
            znet.connect(s, @ptrCast(&addr), @sizeOf(znet.sockaddr.in)) catch return;
            var buf: [256]u8 = undefined;
            var iov: [1]znet.iovec = undefined;
            var wiov: [1]znet.iovec_const = undefined;
            var i: usize = 0;
            while (i < rounds) : (i += 1) {
                _ = znet.send(s, ev.WriteBuf.fromSlice(&payload, &wiov).iovecs, .{}) catch return;
                const got = znet.recv(s, ev.ReadBuf.fromSlice(&buf, &iov).iovecs, .{}) catch return;
                if (got != payload.len) return;
            }
        }
    };
};

fn zioSession(ctx: *Ctx, unused_io: std.Io) anyerror!void {
    _ = unused_io;
    _ = ctx;
    var loop: ev.Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var server: ZioServer = .{ .loop = &loop };
    server.start();
    try loop.run();
    if (server.client_thread) |t| t.join();
    if (server.echo.done != rounds) return error.IncompleteEcho;
}

// ── 驱动 ────────────────────────────────────────────────────────────────

const Ctx = struct { gpa: std.mem.Allocator };

pub fn main(init: std.process.Init) !void {
    if (@import("builtin").os.tag == .windows) {
        // mox 的 IOCP 后端需要显式 WSAStartup；zio 的 Loop.init 自带
        // ensureWSAInitialized，重复调用无害。
        try platform.startup();
    }

    var ctx: Ctx = .{ .gpa = init.gpa };

    // 交替两轮：每个 oktest.run 内部已有 warmup + 多轮采样，交替可抵消
    // 进程热机 / 频率漂移带来的系统偏差。
    var results: [4]oktest.Result = undefined;
    const order = [_]struct { name: []const u8, which: u8 }{
        .{ .name = "mox_io #1", .which = 0 },
        .{ .name = "zio.ev #1", .which = 1 },
        .{ .name = "mox_io #2", .which = 0 },
        .{ .name = "zio.ev #2", .which = 1 },
    };
    for (order, 0..) |item, i| {
        results[i] = if (item.which == 0)
            try oktest.run(init.gpa, init.io, item.name, moxSession, &ctx, bench_opts)
        else
            try oktest.run(init.gpa, init.io, item.name, zioSession, &ctx, bench_opts);
    }

    var buf: [8192]u8 = undefined;
    var out: std.Io.File.Writer = .init(.stdout(), init.io, &buf);
    try oktest.report.print(&out.interface, &results, .{ .format = .markdown });
    try out.interface.writeAll("\n\n<!-- JSON-BEGIN -->\n");
    try oktest.report.print(&out.interface, &results, .{ .format = .json });
    try out.interface.writeAll("\n<!-- JSON-END -->\n");
    try out.flush();
}
