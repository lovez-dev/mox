//! 多连接并发吞吐尺子：N 条 TCP 连接同时跑 ping-pong。
//!
//! 服务端只有**一个** `mox_io.Loop`，所有连接的完成包由 `waitBatch` 批量
//! 收割；客户端每条连接一个阻塞线程。与单连接 `bench/echo.zig` 对比，
//! 用来体现批量收割在并发下的价值，并和 `bench/blocking.zig`（每连接
//! 一个线程、不经完成循环）隔离出线程开销。
//!
//! 用法：`zig build bench-concurrent -Dconns=<连接数> -Drounds=<每连接往返数>`

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
    state: *State,

    fn postRecv(self: *Echo) void {
        self.recv = NetRecv.init(self.socket, &self.buf);
        self.recv.c.callback = onRecv;
        self.loop.add(&self.recv.c);
    }

    fn onRecv(l: *Loop, c: *Completion) void {
        const r: *NetRecv = @fieldParentPtr("c", c);
        const self: *Echo = @fieldParentPtr("recv", r);
        const n = r.getResult() catch {
            self.finish(l);
            return;
        };
        if (n == 0) {
            self.finish(l);
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
            self.finish(l);
            return;
        };
        self.done += 1;
        if (self.done >= self.target) {
            self.finish(l);
            return;
        }
        self.postRecv();
    }

    fn finish(self: *Echo, l: *Loop) void {
        self.state.finished += 1;
        if (self.state.finished == self.state.conns) l.stop();
    }
};

const State = struct {
    conns: usize,
    finished: usize = 0,
};

pub fn main() !void {
    const opts = @import("build_options");
    const conns: usize = opts.conns;
    const rounds: usize = opts.rounds;
    const gpa = std.heap.page_allocator;
    if (@import("builtin").os.tag == .windows) try platform.startup();

    const bind_addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const listener = try platform.createTcpSocket(bind_addr);
    defer platform.closeSocket(listener);
    try platform.setReuseAddress(listener, true);
    try platform.bindSocket(listener, bind_addr);
    const bound = try platform.localAddress(listener);
    try platform.listenSocket(listener, @intCast(conns + 1));

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

    const threads = try gpa.alloc(std.Thread, conns);
    defer gpa.free(threads);
    var started: usize = 0;
    defer for (threads[0..started]) |t| t.join();
    var i: usize = 0;
    while (i < conns) : (i += 1) {
        threads[i] = try std.Thread.spawn(.{}, Client.run, .{ bound, rounds });
        started += 1;
    }

    const sockets = try gpa.alloc(Handle, conns);
    defer gpa.free(sockets);
    i = 0;
    while (i < conns) : (i += 1) {
        const a = try platform.acceptSocket(listener);
        sockets[i] = a.socket;
    }
    defer for (sockets) |s| platform.closeSocket(s);

    var loop = try io.open(gpa);
    defer loop.deinit();

    var state: State = .{ .conns = conns };
    const echos = try gpa.alloc(Echo, conns);
    defer gpa.free(echos);
    i = 0;
    while (i < conns) : (i += 1) {
        try loop.associate(sockets[i], i + 1);
        echos[i] = .{ .loop = &loop, .socket = sockets[i], .target = rounds, .state = &state };
        echos[i].postRecv();
    }

    const start = platform.tickCount();
    try loop.run();
    const elapsed = platform.tickCount() - start;

    var total: usize = 0;
    for (echos) |*e| total += e.done;
    std.debug.print(
        "mox_io concurrent: {d} conns x {d} rounds = {d} ops / {d} ms = {d} ops/s, {d} us/op\n",
        .{
            conns,
            rounds,
            total,
            elapsed,
            if (elapsed != 0) total * 1000 / elapsed else 0,
            if (total != 0) elapsed * 1000 / total else 0,
        },
    );
}
