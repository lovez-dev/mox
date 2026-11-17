//! A bounded sequential framed TCP service. Each response XORs the body with 0x5a.

const std = @import("std");
const mox_io = @import("mox_io");

const t = mox_io.types;
const Loop = mox_io.DefaultLoop;

fn completion(loop: *Loop) !t.Completion {
    const deadline = loop.now() + 30_000_000_000;
    var result: [1]t.Completion = undefined;
    while (try loop.poll(&result, .{ .until = deadline }) == 0)
        if (loop.now() >= deadline) return error.ClientTimeout;
    return result[0];
}

fn receive(loop: *Loop, handle: t.Handle, bytes: []u8) !bool {
    _ = try loop.recvExact(handle, bytes, .{ .deadline = loop.now() + 30_000_000_000 });
    const result = try completion(loop);
    if (result.status == .eof and result.bytes == 0) return false;
    if (result.status != .ok or result.bytes != bytes.len) return error.InvalidFrame;
    return true;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const port = if (args.len > 1) try std.fmt.parseInt(u16, args[1], 10) else 9000;
    const clients = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 1;
    var loop: Loop = undefined;
    try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 8, .resources = 3, .file_threads = 0 });
    defer {
        loop.shutdown() catch @panic("service shutdown failed");
        var results: [8]t.Completion = undefined;
        const deadline = loop.now() + 5_000_000_000;
        while (loop.stats().active_resources != 0 or loop.stats().active_operations != 0 or loop.stats().completions_queued != 0) {
            if (loop.now() >= deadline) @panic("service cleanup timed out");
            _ = loop.poll(&results, .{ .until = deadline }) catch @panic("service drain failed");
        }
        loop.deinit() catch @panic("service deinit failed");
    }
    const listener = try loop.listen(t.Address.loopback(port), 16);
    var output_buffer: [256]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    try output.interface.print("listening 127.0.0.1:{d}\n", .{(try loop.localAddress(listener)).port});
    try output.interface.flush();
    for (0..clients) |_| {
        _ = try loop.accept(listener, .{ .deadline = loop.now() + 30_000_000_000 });
        const accepted = try completion(&loop);
        if (accepted.status != .ok) return error.AcceptFailed;
        const peer = accepted.accepted.?;
        try loop.noDelay(peer, true);
        while (true) {
            var header: [2]u8 = undefined;
            if (!try receive(&loop, peer, &header)) break;
            const length = @as(usize, header[0]) * 256 + header[1];
            if (length == 0 or length > 4096) return error.FrameTooLarge;
            var body: [4096]u8 = undefined;
            if (!try receive(&loop, peer, body[0..length])) return error.TruncatedFrame;
            for (body[0..length]) |*byte| byte.* ^= 0x5a;
            _ = try loop.sendAll(peer, body[0..length], .{ .deadline = loop.now() + 30_000_000_000 });
            if ((try completion(&loop)).status != .ok) return error.SendFailed;
        }
        try loop.close(peer, .drain, 0);
        const closed = try completion(&loop);
        if (closed.kind != .close or closed.status != .ok) return error.CloseFailed;
    }
}
