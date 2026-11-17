//! Concurrent owners exercise allocator snapshots and shared executor retirement.

const mox_io = @import("mox_io");
const testing = @import("std").testing;

const c = mox_io.backend_common;
const t = mox_io.types;
const FakeLoop = mox_io.Loop(@import("../support/fake_backend.zig"));

const AllocationOwner = struct { shared: *mox_io.mem.SharedTrackingAllocator, index: usize, failed: u32 = 0 };

fn allocate(context: *anyopaque) void {
    const owner: *AllocationOwner = @ptrCast(@alignCast(context));
    allocationWork(owner) catch {
        @atomicStore(u32, &owner.failed, 1, .release);
    };
}

fn allocationWork(owner: *AllocationOwner) !void {
    const allocator = owner.shared.allocator();
    for (0..128) |round| {
        const size = 17 + (round + owner.index) % 257;
        const block = try allocator.allocate(size, 64);
        {
            defer allocator.release(block);
            for (block.bytes[0..size], 0..) |*byte, index| byte.* = @truncate(index + owner.index);
            const snapshot = owner.shared.stats();
            if (snapshot.live_bytes < size or snapshot.live_reserved_bytes < block.bytes.len) return error.AccountingMismatch;
            for (block.bytes[0..size], 0..) |byte, index| if (byte != @as(u8, @truncate(index + owner.index))) return error.DataMismatch;
        }
        if (round & 15 == 0) {
            var loop: FakeLoop = undefined;
            try loop.init(allocator, .{ .operations = 1, .resources = 1, .events = 1, .inbox = 0, .file_threads = 0 });
            try loop.deinit();
            if (loop.stats().memory.allocations != 1 or loop.stats().memory.live_bytes != 0) return error.AccountingMismatch;
        }
    }
}

test "shared allocation accounting stays exact across concurrent loop owners" {
    var shared: mox_io.mem.SharedTrackingAllocator = undefined;
    try shared.init(mox_io.mem.PageAllocator.allocator());
    defer shared.deinit() catch @panic("shared allocator cleanup failed");
    const held = try shared.allocator().allocate(1, 64);
    var held_live = true;
    defer if (held_live) shared.allocator().release(held);
    var owners: [4]AllocationOwner = undefined;
    var threads: [4]mox_io.sync.Thread = undefined;
    var started: usize = 0;
    defer for (threads[0..started]) |*thread| thread.join();
    for (&owners, &threads, 0..) |*owner, *thread, index| {
        owner.* = .{ .shared = &shared, .index = index };
        try thread.start(allocate, owner);
        started += 1;
    }
    for (threads[0..started]) |*thread| thread.join();
    started = 0;
    for (&owners) |*owner| try testing.expect(@atomicLoad(u32, &owner.failed, .acquire) == 0);
    const busy = shared.stats();
    try testing.expect(busy.allocations == 1 + 4 * (128 + 8) and busy.releases == busy.allocations - 1);
    try testing.expect(busy.live_bytes == 1 and busy.failures == 0);
    try testing.expectError(error.Busy, shared.deinit());
    shared.allocator().release(held);
    held_live = false;
    const final = shared.stats();
    try testing.expect(final.allocations == final.releases and final.live_bytes == 0 and final.live_reserved_bytes == 0);
}

const ExecutorOwner = struct { executor: *mox_io.fs.Executor, index: usize, failed: u32 = 0, wakeups: u64 = 0 };

fn wake(context: *anyopaque) void {
    const owner: *ExecutorOwner = @ptrCast(@alignCast(context));
    _ = @atomicRmw(u64, &owner.wakeups, .Add, 1, .monotonic);
}

fn perform(request: *c.Request, _: []u8) c.Event {
    for (request.read_buffer, 0..) |*byte, index| byte.* = @truncate(index + request.options.tag);
    return .{ .id = request.id, .bytes = request.read_buffer.len };
}

fn execute(context: *anyopaque) void {
    const owner: *ExecutorOwner = @ptrCast(@alignCast(context));
    for (0..64) |round| {
        executorRound(owner, round) catch {
            @atomicStore(u32, &owner.failed, 1, .release);
            return;
        };
    }
}

fn executorRound(owner: *ExecutorOwner, round: usize) !void {
    var buffers: [2][32]u8 = @splat(@splat(0xcc));
    var requests: [2]c.Request = undefined;
    var output: [2]c.Event = undefined;
    var client = try owner.executor.attach(2, 32, perform, owner, wake);
    var submitted: usize = 0;
    var consumed: usize = 0;
    defer {
        // An assertion failure still retires every borrowed request before detachment.
        for (requests[0..submitted]) |request| client.cancel(request.id);
        const deadline = mox_io.os.now() + 5_000_000_000;
        while (consumed < submitted) {
            if (mox_io.os.now() >= deadline) @panic("executor cleanup timed out");
            consumed += client.poll(output[0 .. submitted - consumed]);
            mox_io.sync.Thread.yield();
        }
        client.deinit();
    }
    for (&requests, &buffers, 0..) |*request, *buffer, index| {
        request.* = .{
            .id = .{ .index = @intCast(index), .generation = round + 1 },
            .handle = t.invalid_handle,
            .native = 0,
            .kind = .read,
            .options = .{ .tag = owner.index * 2 + index },
            .read_buffer = buffer,
        };
        try client.submit(request);
        submitted += 1;
    }
    client.cancel(requests[round & 1].id);
    const deadline = mox_io.os.now() + 5_000_000_000;
    while (consumed < submitted) {
        if (mox_io.os.now() >= deadline) return error.ExecutorTimeout;
        consumed += client.poll(output[consumed..]);
        mox_io.sync.Thread.yield();
    }
    var seen: u8 = 0;
    for (output) |event| {
        if (event.id.index >= 2 or event.id.generation != round + 1) return error.UnexpectedCompletion;
        const bit = @as(u8, 1) << @intCast(event.id.index);
        if (seen & bit != 0) return error.DuplicateCompletion;
        seen |= bit;
        if (event.status == .ok) {
            if (event.bytes != 32) return error.ShortTransfer;
            for (buffers[event.id.index], 0..) |byte, index| {
                if (byte != @as(u8, @truncate(index + owner.index * 2 + event.id.index))) return error.DataMismatch;
            }
        } else if (event.status == .canceled) {
            if (event.bytes != 0 or event.id.index != round & 1) return error.CancelMismatch;
            for (buffers[event.id.index]) |byte| if (byte != 0xcc) return error.CanceledBufferAccess;
        } else return error.UnexpectedStatus;
    }
    if (seen != 3) return error.MissingCompletion;
}

test "shared executor clients submit, cancel and detach concurrently" {
    var executor_pool: mox_io.fs.Executor = undefined;
    try executor_pool.init(mox_io.mem.PageAllocator.allocator(), .{ .jobs = 8, .clients = 4, .threads = 2, .path_capacity = 32 });
    defer executor_pool.deinit() catch @panic("executor cleanup failed");
    var owners: [4]ExecutorOwner = undefined;
    var threads: [4]mox_io.sync.Thread = undefined;
    var started: usize = 0;
    defer for (threads[0..started]) |*thread| thread.join();
    for (&owners, &threads, 0..) |*owner, *thread, index| {
        owner.* = .{ .executor = &executor_pool, .index = index };
        try thread.start(execute, owner);
        started += 1;
    }
    for (threads[0..started]) |*thread| thread.join();
    started = 0;
    for (&owners) |*owner| try testing.expect(@atomicLoad(u32, &owner.failed, .acquire) == 0);
    const stats = executor_pool.stats();
    try testing.expect(stats.submitted == 4 * 64 * 2 and stats.completed == stats.submitted);
    try testing.expect(stats.clients == 0 and stats.jobs_active == 0 and stats.memory.allocations == 1);
}
