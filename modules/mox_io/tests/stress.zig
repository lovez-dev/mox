//! Bounded native stress: cancellation races, full pools and resource generations.

const mox_io = @import("mox_io");

const t = mox_io.types;
const channels = 16;
const payload_bytes = 257;
const cycles = 512;

const Pair = struct { client: t.Handle, peer: t.Handle };

fn sameId(a: t.OpId, b: t.OpId) bool {
    return a.index == b.index and a.generation == b.generation;
}

fn sameHandle(a: t.Handle, b: t.Handle) bool {
    return a.index == b.index and a.generation == b.generation;
}

fn gather(loop: anytype, results: []t.Completion) !void {
    const deadline = loop.now() + 10_000_000_000;
    var count: usize = 0;
    while (count < results.len) {
        if (loop.now() >= deadline) {
            @import("std").debug.print("stress timeout delivered={d}/{d} stats={any}\n", .{ count, results.len, loop.stats() });
            for (loop.operations.slots, loop.operations.requests) |slot, request| {
                if (slot.state != .free and slot.state != .retired)
                    @import("std").debug.print("pending kind={s} state={s} tag={d} progress={d} reason={any}\n", .{ @tagName(request.kind), @tagName(slot.state), request.options.tag, slot.progress, slot.reason });
            }
            return error.StressTimeout;
        }
        const received = try loop.poll(results[count..], .{ .until = deadline });
        for (results[count..][0..received]) |result| if (result.status == .failed) {
            @import("std").debug.print("stress native failure kind={s} code={d} library={any}\n", .{ @tagName(result.kind), result.native_error, result.library_error });
            return error.NativeOperationFailed;
        };
        count += received;
    }
}

fn drain(loop: anytype) !void {
    loop.shutdown() catch |err| {
        if (err != error.NativeFailure) return err;
    };
    const deadline = loop.now() + 10_000_000_000;
    var results: [64]t.Completion = undefined;
    while (true) {
        const stats = loop.stats();
        if (stats.active_operations == 0 and stats.active_resources == 0 and stats.completions_queued == 0) break;
        if (loop.now() >= deadline) return error.ShutdownTimeout;
        _ = try loop.poll(&results, .{ .until = deadline });
    }
    try loop.deinit();
}

fn connectPair(loop: anytype, listener: t.Handle) !Pair {
    const client = try loop.openTcp(.ipv4);
    _ = try loop.accept(listener, .{});
    _ = try loop.connect(client, try loop.localAddress(listener), .{});
    var results: [2]t.Completion = undefined;
    try gather(loop, &results);
    var peer: ?t.Handle = null;
    for (results) |result| {
        if (result.status != .ok) return error.ConnectionFailed;
        if (result.kind == .accept) peer = result.accepted;
    }
    try loop.noDelay(client, true);
    try loop.noDelay(peer orelse return error.AcceptMissing, true);
    return .{ .client = client, .peer = peer.? };
}

fn recycle(loop: anytype, listener: t.Handle, old: Pair) !Pair {
    var buffers: [2][1]u8 = undefined;
    _ = try loop.recv(old.client, &buffers[0], .{ .tag = 0 });
    _ = try loop.recv(old.peer, &buffers[1], .{ .tag = 1 });
    try loop.pump(.none);
    try loop.close(old.client, .cancel, 2);
    try loop.close(old.peer, .cancel, 3);
    var results: [4]t.Completion = undefined;
    try gather(loop, &results);
    var seen: u8 = 0;
    for (results) |result| {
        if (result.tag >= 4) return error.UnexpectedCompletion;
        const bit = @as(u8, 1) << @intCast(result.tag);
        if (seen & bit != 0) return error.DuplicateCompletion;
        if (result.tag < 2) {
            if (result.kind != .recv or result.status != .canceled or result.bytes != 0) return error.CancelMismatch;
        } else {
            if (result.kind != .close or result.status != .ok or seen & (@as(u8, 1) << @intCast(result.tag - 2)) == 0) return error.CloseOrder;
        }
        seen |= bit;
    }
    if (seen != 15) return error.MissingCompletion;
    if (loop.localAddress(old.client)) |_| return error.StaleHandleAccepted else |err| {
        if (err != error.StaleHandle) return err;
    }
    if (loop.localAddress(old.peer)) |_| return error.StaleHandleAccepted else |err| {
        if (err != error.StaleHandle) return err;
    }
    const next = try connectPair(loop, listener);
    if (sameHandle(next.client, old.client) or sameHandle(next.peer, old.peer)) return error.GenerationReused;
    return next;
}

pub fn network(comptime Backend: type) !void {
    return networkRun(Backend, cycles, 16);
}

/// Timed tests use longer sessions to avoid exhausting ephemeral ports in TIME_WAIT.
pub fn networkRun(comptime Backend: type, rounds: usize, recycle_interval: usize) !void {
    const Loop = mox_io.Loop(Backend);
    var source: [channels][payload_bytes]u8 align(64) = undefined;
    var target: [channels][payload_bytes]u8 align(64) = undefined;
    var pairs: [channels]Pair = undefined;
    var reads: [channels]t.OpId = undefined;
    var writes: [channels]t.OpId = undefined;
    var loop: Loop = undefined;
    try loop.init(mox_io.mem.PageAllocator.allocator(), .{
        .operations = channels * 2,
        .resources = channels * 2 + 1,
        .events = 1,
        .inbox = 2,
        .file_threads = 0,
    });
    var active = true;
    defer if (active) {
        drain(&loop) catch @panic("stress cleanup failed");
    };
    const listener = try loop.listen(t.Address.loopback(0), channels);
    for (&pairs) |*pair| pair.* = try connectPair(&loop, listener);
    const baseline = loop.stats().memory;
    for (0..rounds) |cycle| {
        for (&source, &target, pairs, 0..) |*input, *output, pair, channel| {
            for (input, 0..) |*byte, index| byte.* = @truncate(index *% 31 +% cycle *% 17 +% channel);
            @memset(output, 0xcc);
            reads[channel] = try loop.recvExact(pair.peer, output, .{ .tag = channel * 2 });
            writes[channel] = try loop.sendAll(pair.client, input, .{ .tag = channel * 2 + 1 });
        }
        try loop.pump(.none);
        for (reads, 0..) |id, channel| if ((cycle + channel) & 1 == 0) {
            _ = try loop.cancel(id);
        };
        var results: [channels * 2]t.Completion = undefined;
        try gather(&loop, &results);
        var progress: [channels]usize = @splat(0);
        var seen: u64 = 0;
        for (results) |result| {
            if (result.tag >= channels * 2) return error.UnexpectedCompletion;
            const bit = @as(u64, 1) << @intCast(result.tag);
            if (seen & bit != 0) return error.DuplicateCompletion;
            seen |= bit;
            const channel = result.tag / 2;
            const id = result.id orelse return error.OperationMissing;
            if (result.tag & 1 != 0) {
                if (!sameId(id, writes[channel]) or result.kind != .send or result.status != .ok or result.bytes != payload_bytes) return error.SendMismatch;
            } else {
                if (!sameId(id, reads[channel]) or result.kind != .recv or result.bytes > payload_bytes) return error.ReadMismatch;
                if (result.status != .ok and !(result.status == .canceled and (cycle + channel) & 1 == 0)) return error.CancelMismatch;
                if (result.status == .ok and result.bytes != payload_bytes) return error.ShortTransfer;
                if (!mox_io.mem.bytes.equal(source[channel][0..result.bytes], target[channel][0..result.bytes])) return error.DataMismatch;
                progress[channel] = result.bytes;
            }
        }
        if (seen != (@as(u64, 1) << (channels * 2)) - 1) return error.MissingCompletion;
        // A canceled receive may have consumed a prefix. Drain exactly the remainder.
        var pending: usize = 0;
        for (pairs, progress, 0..) |pair, done, channel| {
            if (done == payload_bytes) continue;
            reads[channel] = try loop.recvExact(pair.peer, target[channel][done..], .{ .tag = channel });
            pending += 1;
        }
        var remainder: [channels]t.Completion = undefined;
        try gather(&loop, remainder[0..pending]);
        seen = 0;
        for (remainder[0..pending]) |result| {
            if (result.tag >= channels) return error.UnexpectedCompletion;
            const channel = result.tag;
            const bit = @as(u64, 1) << @intCast(channel);
            if (seen & bit != 0 or !sameId(result.id orelse return error.OperationMissing, reads[channel])) return error.DuplicateCompletion;
            seen |= bit;
            if (result.status != .ok or result.bytes != payload_bytes - progress[channel]) return error.ReadMismatch;
        }
        for (source, target) |input, output| if (!mox_io.mem.bytes.equal(&input, &output)) return error.DataMismatch;
        const stats = loop.stats();
        if (stats.active_operations != 0 or stats.completions_queued != 0) return error.OutstandingOperation;
        if (stats.memory.allocations != baseline.allocations or stats.memory.live_bytes != baseline.live_bytes) return error.SteadyAllocation;
        if (cycle % recycle_interval == recycle_interval - 1) {
            const channel = (cycle / recycle_interval) % channels;
            pairs[channel] = try recycle(&loop, listener, pairs[channel]);
        }
    }
    const final = loop.stats();
    if (final.bytes_written != rounds * channels * payload_bytes or final.bytes_read != final.bytes_written) return error.ByteAccounting;
    if (final.operation_high_water != channels * 2 or final.canceled == 0 or final.native.cancellations == 0 or final.native.workers != 0) return error.StatsMismatch;
    try drain(&loop);
    active = false;
    if (loop.stats().memory.live_bytes != 0 or loop.stats().memory.releases != 1) return error.MemoryLeak;
}

fn backend(comptime Backend: type) !void {
    try network(Backend);
    const Suite = @import("integration/native.zig").Suite(Backend);

    // Repeat worker attachment, file lifecycle, datagrams and producer teardown.
    for (0..4) |_| try Suite.repeat();
}

test "native bounded stress preserves cancellation, generations and allocation counts" {
    backend(mox_io.DefaultBackend) catch |err| {
        @import("std").debug.print("stress backend={s} error={s}\n", .{ @typeName(mox_io.DefaultBackend), @errorName(err) });
        return err;
    };
}

test "io_uring bounded stress preserves cancellation, generations and allocation counts" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    if (!try mox_io.backends.Uring.probe()) return error.SkipZigTest;
    backend(mox_io.backends.Uring) catch |err| {
        @import("std").debug.print("stress backend=io_uring error={s}\n", .{@errorName(err)});
        return err;
    };
}
