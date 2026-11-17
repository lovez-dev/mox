//! Parallel owner-local TCP round trips with a common measured start barrier.

const std = @import("std");
const mox_io = @import("mox_io");

const Runtime = mox_io.DefaultRuntime;
const Loop = Runtime.Loop;
const t = mox_io.types;

const Owner = struct {
    context: *Context,
    ended: u64 = 0,
    allocations: u64 = 0,
    thread: u64 = 0,
    source: []u8,
    echo: []u8,
    target: []u8,

    fn run(context: ?*anyopaque, worker: *Runtime.Worker) void {
        const self: *Owner = @ptrCast(@alignCast(context.?));
        self.measure(worker) catch |err| {
            @atomicStore(u32, &self.context.failed, 1, .release);
            worker.fail(err);
        };
    }

    fn measure(self: *Owner, worker: *Runtime.Worker) mox_io.Error!void {
        const loop = worker.loop();
        self.thread = mox_io.os.threadId();
        const listener = try loop.listen(t.Address.loopback(0), 8);
        const client = try loop.openTcp(.ipv4);
        _ = try loop.accept(listener, .{});
        _ = try loop.connect(client, try loop.localAddress(listener), .{});
        var output: [2]t.Completion = undefined;
        try gather(loop, &output);
        var peer: ?t.Handle = null;
        for (output) |result| if (result.kind == .accept) {
            peer = result.accepted;
        };
        const server = peer orelse return error.InvalidState;
        try loop.noDelay(client, true);
        try loop.noDelay(server, true);
        for (self.source, 0..) |*byte, index| byte.* = @truncate(index *% 37 +% worker.index);
        for (0..128) |_| try self.round(loop, client, server);
        const before = loop.stats().memory.allocations;
        _ = @atomicRmw(u32, &self.context.ready, .Add, 1, .release);
        while (@atomicLoad(u32, &self.context.go, .acquire) == 0) {
            if (@atomicLoad(u32, &self.context.failed, .acquire) != 0) return error.InvalidState;
            mox_io.sync.Thread.yield();
        }
        for (0..self.context.rounds) |_| try self.round(loop, client, server);
        self.ended = loop.now();
        self.allocations = loop.stats().memory.allocations - before;
        if (self.allocations != 0 or !std.mem.eql(u8, self.source, self.target)) return error.InvalidState;
        _ = @atomicRmw(u32, &self.context.done, .Add, 1, .release);
    }

    fn round(self: *Owner, loop: *Loop, client: t.Handle, peer: t.Handle) mox_io.Error!void {
        try transfer(loop, client, peer, self.source, self.echo);
        try transfer(loop, peer, client, self.echo, self.target);
    }
};

const Context = struct { ready: u32 = 0, go: u32 = 0, done: u32 = 0, failed: u32 = 0, rounds: usize };

fn gather(loop: *Loop, output: []t.Completion) mox_io.Error!void {
    const deadline = loop.now() + 30_000_000_000;
    var count: usize = 0;
    while (count != output.len) {
        if (loop.now() >= deadline) return error.NoProgress;
        count += try loop.poll(output[count..], .{ .until = deadline });
    }
    for (output) |result| if (result.status != .ok) return result.library_error orelse error.NativeFailure;
}

fn transfer(loop: *Loop, from: t.Handle, to: t.Handle, input: []const u8, output: []u8) mox_io.Error!void {
    _ = try loop.recvExact(to, output, .{});
    _ = try loop.sendAll(from, input, .{});
    var results: [2]t.Completion = undefined;
    try gather(loop, &results);
    for (results) |result| if (result.bytes != input.len) return error.NoProgress;
}

fn complete(_: ?*anyopaque, worker: *Runtime.Worker, results: []const t.Completion) void {
    for (results) |result| if (result.kind != .close or result.status != .ok) worker.fail(error.NativeFailure);
}

fn wait(context: *Context, field: enum { ready, done }, expected: usize, deadline: u64) !void {
    while (@atomicLoad(u32, if (field == .ready) &context.ready else &context.done, .acquire) != expected) {
        if (@atomicLoad(u32, &context.failed, .acquire) != 0) return error.OwnerFailed;
        if (mox_io.os.now() >= deadline) {
            @atomicStore(u32, &context.failed, 1, .release);
            return error.BenchmarkTimeout;
        }
        mox_io.sync.Thread.yield();
    }
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const threads = if (args.len > 1) try std.fmt.parseInt(u32, args[1], 10) else 0;
    const payload = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 4096;
    const rounds = if (args.len > 3) try std.fmt.parseInt(usize, args[3], 10) else 10000;
    if (payload == 0 or payload > 65536 or rounds == 0 or rounds > 10000000) return error.InvalidArguments;
    var runtime: Runtime = undefined;
    try runtime.init(mox_io.mem.PageAllocator.allocator(), .{
        .threads = threads,
        .queue_capacity = 2,
        .completion_batch = 8,
        .loop = .{ .operations = 4, .resources = 3, .events = 16, .inbox = 0, .file_threads = 0 },
    });
    defer runtime.deinit() catch @panic("benchmark Runtime deinit failed");
    const count = runtime.stats().threads;
    const owners = try init.arena.allocator().alloc(Owner, count);
    var context: Context = .{ .rounds = rounds };
    for (owners) |*owner| owner.* = .{
        .context = &context,
        .source = try init.arena.allocator().alloc(u8, payload),
        .echo = try init.arena.allocator().alloc(u8, payload),
        .target = try init.arena.allocator().alloc(u8, payload),
    };
    try runtime.start(.{ .complete = complete });
    defer {
        @atomicStore(u32, &context.failed, 1, .release);
        runtime.shutdown();
        runtime.join() catch {};
    }
    for (owners, 0..) |*owner, index| try runtime.postTo(index, .{ .context = owner, .run = Owner.run });
    try wait(&context, .ready, count, mox_io.os.now() + 60_000_000_000);
    const start = mox_io.os.now();
    @atomicStore(u32, &context.go, 1, .release);
    try wait(&context, .done, count, start + 120_000_000_000);
    runtime.shutdown();
    try runtime.join();
    var end = start;
    var allocations: u64 = 0;
    for (owners, 0..) |owner, index| {
        end = @max(end, owner.ended);
        allocations += owner.allocations;
        for (owners[0..index]) |previous| if (previous.thread == owner.thread) return error.DuplicateOwner;
    }
    if (end == start or runtime.stats().tasks_executed != count) return error.InvalidMeasurement;
    var buffer: [512]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    try output.interface.print("owners,payload_bytes,rounds_per_owner,total_rounds,duration_ns,steady_allocations\n{d},{d},{d},{d},{d},{d}\n", .{ count, payload, rounds, count * rounds, end - start, allocations });
    try output.interface.flush();
}
