//! A self-contained TCP transfer with caller-owned buffers and completion adapters.

const mox_io = @import("mox_io");
const support = @import("support.zig");

const Loop = mox_io.DefaultLoop;
const t = mox_io.types;
const Boot = mox_io.runtime.Boot(run);
pub const panic = mox_io.runtime.panic;
pub const main = Boot.main;
pub const WinMainCRTStartup = Boot.WinMainCRTStartup;

comptime {
    Boot.exportEntry();
}

fn run() u8 {
    work() catch |err| {
        support.report(err);
        return 1;
    };
    return 0;
}

fn work() !void {
    const message = "TCP completion through an independent native backend.\n";
    var buffer: [128]u8 = undefined;
    var loop: Loop = undefined;
    try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 8, .resources = 4, .file_threads = 0 });
    defer support.drain(&loop) catch @panic("example cleanup failed");
    const listener = try loop.listen(t.Address.loopback(0), 16);
    const client = try loop.openTcp(.ipv4);
    _ = try loop.accept(listener, .{});
    _ = try loop.connect(client, try loop.localAddress(listener), .{});
    var connected: [2]t.Completion = undefined;
    try support.gather(&loop, &connected);
    var peer: ?t.Handle = null;
    for (connected) |result| {
        try support.success(result);
        if (result.kind == .accept) peer = result.accepted;
    }
    const sender: mox_io.net.Tcp(Loop) = .{ .loop = &loop, .handle = client };
    const receiver: mox_io.net.Tcp(Loop) = .{ .loop = &loop, .handle = peer orelse return error.AcceptMissing };
    try sender.noDelay(true);
    try receiver.noDelay(true);
    var reader = receiver.stream();
    var writer = sender.stream();
    _ = try reader.readExact(buffer[0..message.len], .{});
    _ = try writer.writeAll(message, .{});
    var results: [2]t.Completion = undefined;
    try support.gather(&loop, &results);
    for (results) |result| {
        try support.success(result);
        if (!reader.complete(result) and !writer.complete(result)) return error.UnexpectedCompletion;
    }
    if (!mox_io.mem.bytes.equal(message, buffer[0..message.len])) return error.DataMismatch;
    mox_io.os.writeStdout(buffer[0..message.len]);
    support.number("Payload bytes received: ", loop.stats().bytes_read);
    support.number("Steady-state allocations: ", loop.stats().memory.allocations - 1);
}
