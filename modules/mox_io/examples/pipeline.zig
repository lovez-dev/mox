//! Feed and drain a real child process using the public completion API.

const std = @import("std");
const mox_io = @import("mox_io");

const t = mox_io.types;
const Loop = mox_io.DefaultLoop;

fn one(loop: *Loop) !t.Completion {
    const deadline = loop.now() + 10_000_000_000;
    var results: [1]t.Completion = undefined;
    while (try loop.poll(&results, .{ .until = deadline }) == 0)
        if (loop.now() >= deadline) return error.PipelineTimeout;
    return results[0];
}

pub fn main(init: std.process.Init) !void {
    var loop: Loop = undefined;
    try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 4, .resources = 1, .file_threads = 3 });
    defer {
        loop.shutdown() catch @panic("pipeline shutdown failed");
        loop.deinit() catch @panic("pipeline deinit failed");
    }
    var input: mox_io.Pipe = .{};
    try input.init();
    defer input.deinit() catch unreachable;
    var output: mox_io.Pipe = .{};
    try output.init();
    defer output.deinit() catch unreachable;
    var child: mox_io.process.Child = .{};
    const args: []const [:0]const u8 = if (@import("builtin").os.tag == .windows) &.{"sort.exe"} else &.{"sort"};
    try child.spawn(.{ .argv = args, .stdin = &input.reader, .stdout = &output.writer });
    defer {
        if (!child.reaped) {
            child.kill() catch {};
            if (child.pending == null) _ = child.wait(&loop, .{}) catch @panic("cleanup wait failed");
            const result = one(&loop) catch @panic("cleanup reap failed");
            _ = child.complete(result);
        }
        child.deinit() catch @panic("child not retired");
    }
    try input.reader.close();
    try output.writer.close();
    var write: mox_io.Pipe.Transfer = .{ .end = &input.writer, .write_buffer = "zebra\napple\nmango\n" };
    _ = try write.submit(&loop, .{});
    const written = try one(&loop);
    _ = write.complete(written);
    if (written.status != .ok or written.bytes != write.write_buffer.len) return error.WriteFailed;
    try input.writer.close();
    var print_buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &print_buffer);
    while (true) {
        var bytes: [1024]u8 = undefined;
        var read: mox_io.Pipe.Transfer = .{ .end = &output.reader, .read_buffer = &bytes };
        _ = try read.submit(&loop, .{});
        const result = try one(&loop);
        _ = read.complete(result);
        if (result.status != .ok) return error.ReadFailed;
        try writer.interface.writeAll(bytes[0..result.bytes]);
        if (read.eof) break;
    }
    try writer.interface.flush();
    _ = try child.wait(&loop, .{});
    const result = try one(&loop);
    _ = child.complete(result);
    if (result.status != .ok or child.termination.?.exited != 0) return error.ChildFailed;
}
