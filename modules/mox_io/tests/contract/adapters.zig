//! Stream state follows delivered terminal results rather than native progress.

const mox_io = @import("mox_io");
const testing = @import("std").testing;

const Loop = mox_io.Loop(@import("../support/fake_backend.zig"));
const Stream = mox_io.Stream(Loop);
const t = mox_io.types;

test "file stream cursor preserves partial EOF and cancellation progress" {
    var buffer: [8]u8 = undefined;
    var loop: Loop = undefined;
    try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 1, .resources = 1 });
    const file = try loop.adopt(41, .file, false);
    var stream = Stream.file(&loop, file, 7);
    const read = try stream.readExact(&buffer, .{});
    try testing.expectError(error.DirectionBusy, stream.seek(0));
    try testing.expectError(error.DirectionBusy, stream.write("x", .{}));
    try loop.pump(.none);
    loop.backend.complete(.{ .id = read, .bytes = 3 });
    try loop.pump(.none);
    try testing.expect(stream.cursor == 7 and loop.operations.requests[read.index].offset == 10);
    try loop.pump(.none);
    loop.backend.complete(.{ .id = read, .status = .eof, .bytes = 2 });
    var result: [1]t.Completion = undefined;
    try testing.expect(try loop.poll(&result, .none) == 1);
    var unrelated = result[0];
    unrelated.handle.generation += 1;
    try testing.expect(!stream.complete(unrelated) and stream.cursor == 7);
    try testing.expect(result[0].status == .eof and result[0].bytes == 5);
    try testing.expect(stream.complete(result[0]) and stream.cursor == 12);
    try testing.expect(!stream.complete(result[0]));
    loop.backend.cancel_immediately = false;
    const write = try stream.writeAll("abcd", .{});
    try loop.pump(.none);
    _ = try loop.cancel(write);
    loop.backend.complete(.{ .id = write, .bytes = 2 });
    try testing.expect(try loop.poll(&result, .none) == 1);
    try testing.expect(result[0].status == .canceled and result[0].bytes == 2);
    try testing.expect(stream.complete(result[0]) and stream.cursor == 14);
    try stream.seek(0x7fffffffffffffff);
    try testing.expectError(error.InvalidOptions, stream.readExact(buffer[0..2], .{}));
    try testing.expect(stream.reading == null);
    try loop.close(file, .drain, 0);
    _ = try loop.poll(&result, .none);
    try loop.deinit();
}

test "TCP stream keeps read and write completion ownership independent" {
    var buffer: [2]u8 = undefined;
    var loop: Loop = undefined;
    try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 2, .resources = 1 });
    const socket = try loop.adopt(42, .tcp, true);
    var stream = Stream.tcp(&loop, socket);
    const read = try stream.read(&buffer, .{});
    const write = try stream.write("ok", .{});
    try testing.expectError(error.DirectionBusy, stream.read(&buffer, .{}));
    try testing.expectError(error.DirectionBusy, stream.write("ok", .{}));
    try testing.expectError(error.InvalidResource, stream.seek(0));
    try loop.pump(.none);
    loop.backend.complete(.{ .id = write, .bytes = 2 });
    loop.backend.complete(.{ .id = read, .bytes = 2 });
    var results: [2]t.Completion = undefined;
    try testing.expect(try loop.poll(&results, .none) == 2);
    try testing.expect(stream.complete(results[0]) and stream.reading != null and stream.writing == null);
    try testing.expect(stream.complete(results[1]) and stream.reading == null and stream.cursor == 0);
    try loop.close(socket, .drain, 0);
    _ = try loop.poll(&results, .none);
    try loop.deinit();
}
