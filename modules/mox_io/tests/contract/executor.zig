//! Bounded executor admission, cancellation and retirement contracts.

const mox_io = @import("mox_io");
const testing = @import("std").testing;

const c = mox_io.backend_common;
const t = mox_io.types;

const Gate = struct {
    mutex: mox_io.sync.Mutex = .{},
    condition: mox_io.sync.Condition = .{},
    entered: u32 = 0,
    released: bool = false,

    fn release(self: *Gate) void {
        self.mutex.lock();
        self.released = true;
        self.condition.broadcast();
        self.mutex.unlock();
    }
};

fn perform(request: *c.Request, _: []u8) c.Event {
    const gate: *Gate = @ptrFromInt(request.options.tag);
    gate.mutex.lock();
    @atomicStore(u32, &gate.entered, 1, .release);
    while (!gate.released) gate.condition.wait(&gate.mutex);
    gate.mutex.unlock();
    request.read_buffer[0] = 0x7f;
    return .{ .id = request.id, .bytes = 1 };
}

fn wake(_: *anyopaque) void {}

test "shared workers skip queued cancellations and retire running buffer access" {
    var gate: Gate = .{};
    try gate.mutex.init();
    defer gate.mutex.deinit();
    try gate.condition.init();
    defer gate.condition.deinit();
    var executor: mox_io.fs.Executor = undefined;
    try executor.init(mox_io.mem.PageAllocator.allocator(), .{ .jobs = 2, .clients = 1, .threads = 1, .path_capacity = 32 });
    var client = try executor.attach(2, 32, perform, &gate, wake);
    var first: [1]u8 = .{0};
    var second: [1]u8 = .{0};
    var requests = [_]c.Request{
        .{ .id = .{ .index = 0, .generation = 1 }, .handle = t.invalid_handle, .native = 0, .kind = .read, .options = .{ .tag = @intFromPtr(&gate) }, .read_buffer = &first },
        .{ .id = .{ .index = 1, .generation = 1 }, .handle = t.invalid_handle, .native = 0, .kind = .read, .options = .{ .tag = @intFromPtr(&gate) }, .read_buffer = &second },
    };
    try client.submit(&requests[0]);
    const deadline = mox_io.os.now() + 5_000_000_000;
    while (@atomicLoad(u32, &gate.entered, .acquire) == 0) {
        if (mox_io.os.now() >= deadline) {
            gate.release();
            return error.WorkerTimeout;
        }
        mox_io.sync.Thread.yield();
    }
    try client.submit(&requests[1]);
    client.cancel(requests[0].id);
    client.cancel(requests[1].id);
    var results: [2]c.Event = undefined;
    try testing.expect(client.poll(&results) == 0);
    gate.release();
    var count: usize = 0;
    while (count != 2) {
        if (mox_io.os.now() >= deadline) return error.WorkerTimeout;
        count += client.poll(results[count..]);
        mox_io.sync.Thread.yield();
    }
    try testing.expect(results[0].status == .ok and results[0].bytes == 1 and first[0] == 0x7f);
    try testing.expect(results[1].status == .canceled and second[0] == 0);
    try testing.expect(executor.stats().canceled == 2 and executor.stats().jobs_active == 0);
    client.deinit();
    try executor.deinit();
    try testing.expect(executor.stats().memory.live_bytes == 0);
}
