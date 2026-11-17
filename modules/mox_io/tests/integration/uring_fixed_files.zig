//! Registered io_uring descriptors retain normal completion and close lifetimes.

const std = @import("std");
const mox_io = @import("mox_io");

const testing = std.testing;
const t = mox_io.types;
const Loop = mox_io.Loop(mox_io.backends.Uring);

fn init(loop: *Loop, resources: u32) !void {
    loop.init(mox_io.mem.PageAllocator.allocator(), .{
        .operations = 8,
        .resources = resources,
        .events = 8,
        .file_threads = 1,
        .uring_fixed_files = true,
    }) catch |err| {
        if (err == error.BackendUnavailable) return error.SkipZigTest;
        return err;
    };
    if (loop.stats().native.fixed_file_capacity == 0) {
        try loop.deinit();
        return error.SkipZigTest;
    }
    try testing.expectEqual(resources, loop.stats().native.fixed_file_capacity);
}

fn gather(loop: *Loop, results: []t.Completion) !void {
    const deadline = loop.now() + 5_000_000_000;
    var count: usize = 0;
    while (count < results.len) {
        if (loop.now() >= deadline) return error.TestTimeout;
        count += try loop.poll(results[count..], .{ .until = deadline });
    }
}

fn cleanup(loop: *Loop) !void {
    try loop.shutdown();
    var results: [16]t.Completion = undefined;
    const deadline = loop.now() + 5_000_000_000;
    while (loop.stats().active_resources != 0 or loop.stats().active_operations != 0 or loop.stats().completions_queued != 0) {
        if (loop.now() >= deadline) return error.DrainTimeout;
        _ = try loop.poll(&results, .{ .until = deadline });
    }
    try testing.expectEqual(@as(u32, 0), loop.stats().native.registered_files);
    const submissions = loop.stats().native.fixed_file_submissions;
    try loop.deinit();
    try testing.expectEqual(@as(usize, 0), loop.stats().memory.live_bytes);
    try testing.expectEqual(@as(u32, 0), loop.stats().native.fixed_file_capacity);
    try testing.expectEqual(@as(u32, 0), loop.stats().native.registered_files);
    try testing.expectEqual(submissions, loop.stats().native.fixed_file_submissions);
}

fn expectOk(results: []const t.Completion) !void {
    for (results) |result| try testing.expectEqual(t.Status.ok, result.status);
}

test "io_uring fixed files roll back failed adoption and retry failed unregister" {
    var loop: Loop = undefined;
    try init(&loop, 1);
    defer cleanup(&loop) catch unreachable;
    const Backend = mox_io.backends.Uring;
    const native = try Backend.socket(.tcp, .ipv4, null, 0);
    var caller_owned = true;
    defer if (caller_owned) {
        _ = Backend.closeNative(native, .tcp);
    };
    const allocations = loop.stats().memory.allocations;
    const ring_fd = loop.backend.ring.fd;
    {
        // Inject EBADF without closing the actual ring or invalidating its mappings.
        loop.backend.ring.fd = -1;
        defer loop.backend.ring.fd = ring_fd;
        const adoption = loop.adopt(native, .tcp, false);
        if (adoption) |_| {
            caller_owned = false;
        } else |_| {}
        try testing.expectError(error.NativeFailure, adoption);
        try testing.expectEqual(@as(u32, 0), loop.stats().active_resources);
        try testing.expectEqual(@as(u32, 0), loop.stats().native.registered_files);
        try testing.expectEqual(@as(i32, -1), loop.backend.fixed_files[0]);
    }
    // The failed adoption must leave the ordinary fd owned and usable by its caller.
    const handle = try loop.adopt(native, .tcp, false);
    caller_owned = false;
    try testing.expectEqual(@as(u32, 1), loop.stats().native.registered_files);
    {
        loop.backend.ring.fd = -1;
        defer loop.backend.ring.fd = ring_fd;
        try testing.expectError(error.NativeFailure, loop.close(handle, .cancel, 73));
        try testing.expectEqual(@as(u32, 1), loop.stats().active_resources);
        try testing.expectEqual(@as(u32, 1), loop.stats().native.registered_files);
        try testing.expectEqual(@as(u32, 1), loop.stats().closes_pending_retry);
        try testing.expectEqual(@as(i32, @intCast(native)), loop.backend.fixed_files[handle.index]);
    }
    var result: [1]t.Completion = undefined;
    try gather(&loop, &result);
    try testing.expect(result[0].kind == .close and result[0].status == .ok and result[0].tag == 73);
    try testing.expectEqual(@as(u32, 0), loop.stats().active_resources);
    try testing.expectEqual(@as(u32, 0), loop.stats().native.registered_files);
    try testing.expectEqual(@as(u32, 0), loop.stats().closes_pending_retry);
    try testing.expectEqual(@as(u64, 1), loop.stats().close_failures);
    try testing.expectEqual(@as(u64, 1), loop.stats().close_retries);
    try testing.expectEqual(allocations, loop.stats().memory.allocations);
}

test "io_uring fixed files preserve file sync, close and resource slot reuse" {
    var loop: Loop = undefined;
    try init(&loop, 1);
    defer cleanup(&loop) catch unreachable;
    try std.Io.Dir.cwd().createDirPath(testing.io, "out");
    const path = "out/mox-io-fixed-file-test.bin";
    defer std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};
    const allocations = loop.stats().memory.allocations;
    var previous: ?t.Handle = null;
    for (0..16) |iteration| {
        const file = try loop.openFile(path, true, true);
        if (previous) |old| {
            try testing.expectEqual(old.index, file.index);
            try testing.expect(old.generation != file.generation);
        }
        try testing.expectEqual(@as(u32, 1), loop.stats().native.registered_files);
        const before = loop.stats().native.fixed_file_submissions;
        const source: [4]u8 = .{ @intCast(iteration), 0, 0x80, 0xff };
        var output: [4]u8 = undefined;
        var result: [1]t.Completion = undefined;
        _ = try loop.writeAllAt(file, &source, 7, .{});
        try gather(&loop, &result);
        try expectOk(&result);
        try testing.expectEqual(@as(usize, 4), result[0].bytes);
        _ = try loop.sync(file, .{});
        try gather(&loop, &result);
        try expectOk(&result);
        _ = try loop.readExactAt(file, &output, 7, .{});
        try gather(&loop, &result);
        try expectOk(&result);
        try testing.expectEqualSlices(u8, &source, &output);
        try testing.expect(loop.stats().native.fixed_file_submissions >= before + 3);
        const before_close = loop.stats().native.fixed_file_submissions;
        try loop.close(file, .drain, 91);
        try testing.expectEqual(@as(u32, 0), loop.stats().native.registered_files);
        try gather(&loop, &result);
        try expectOk(&result);
        try testing.expect(result[0].kind == .close and result[0].tag == 91);
        // CLOSE must target the ordinary fd after its registered reference is removed.
        try testing.expectEqual(before_close, loop.stats().native.fixed_file_submissions);
        previous = file;
    }
    try testing.expectEqual(allocations, loop.stats().memory.allocations);
}

test "io_uring fixed files retire canceled TCP receives before close and EOF" {
    var loop: Loop = undefined;
    try init(&loop, 3);
    defer cleanup(&loop) catch unreachable;
    const listener = try loop.listen(t.Address.loopback(0), 8);
    const client = try loop.openTcp(.ipv4);
    _ = try loop.accept(listener, .{});
    _ = try loop.connect(client, try loop.localAddress(listener), .{});
    var connected: [2]t.Completion = undefined;
    try gather(&loop, &connected);
    try expectOk(&connected);
    var peer: ?t.Handle = null;
    for (connected) |result| if (result.accepted) |accepted| {
        peer = accepted;
    };
    const accepted = peer orelse return error.AcceptMissing;
    try testing.expectEqual(@as(u32, 3), loop.stats().native.registered_files);
    const allocations = loop.stats().memory.allocations;
    var bytes: [8]u8 = @splat(0xa5);
    const before = loop.stats().native.fixed_file_submissions;
    const receive = try loop.recv(accepted, &bytes, .{ .tag = 19 });
    try loop.pump(.none);
    // The peer sent no data: this request must have left the staged fast path.
    try testing.expectEqual(@as(usize, 1), loop.backend.native_pending);
    try testing.expectEqual(before + 1, loop.stats().native.fixed_file_submissions);
    _ = try loop.cancel(receive);
    try loop.close(accepted, .cancel, 20);
    try testing.expectEqual(@as(u32, 3), loop.stats().native.registered_files);
    var closed: [2]t.Completion = undefined;
    try gather(&loop, &closed);
    try testing.expect(closed[0].kind == .recv and closed[0].status == .canceled and closed[0].tag == 19);
    try testing.expect(closed[1].kind == .close and closed[1].status == .ok and closed[1].tag == 20);
    for (bytes) |byte| try testing.expectEqual(@as(u8, 0xa5), byte);
    try testing.expectEqual(@as(u32, 2), loop.stats().native.registered_files);
    _ = try loop.recv(client, &bytes, .{});
    var eof: [1]t.Completion = undefined;
    try gather(&loop, &eof);
    // A leaked registered reference would keep the peer socket alive and hide EOF.
    try testing.expect(eof[0].status == .eof and eof[0].bytes == 0);
    const reused = try loop.openTcp(.ipv4);
    try testing.expectEqual(accepted.index, reused.index);
    try testing.expect(accepted.generation != reused.generation);
    try testing.expectEqual(@as(u32, 3), loop.stats().native.registered_files);
    try testing.expectEqual(allocations, loop.stats().memory.allocations);
}

test "io_uring fixed files preserve UDP truncation and empty datagrams" {
    var loop: Loop = undefined;
    try init(&loop, 2);
    defer cleanup(&loop) catch unreachable;
    const sender = try loop.bindUdp(t.Address.loopback(0));
    const receiver = try loop.bindUdp(t.Address.loopback(0));
    const destination = try loop.localAddress(receiver);
    const source = try loop.localAddress(sender);
    const allocations = loop.stats().memory.allocations;
    const before = loop.stats().native.fixed_file_submissions;
    var bytes: [3]u8 = undefined;
    for ([_][]const u8{ "abcdef", "" }) |payload| {
        _ = try loop.recvFrom(receiver, &bytes, .{});
        _ = try loop.sendTo(sender, payload, destination, .{});
        var results: [2]t.Completion = undefined;
        try gather(&loop, &results);
        try expectOk(&results);
        for (results) |result| {
            if (result.kind == .recv_from) {
                try testing.expectEqual(@min(payload.len, bytes.len), result.bytes);
                try testing.expectEqual(payload.len > bytes.len, result.truncated);
                try testing.expectEqual(source.port, result.peer.port);
                try testing.expectEqualSlices(u8, payload[0..result.bytes], bytes[0..result.bytes]);
            } else try testing.expectEqual(payload.len, result.bytes);
        }
    }
    try testing.expectEqual(before + 4, loop.stats().native.fixed_file_submissions);
    try testing.expectEqual(allocations, loop.stats().memory.allocations);
}

test "io_uring fixed files release failed and canceled async open reservations" {
    var loop: Loop = undefined;
    try init(&loop, 1);
    defer cleanup(&loop) catch unreachable;
    try std.Io.Dir.cwd().createDirPath(testing.io, "out");
    const path = "out/mox-io-fixed-async-open.bin";
    defer std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};
    const allocations = loop.stats().memory.allocations;
    const canceled = try loop.openFileAsync(path, .{ .access = .read_write, .creation = .create_always }, .{});
    _ = try loop.cancel(canceled);
    var result: [1]t.Completion = undefined;
    try gather(&loop, &result);
    try testing.expect(result[0].status == .canceled and result[0].opened == null);
    try testing.expectEqual(@as(u32, 0), loop.stats().native.registered_files);
    // A successful open must still fit after the hidden reservation is released.
    _ = try loop.openFileAsync(path, .{ .access = .read_write, .creation = .create_always }, .{});
    try gather(&loop, &result);
    try expectOk(&result);
    const file = result[0].opened orelse return error.OpenMissing;
    try testing.expectEqual(@as(u32, 1), loop.stats().native.registered_files);
    try loop.close(file, .drain, 0);
    try gather(&loop, &result);
    try expectOk(&result);
    // Using a regular file as a directory reliably produces ENOTDIR.
    _ = try loop.openFileAsync(path ++ "/child", .{}, .{});
    try gather(&loop, &result);
    try testing.expect(result[0].status == .failed and result[0].opened == null);
    try testing.expectEqual(@as(u32, 0), loop.stats().native.registered_files);
    try testing.expectEqual(@as(u32, 0), loop.stats().active_resources);
    try testing.expectEqual(allocations, loop.stats().memory.allocations);
}
