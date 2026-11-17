//! Loop ownership, identity, completion and shutdown contracts.

const mox_io = @import("mox_io");
const testing = @import("std").testing;
const Fake = @import("../support/fake_backend.zig");

const Loop = mox_io.Loop(Fake);
const t = mox_io.types;

test "allocator accounting, alignment and failed allocation" {
    var tracker: mox_io.mem.TrackingAllocator = .{ .parent = mox_io.mem.PageAllocator.allocator() };
    const alloc = tracker.allocator();
    const block = try alloc.allocate(257, 64);
    var arena: mox_io.mem.Arena = .{ .bytes = block.bytes };
    const values = try arena.allocate(u64, 16);
    try testing.expect(@intFromPtr(values.ptr) % 8 == 0);
    try testing.expect(tracker.stats().live_bytes == 257 and tracker.stats().allocations == 1);
    alloc.release(block);
    try testing.expect(tracker.stats().live_bytes == 0 and tracker.stats().live_reserved_bytes == 0);
    try testing.expect(tracker.stats().peak_bytes == 257 and tracker.stats().releases == 1);
    var failing: mox_io.mem.TrackingAllocator = .{ .parent = FailingAllocator.allocator() };
    try testing.expectError(error.OutOfMemory, failing.allocator().allocate(128, 64));
    try testing.expect(failing.stats().failures == 1 and failing.stats().allocations == 0 and failing.stats().live_bytes == 0);
    try testing.expectError(error.InvalidAlignment, alloc.allocate(128, 3));
}

const FailingAllocator = struct {
    fn allocator() mox_io.mem.Allocator {
        return .{ .context = null, .vtable = &.{ .allocate = allocate, .release = release } };
    }

    fn allocate(_: ?*anyopaque, _: usize, _: usize) error{OutOfMemory}!mox_io.mem.Allocation {
        return error.OutOfMemory;
    }

    fn release(_: ?*anyopaque, _: mox_io.mem.Allocation) void {
        @panic("unallocated memory released");
    }
};

const FailingBackend = struct {
    pub const layout = Fake.layout;

    pub fn init(_: *@This(), _: *mox_io.mem.Arena, _: t.Options, _: []mox_io.backend_common.Request) mox_io.Error!void {
        return error.BackendUnavailable;
    }

    pub fn stats(_: *const @This()) mox_io.backend_common.NativeStats {
        return .{};
    }
};

test "failed loop initialization releases all owned memory" {
    var loop: Loop = undefined;
    try testing.expectError(error.OutOfMemory, loop.init(FailingAllocator.allocator(), .{}));
    try testing.expect(loop.stats().memory.failures == 1 and loop.stats().memory.live_bytes == 0);
    var outer: mox_io.mem.TrackingAllocator = .{ .parent = mox_io.mem.PageAllocator.allocator() };
    var native_failure: mox_io.Loop(FailingBackend) = undefined;
    try testing.expectError(error.BackendUnavailable, native_failure.init(outer.allocator(), .{}));
    try testing.expect(outer.stats().allocations == 1 and outer.stats().releases == 1 and outer.stats().live_bytes == 0);
    try testing.expect(native_failure.stats().memory.live_bytes == 0);
}

test "loop allocation is scoped and steady-state allocation-free" {
    var loop: Loop = undefined;
    try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 4, .resources = 2 });
    const file = try loop.adopt(41, .file, false);
    var bytes: [4]u8 = undefined;
    const id = try loop.readAt(file, &bytes, 0, .{ .tag = 19 });
    try loop.pump(.none);
    loop.backend.complete(.{ .id = id, .bytes = 4 });
    var results: [4]t.Completion = undefined;
    const count = try loop.poll(&results, .none);
    try testing.expect(count == 1 and results[0].tag == 19 and results[0].bytes == 4);
    const stats = loop.stats();
    try testing.expect(stats.memory.allocations == 1 and stats.memory.releases == 0);
    try testing.expect(stats.active_operations == 0 and stats.operation_high_water == 1 and stats.bytes_read == 4);
    try loop.close(file, .cancel, 0);
    _ = try loop.poll(&results, .none);
    try loop.deinit();
    try testing.expect(loop.stats().memory.live_bytes == 0 and loop.stats().memory.releases == 1);
}

test "late native cancellation holds buffers and resource ownership" {
    var loop: Loop = undefined;
    try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 1, .resources = 1 });
    loop.backend.cancel_immediately = false;
    const stream = try loop.adopt(41, .tcp, true);
    var bytes: [8]u8 = undefined;
    const id = try loop.recv(stream, &bytes, .{});
    try loop.pump(.none);
    _ = try loop.cancel(id);
    try loop.close(stream, .cancel, 0);
    try testing.expect(loop.stats().active_operations == 1 and loop.stats().completions_queued == 0);
    try testing.expectError(error.Busy, loop.deinit());
    loop.backend.complete(.{ .id = id, .status = .canceled });
    var results: [2]t.Completion = undefined;
    try testing.expect(try loop.poll(&results, .none) == 2);
    try testing.expect(results[0].status == .canceled and results[1].kind == .close);
    try loop.deinit();
}

test "close completes behind dependent operations at full capacity" {
    var loop: Loop = undefined;
    try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 1, .resources = 1 });
    const stream = try loop.adopt(41, .tcp, true);
    var bytes: [8]u8 = undefined;
    _ = try loop.recv(stream, &bytes, .{ .tag = 7 });
    try testing.expectError(error.Capacity, loop.send(stream, "x", .{}));
    try loop.close(stream, .cancel, 8);
    var results: [1]t.Completion = undefined;
    try testing.expect(try loop.poll(&results, .none) == 1);
    try testing.expect(results[0].kind == .recv and results[0].status == .canceled);
    try testing.expectError(error.Busy, loop.deinit());
    try testing.expect(try loop.poll(&results, .none) == 1);
    try testing.expect(results[0].kind == .close and results[0].tag == 8);
    try loop.deinit();
}

test "deadline removes pending operation and admits no native work" {
    var loop: Loop = undefined;
    try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 4, .resources = 1 });
    const file = try loop.adopt(41, .file, false);
    var bytes: [1]u8 = undefined;
    _ = try loop.readAt(file, &bytes, 0, .{ .deadline = 1 });
    var results: [4]t.Completion = undefined;
    try testing.expect(try loop.poll(&results, .none) == 1);
    try testing.expect(results[0].status == .timed_out and loop.stats().native.submissions == 0);
    try testing.expect(loop.stats().timers_active == 0);
    try loop.close(file, .cancel, 0);
    _ = try loop.poll(&results, .none);
    try loop.deinit();
}

test "consumed operation IDs reject stale cancellation" {
    var loop: Loop = undefined;
    try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 1, .resources = 1 });
    const file = try loop.adopt(41, .file, false);
    var bytes: [1]u8 = undefined;
    const first = try loop.readAt(file, &bytes, 0, .{});
    _ = try loop.cancel(first);
    var results: [2]t.Completion = undefined;
    _ = try loop.poll(&results, .none);
    const next = try loop.readAt(file, &bytes, 0, .{});
    try testing.expect(first.index == next.index and first.generation != next.generation);
    try testing.expectError(error.StaleOperation, loop.cancel(first));
    _ = try loop.cancel(next);
    try loop.close(file, .cancel, 0);
    _ = try loop.poll(&results, .none);
    try loop.deinit();
}

test "compound transfers preserve progress over multiple completions" {
    var loop: Loop = undefined;
    try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 1, .resources = 1 });
    const file = try loop.adopt(41, .file, false);
    const id = try loop.writeAllAt(file, "abcdef", 10, .{});
    try loop.pump(.none);
    loop.backend.complete(.{ .id = id, .bytes = 2 });
    try loop.pump(.none);
    try testing.expect(loop.operations.requests[id.index].offset == 12);
    try loop.pump(.none);
    loop.backend.complete(.{ .id = id, .bytes = 4 });
    var results: [2]t.Completion = undefined;
    try testing.expect(try loop.poll(&results, .none) == 1);
    try testing.expect(results[0].bytes == 6 and loop.stats().bytes_written == 6);
    try loop.close(file, .cancel, 0);
    _ = try loop.poll(&results, .none);
    try loop.deinit();
}

test "accept reserves a child resource before native submission" {
    var loop: Loop = undefined;
    try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 2, .resources = 1 });
    const listener = try loop.listen(t.Address.loopback(0), 8);
    try testing.expectError(error.Capacity, loop.accept(listener, .{}));
    try testing.expect(loop.stats().active_operations == 0 and loop.stats().native.submissions == 0);
    var results: [1]t.Completion = undefined;
    try loop.close(listener, .cancel, 0);
    _ = try loop.poll(&results, .none);
    try loop.deinit();
}

fn increment(context: ?*anyopaque, _: *Loop) void {
    const counter: *usize = @ptrCast(@alignCast(context.?));
    counter.* += 1;
}

test "bounded inbox rejects overflow and drains accepted tasks after sealing" {
    var loop: Loop = undefined;
    try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 1, .resources = 1, .events = 1, .inbox = 2 });
    var counter: usize = 0;
    const command: Loop.Command = .{ .task = .{ .context = &counter, .run = increment } };
    try loop.post(command);
    try loop.post(command);
    try testing.expectError(error.QueueFull, loop.post(command));
    try loop.pump(.none);
    try testing.expect(counter == 1 and loop.stats().inbox.queued == 1 and loop.stats().inbox.high_water == 2);
    try loop.closeInbox();
    try testing.expectError(error.Closing, loop.post(command));
    try testing.expectError(error.Busy, loop.deinit());
    try loop.pump(.none);
    try testing.expect(counter == 2 and loop.stats().inbox.processed == 2 and loop.stats().inbox.rejected == 2);
    try loop.deinit();
}

test "disabled inbox rejects tasks while owner pumps remain usable" {
    var loop: Loop = undefined;
    try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 1, .resources = 1, .inbox = 0 });
    defer loop.deinit() catch unreachable;
    var counter: usize = 0;
    const command: Loop.Command = .{ .task = .{ .context = &counter, .run = increment } };
    try testing.expectError(error.QueueFull, loop.post(command));
    try loop.pump(.none);
    try testing.expect(counter == 0 and loop.backend.last_duration.? == 0);
    try testing.expect(loop.stats().inbox.rejected == 1 and loop.stats().inbox.processed == 0);
    try loop.closeInbox();
    try testing.expectError(error.Closing, loop.post(command));
}

test "standalone timers complete and cancel without native work" {
    var loop: Loop = undefined;
    try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 2, .resources = 1 });
    _ = try loop.sleepUntil(1, 77);
    const canceled = try loop.sleepUntil(~@as(u64, 0), 88);
    _ = try loop.cancel(canceled);
    var results: [2]t.Completion = undefined;
    try testing.expect(try loop.poll(&results, .none) == 2);
    for (results) |result| {
        try testing.expect(result.kind == .timer and result.handle.index == t.none);
        try testing.expect(if (result.tag == 77) result.status == .ok else result.status == .canceled);
    }
    try testing.expect(loop.stats().native.submissions == 0 and loop.stats().timers_active == 0);
    try loop.deinit();
}

test "untimed pumps refresh cached time and preserve native wait modes" {
    var loop: Loop = undefined;
    try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 1, .resources = 1 });
    defer loop.deinit() catch unreachable;
    for ([_]t.Wait{ .none, .forever }) |wait| {
        const before = loop.now();
        loop.clock.cached = 0;
        try loop.pump(wait);
        try testing.expect(loop.cachedNow() >= before and loop.cachedNow() <= loop.now());
        switch (wait) {
            .none => try testing.expect(loop.backend.last_duration.? == 0),
            .forever => try testing.expect(loop.backend.last_duration == null),
            else => unreachable,
        }
    }
}

test "absolute waits use fresh time without scheduled operations" {
    var loop: Loop = undefined;
    try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 1, .resources = 1 });
    defer loop.deinit() catch unreachable;
    // An old cache must not lengthen a caller's absolute wait.
    loop.clock.cached = 0;
    try loop.pump(.{ .until = loop.now() + 1_000_000_000 });
    try testing.expect(loop.backend.last_duration.? <= 1_000_000_000);
    try loop.pump(.{ .until = 1 });
    try testing.expect(loop.backend.last_duration.? == 0);
}

test "queued completions and inbox tasks force nonblocking absolute waits" {
    var loop: Loop = undefined;
    try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 1, .resources = 1, .inbox = 2 });
    defer loop.deinit() catch unreachable;
    const file = try loop.adopt(41, .file, false);
    try loop.close(file, .drain, 19);
    var result: [1]t.Completion = undefined;
    const before = loop.now();
    loop.clock.cached = 0;
    try testing.expect(try loop.poll(&result, .{ .until = before + 1_000_000_000 }) == 1);
    try testing.expect(result[0].kind == .close and result[0].tag == 19);
    try testing.expect(loop.backend.last_duration.? == 0);
    try testing.expect(loop.cachedNow() >= before and loop.cachedNow() <= loop.now());

    var counter: usize = 0;
    const command: Loop.Command = .{ .task = .{ .context = &counter, .run = increment } };
    // Repeated progress stays nonblocking even while notifications are coalesced.
    for (0..4) |_| {
        try loop.post(command);
        try loop.pump(.{ .until = loop.now() + 1_000_000_000 });
        try testing.expect(loop.backend.last_duration.? == 0);
    }
    try testing.expect(counter == 4 and loop.stats().inbox.processed == 4);

    // After progress is drained, an absolute wait again uses a fresh timestamp.
    loop.clock.cached = 0;
    try loop.pump(.{ .until = loop.now() + 1_000_000_000 });
    try testing.expect(loop.backend.last_duration.? > 0 and loop.backend.last_duration.? <= 1_000_000_000);
}

test "nonblocking inbox pumps rearm notifications before returning to blocking waits" {
    var loop: Loop = undefined;
    try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 1, .resources = 1, .events = 1, .inbox = 2 });
    defer loop.deinit() catch unreachable;
    var counter: usize = 0;
    const command: Loop.Command = .{ .task = .{ .context = &counter, .run = increment } };

    try loop.post(command);
    try loop.pump(.none);
    try loop.pump(.none);
    try testing.expect(counter == 1 and @atomicLoad(u32, &loop.inbox.wake_pending, .acquire) == 1);

    // A second post may share the consumed wake while the owner keeps polling.
    try loop.post(command);
    try loop.pump(.{ .until = loop.now() + 1_000_000_000 });
    try testing.expect(counter == 2 and loop.backend.last_duration.? == 0);
    try testing.expect(@atomicLoad(u32, &loop.inbox.wake_pending, .acquire) == 1);

    // The first potentially blocking pump must rearm a future producer.
    try loop.pump(.forever);
    try testing.expect(loop.backend.last_duration == null);
    try testing.expect(@atomicLoad(u32, &loop.inbox.wake_pending, .acquire) == 0);
    try loop.post(command);
    try testing.expect(@atomicLoad(u32, &loop.inbox.wake_pending, .acquire) == 1);

    // Preparation also detects a task already published before its final recheck.
    try testing.expect(loop.inbox.prepareWait());
    try loop.pump(.none);
    try testing.expect(counter == 3 and loop.stats().inbox.queued == 0);
}

test "transient close failures retain ownership and retry without allocation" {
    var loop: Loop = undefined;
    try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 1, .resources = 1 });
    const descriptor = try loop.adopt(41, .file, false);
    loop.backend.close_failures = 1;
    try testing.expectError(error.NativeFailure, loop.close(descriptor, .cancel, 29));
    try testing.expect(loop.stats().closes_pending_retry == 1 and loop.stats().active_resources == 1);
    try testing.expectError(error.Busy, loop.deinit());
    var result: [1]t.Completion = undefined;
    const deadline_time = loop.now() + 100_000_000;
    while (try loop.poll(&result, .none) == 0) {
        if (loop.now() > deadline_time) return error.CloseRetryTimeout;
        mox_io.sync.Thread.yield();
    }
    try testing.expect(result[0].kind == .close and result[0].status == .ok and result[0].tag == 29);
    try testing.expect(loop.stats().close_failures == 1 and loop.stats().close_retries == 1 and loop.stats().closes_pending_retry == 0);
    try testing.expect(loop.stats().memory.allocations == 1);
    try loop.deinit();
}

test "late canceled opens retire hidden handles before reporting completion" {
    var loop: Loop = undefined;
    try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 1, .resources = 1 });
    loop.backend.cancel_immediately = false;
    const id = try loop.openFileAsync("hidden-file", .{}, .{});
    try loop.pump(.none);
    _ = try loop.cancel(id);
    loop.backend.complete(.{ .id = id, .accepted_native = 43 });
    var result: [1]t.Completion = undefined;
    try testing.expect(try loop.poll(&result, .none) == 1);
    try testing.expect(result[0].kind == .open and result[0].status == .canceled and result[0].opened == null);
    try testing.expect(loop.stats().active_resources == 0 and loop.stats().completed == 1 and loop.stats().canceled == 1);
    try loop.deinit();
}

test "exhausted generations retire slots without wrapping identities" {
    var loop: Loop = undefined;
    try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 2, .resources = 2 });
    const maximum = ~@as(u64, 0);
    loop.resources.slots[0].generation = maximum - 1;
    const last_handle = try loop.adopt(41, .file, false);
    try testing.expect(last_handle.generation == maximum);
    try loop.close(last_handle, .drain, 0);
    var results: [2]t.Completion = undefined;
    _ = try loop.poll(&results, .none);
    const file = try loop.adopt(42, .file, false);
    try testing.expect(file.index != last_handle.index and loop.resources.slots[last_handle.index].state == .retired);
    try testing.expectError(error.StaleHandle, loop.close(last_handle, .cancel, 0));
    loop.operations.slots[0].generation = maximum - 1;
    var buffer: [1]u8 = undefined;
    const last_operation = try loop.readAt(file, &buffer, 0, .{});
    try testing.expect(last_operation.generation == maximum);
    _ = try loop.cancel(last_operation);
    _ = try loop.poll(&results, .none);
    const operation = try loop.readAt(file, &buffer, 0, .{});
    try testing.expect(operation.index != last_operation.index and loop.operations.slots[last_operation.index].state == .retired);
    try testing.expectError(error.StaleOperation, loop.cancel(last_operation));
    _ = try loop.cancel(operation);
    try loop.close(file, .cancel, 0);
    try testing.expect(try loop.poll(&results, .none) == 2);
    try loop.deinit();
}

test "close follows all file dependencies despite reversed native results" {
    var loop: Loop = undefined;
    try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 4, .resources = 1, .events = 4 });
    const file = try loop.adopt(41, .file, false);
    var ids: [4]t.OpId = undefined;
    for (&ids, 0..) |*id, index| id.* = try loop.writeAt(file, "data", index * 4, .{ .tag = index });
    try loop.pump(.none);
    try loop.close(file, .drain, 4);
    for ([_]usize{ 2, 0, 3, 1 }) |index| loop.backend.complete(.{ .id = ids[index], .bytes = 4 });
    var results: [1]t.Completion = undefined;
    for ([_]usize{ 2, 0, 3, 1 }) |index| {
        try testing.expect(try loop.poll(&results, .none) == 1);
        try testing.expect(results[0].kind == .write and results[0].tag == index and results[0].status == .ok);
        try testing.expectError(error.Busy, loop.deinit());
    }
    try testing.expect(try loop.poll(&results, .none) == 1);
    try testing.expect(results[0].kind == .close and results[0].tag == 4);
    try loop.deinit();
}

test "cumulative statistics saturate while live allocation accounting stays exact" {
    const maximum = ~@as(u64, 0);
    var tracker: mox_io.mem.TrackingAllocator = .{ .parent = mox_io.mem.PageAllocator.allocator() };
    tracker.counters.allocations = maximum;
    tracker.counters.releases = maximum;
    const allocation = try tracker.allocator().allocate(128, 64);
    try testing.expect(tracker.stats().allocations == maximum and tracker.stats().live_bytes == 128);
    tracker.allocator().release(allocation);
    try testing.expect(tracker.stats().releases == maximum and tracker.stats().live_bytes == 0);
    var loop: Loop = undefined;
    try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 1, .resources = 1 });
    const file = try loop.adopt(41, .file, false);
    loop.counters.submissions = maximum;
    loop.counters.completed = maximum;
    loop.counters.bytes_written = maximum;
    const id = try loop.writeAt(file, "x", 0, .{});
    try loop.pump(.none);
    loop.backend.complete(.{ .id = id, .bytes = 1 });
    var result: [1]t.Completion = undefined;
    _ = try loop.poll(&result, .none);
    const stats = loop.stats();
    try testing.expect(stats.submissions == maximum and stats.completed == maximum and stats.bytes_written == maximum);
    try testing.expect(stats.active_operations == 0 and stats.memory.allocations == 1);
    try loop.close(file, .drain, 0);
    _ = try loop.poll(&result, .none);
    try loop.deinit();
}
