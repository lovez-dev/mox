//! A producer posts bounded tasks while the Loop owns state and completion handling.

const mox_io = @import("mox_io");
const support = @import("support.zig");

const Loop = mox_io.DefaultLoop;
const Boot = mox_io.runtime.Boot(run);
pub const panic = mox_io.runtime.panic;
pub const main = Boot.main;
pub const WinMainCRTStartup = Boot.WinMainCRTStartup;

comptime {
    Boot.exportEntry();
}

const Counter = struct { value: usize = 0 };

const Producer = struct { loop: *Loop, counter: *Counter, failed: u32 = 0 };

fn increment(context: ?*anyopaque, _: *Loop) void {
    const counter: *Counter = @ptrCast(@alignCast(context.?));
    counter.value += 1;
}

fn produce(context: *anyopaque) void {
    const producer: *Producer = @ptrCast(@alignCast(context));
    for (0..128) |_| {
        while (true) {
            producer.loop.post(.{ .task = .{ .context = producer.counter, .run = increment } }) catch |err| {
                if (err == error.QueueFull) {
                    mox_io.sync.Thread.yield();
                    continue;
                }
                @atomicStore(u32, &producer.failed, 1, .release);
                return;
            };
            break;
        }
    }
}

fn run() u8 {
    work() catch |err| {
        support.report(err);
        return 1;
    };
    return 0;
}

fn work() !void {
    var counter: Counter = .{};
    var loop: Loop = undefined;
    try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 1, .resources = 1, .inbox = 16, .file_threads = 0 });
    var producer: Producer = .{ .loop = &loop, .counter = &counter };
    var thread: mox_io.sync.Thread = .{};
    var started = false;
    defer {
        loop.closeInbox() catch {};
        if (started) thread.join();
        support.drain(&loop) catch @panic("example cleanup failed");
    }
    try thread.start(produce, &producer);
    started = true;
    var results: [1]mox_io.types.Completion = undefined;
    const deadline = loop.now() + 5_000_000_000;
    while (counter.value != 128) {
        if (loop.now() >= deadline) return error.InboxTimeout;
        _ = try loop.poll(&results, .{ .until = deadline });
    }
    thread.join();
    started = false;
    if (@atomicLoad(u32, &producer.failed, .acquire) != 0) return error.ProducerFailed;
    support.number("Owner tasks executed: ", counter.value);
    support.number("Inbox peak occupancy: ", loop.stats().inbox.high_water);
}
