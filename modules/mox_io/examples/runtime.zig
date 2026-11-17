//! Automatically sized owner threads; explicit completion routing and shutdown.

const std = @import("std");
const mox_io = @import("mox_io");

const Runtime = mox_io.DefaultRuntime;

const Context = struct {
    remaining: usize,
    owners: []u64,

    fn task(context: ?*anyopaque, worker: *Runtime.Worker) void {
        const self: *Context = @ptrCast(@alignCast(context.?));
        self.owners[worker.index] = mox_io.os.threadId();
        _ = worker.loop().sleepFor(1_000_000, worker.index) catch |err| {
            worker.fail(err);
            return;
        };
    }

    fn complete(context: ?*anyopaque, worker: *Runtime.Worker, results: []const mox_io.types.Completion) void {
        const self: *Context = @ptrCast(@alignCast(context.?));
        for (results) |result| {
            if (result.kind != .timer or result.status != .ok) {
                worker.fail(error.NativeFailure);
                return;
            }
            if (@atomicRmw(usize, &self.remaining, .Sub, 1, .acq_rel) == 1)
                worker.runtime().shutdown();
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const threads = if (args.len > 1) try std.fmt.parseInt(u32, args[1], 10) else 0;
    var runtime: Runtime = undefined;
    try runtime.init(mox_io.mem.PageAllocator.allocator(), .{ .threads = threads });
    defer runtime.deinit() catch @panic("runtime deinit failed");
    const count = runtime.stats().threads;
    const owners = try init.arena.allocator().alloc(u64, count);
    @memset(owners, 0);
    var context: Context = .{ .remaining = count, .owners = owners };
    try runtime.start(.{ .context = &context, .complete = Context.complete });
    var joined = false;
    defer if (!joined) {
        runtime.shutdown();
        runtime.join() catch {};
    };
    // Each accepted task runs on its selected owner and submits owner-local I/O.
    for (0..count) |index| try runtime.postTo(index, .{ .context = &context, .run = Context.task });
    try runtime.join();
    joined = true;
    const snapshot = runtime.stats();
    var buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    try output.interface.print("owners={d} tasks={d} completions={d} exited={d}\n", .{ count, snapshot.tasks_executed, snapshot.completions, snapshot.threads_exited });
    for (owners, 0..) |id, index| try output.interface.print("owner={d} thread={d}\n", .{ index, id });
    try output.interface.flush();
}
