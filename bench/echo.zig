//! mox_io 性能基线：TCP echo 的往返延迟与吞吐。
//!
//! 服务端完全跑在 `mox_io.Loop` 的完成循环里（recv → send 串行），
//! 客户端是独立的阻塞线程。输出 ops/s 与 µs/op，用于改动前后对比。
//!
//! 用法：`zig build bench -- <往返次数>`（默认 2000）。

const std = @import("std");
const io = @import("mox_io");

const platform = io.platform;
const Loop = io.Loop;
const Completion = io.Completion;
const NetRecv = io.NetRecv;
const NetSend = io.NetSend;
const Handle = io.Handle;

const payload: [64]u8 = @splat('x');

const Echo = struct {
    loop: *Loop,
    socket: Handle,
    buf: [256]u8 = undefined,
    recv: NetRecv = undefined,
    send: NetSend = undefined,
    done: usize = 0,
    target: usize,

    fn postRecv(self: *Echo) void {
        self.recv = NetRecv.init(self.socket, &self.buf);
        self.recv.c.callback = onRecv;
        self.loop.add(&self.recv.c);
    }

    fn onRecv(l: *Loop, c: *Completion) void {
        const r: *NetRecv = @fieldParentPtr("c", c);
        const self: *Echo = @fieldParentPtr("recv", r);
        const n = r.getResult() catch {
            l.stop();
            return;
        };
        if (n == 0) {
            l.stop();
            return;
        }
        self.send = NetSend.init(self.socket, self.buf[0..n]);
        self.send.c.callback = onSend;
        l.add(&self.send.c);
    }

    fn onSend(l: *Loop, c: *Completion) void {
        const s: *NetSend = @fieldParentPtr("c", c);
        const self: *Echo = @fieldParentPtr("send", s);
        _ = s.getResult() catch {
            l.stop();
            return;
        };
        self.done += 1;
        if (self.done >= self.target) {
            l.stop();
            return;
        }
        self.postRecv();
    }
};

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const rounds: usize = @import("build_options").rounds;

    if (@import("builtin").os.tag == .windows) try platform.startup();
    const bind_addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const listener = try platform.createTcpSocket(bind_addr);
    defer platform.closeSocket(listener);
    try platform.setReuseAddress(listener, true);
    try platform.bindSocket(listener, bind_addr);
    const bound = try platform.localAddress(listener);
    try platform.listenSocket(listener, 16);

    const Client = struct {
        fn run(addr: std.Io.net.IpAddress, n: usize) void {
            const s = platform.createTcpSocket(addr) catch return;
            defer platform.closeSocket(s);
            platform.connectSocket(s, addr) catch return;
            var buf: [256]u8 = undefined;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                _ = platform.sendBlocking(s, &payload) catch return;
                const got = platform.recvBlocking(s, &buf) catch return;
                if (got != payload.len) return;
            }
        }
    };

    const t = try std.Thread.spawn(.{}, Client.run, .{ bound, rounds });
    const accepted = try platform.acceptSocket(listener);
    defer platform.closeSocket(accepted.socket);

    var loop = try io.open(gpa, .{});
    defer loop.deinit();
    try loop.io.associate(accepted.socket, 1);

    var echo: Echo = .{ .loop = &loop, .socket = accepted.socket, .target = rounds };
    echo.postRecv();

    const start = platform.tickCount();
    try loop.run();
    const elapsed = platform.tickCount() - start;

    t.join();
    std.debug.print(
        "mox_io echo: {d} rounds / {d} ms = {d} ops/s, {d} us/op\n",
        .{
            echo.done,
            elapsed,
            if (elapsed != 0) echo.done * 1000 / elapsed else 0,
            if (echo.done != 0) elapsed * 1000 / echo.done else 0,
        },
    );
}
