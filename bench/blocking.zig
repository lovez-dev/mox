//! 纯阻塞对照尺子：与 `bench/echo.zig` 完全相同的 TCP ping-pong 负载，
//! 但服务端不经 `mox_io.Loop`，直接用阻塞 recv/send echo。
//! 用来隔离本机 / WSL2 localhost 的固有开销，判断完成循环的真实增量。

const std = @import("std");
const io = @import("mox_io");

const platform = io.platform;
const payload: [64]u8 = @splat('x');

pub fn main() !void {
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

    const start = platform.tickCount();
    var buf: [256]u8 = undefined;
    var done: usize = 0;
    while (done < rounds) : (done += 1) {
        const n = platform.recvBlocking(accepted.socket, &buf) catch break;
        if (n == 0) break;
        _ = platform.sendBlocking(accepted.socket, buf[0..n]) catch break;
    }
    const elapsed = platform.tickCount() - start;

    t.join();
    std.debug.print(
        "blocking echo: {d} rounds / {d} ms = {d} ops/s, {d} us/op\n",
        .{
            done,
            elapsed,
            if (elapsed != 0) done * 1000 / elapsed else 0,
            if (done != 0) elapsed * 1000 / done else 0,
        },
    );
}
