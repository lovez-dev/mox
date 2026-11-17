//! Loopback payload throughput with setup and warmup outside the measured interval.

const mox_io = @import("mox_io");

const t = mox_io.types;
const Boot = mox_io.runtime.Boot(run);
pub const panic = mox_io.runtime.panic;
pub const main = Boot.main;
pub const WinMainCRTStartup = Boot.WinMainCRTStartup;

comptime {
    Boot.exportEntry();
}
const max_connections = 32;

const Pair = struct { client: t.Handle, peer: t.Handle };

fn number(value: u64) void {
    var buffer: [20]u8 = undefined;
    mox_io.os.writeStdout(mox_io.fmt.decimal(value, &buffer));
}

fn field(value: u64) void {
    mox_io.os.writeStdout(",");
    number(value);
}

fn gather(loop: anytype, results: []t.Completion, deadline: u64) !void {
    var count: usize = 0;
    while (count < results.len) {
        if (loop.now() >= deadline) return error.BenchmarkTimeout;
        count += try loop.poll(results[count..], .{ .until = deadline });
    }
}

fn drain(loop: anytype) !void {
    loop.shutdown() catch |err| {
        if (err != error.NativeFailure) return err;
    };
    var results: [64]t.Completion = undefined;
    const deadline = loop.now() + 10_000_000_000;
    while (true) {
        const stats = loop.stats();
        if (stats.active_operations == 0 and stats.active_resources == 0 and stats.completions_queued == 0) break;
        if (loop.now() >= deadline) return error.ShutdownTimeout;
        _ = try loop.poll(&results, .{ .until = deadline });
    }
    try loop.deinit();
}

fn batch(loop: anytype, pairs: []const Pair, source: []const u8, target: []u8, payload: usize, deadline: u64) !void {
    for (pairs, 0..) |pair, index| {
        _ = try loop.recvExact(pair.peer, target[index * payload ..][0..payload], .{});
        _ = try loop.sendAll(pair.client, source[index * payload ..][0..payload], .{});
    }
    var results: [max_connections * 2]t.Completion = undefined;
    try gather(loop, results[0 .. pairs.len * 2], deadline);
    for (results[0 .. pairs.len * 2]) |result| {
        if (result.status != .ok or result.bytes != payload or (result.kind != .recv and result.kind != .send)) return error.TransferFailed;
    }
}

fn measure(comptime Backend: type, name: []const u8, payload: usize, connections: usize) !void {
    const Loop = mox_io.Loop(Backend);
    var tracking: mox_io.mem.TrackingAllocator = .{ .parent = mox_io.mem.PageAllocator.allocator() };
    const allocator = tracking.allocator();
    const borrowed = try allocator.allocate(payload * connections * 2, 64);
    defer allocator.release(borrowed);
    const source = borrowed.bytes[0 .. payload * connections];
    const target = borrowed.bytes[payload * connections ..][0 .. payload * connections];
    for (source, 0..) |*byte, index| byte.* = @truncate(index *% 37 +% 11);
    var loop: Loop = undefined;
    try loop.init(allocator, .{
        .operations = @intCast(connections * 2),
        .resources = @intCast(connections * 2 + 1),
        .events = 64,
        .inbox = 2,
        .file_threads = 0,
    });
    defer drain(&loop) catch @panic("benchmark cleanup failed");
    const listener = try loop.listen(t.Address.loopback(0), max_connections);
    var pairs: [max_connections]Pair = undefined;
    for (pairs[0..connections]) |*pair| {
        const client = try loop.openTcp(.ipv4);
        _ = try loop.accept(listener, .{});
        _ = try loop.connect(client, try loop.localAddress(listener), .{});
        var results: [2]t.Completion = undefined;
        try gather(&loop, &results, loop.now() + 10_000_000_000);
        var peer: ?t.Handle = null;
        for (results) |result| {
            if (result.status != .ok) return error.ConnectionFailed;
            if (result.kind == .accept) peer = result.accepted;
        }
        pair.* = .{ .client = client, .peer = peer orelse return error.AcceptMissing };
        try loop.noDelay(pair.client, true);
        try loop.noDelay(pair.peer, true);
    }
    const warmup_deadline = loop.now() + 30_000_000_000;
    for (0..32) |_| try batch(&loop, pairs[0..connections], source, target, payload, warmup_deadline);
    const before = loop.stats();
    const provider_before = tracking.stats();
    const target_transfers = @max(@as(usize, 512), @min(@as(usize, 16384), 16 * 1024 * 1024 / payload));
    const rounds = @max(@as(usize, 1), target_transfers / connections);
    const start = loop.now();
    const deadline = start + 30_000_000_000;
    for (0..rounds) |_| try batch(&loop, pairs[0..connections], source, target, payload, deadline);
    const elapsed = loop.now() - start;
    const after = loop.stats();
    const steady_allocations = tracking.stats().allocations - provider_before.allocations;
    const transfers = rounds * connections;
    const moved = transfers * payload;
    if (elapsed == 0 or steady_allocations != 0 or after.memory.live_bytes != before.memory.live_bytes) return error.InvalidMeasurement;
    if (after.bytes_read - before.bytes_read != moved or after.bytes_written - before.bytes_written != moved) return error.ByteAccounting;
    // Final validation is excluded from timing; every terminal status/count was checked.
    if (!mox_io.mem.bytes.equal(source, target)) return error.DataMismatch;
    mox_io.os.writeStdout(name);
    mox_io.os.writeStdout(",");
    mox_io.os.writeStdout(@tagName(@import("builtin").mode));
    field(payload);
    field(connections);
    field(transfers);
    field(elapsed);
    const throughput_milli = @as(u64, @intCast(moved)) * 1_000_000_000 / elapsed * 1000 / 1_048_576;
    mox_io.os.writeStdout(",");
    number(throughput_milli / 1000);
    const fraction: u16 = @intCast(throughput_milli % 1000);
    const digits: [4]u8 = .{ '.', @intCast('0' + fraction / 100), @intCast('0' + fraction / 10 % 10), @intCast('0' + fraction % 10) };
    mox_io.os.writeStdout(&digits);
    field(elapsed / transfers);
    field(steady_allocations);
    field(after.native.polls - before.native.polls);
    field(after.native.submissions - before.native.submissions);
    field(after.native.completions - before.native.completions);
    field(after.memory.live_bytes);
    field(after.memory.live_reserved_bytes);
    field(after.native.kernel_mapped_bytes);
    mox_io.os.writeStdout("\n");
}

fn backend(comptime Backend: type, name: []const u8) !void {
    for ([_]usize{ 64, 4096, 65536 }) |payload| {
        for ([_]usize{ 1, 8, 32 }) |connections| try measure(Backend, name, payload, connections);
    }
}

fn work() !void {
    mox_io.os.writeStdout("backend,optimize,payload_bytes,connections,transfers,duration_ns,mib_per_second,mean_ns_per_transfer,steady_allocations,native_polls,native_submissions,native_completions,loop_requested_bytes,loop_reserved_bytes,kernel_mapped_bytes\n");
    const name = switch (@import("builtin").os.tag) {
        .windows => "iocp",
        .linux => "epoll",
        .macos, .freebsd => "kqueue",
        else => unreachable,
    };
    try backend(mox_io.DefaultBackend, name);
    if (@import("builtin").os.tag == .linux) {
        if (try mox_io.backends.Uring.probe()) try backend(mox_io.backends.Uring, "uring") else mox_io.os.writeStderr("SKIP io_uring: required kernel support unavailable\n");
    }
}

fn run() u8 {
    work() catch |err| {
        mox_io.os.writeStderr("Benchmark failed: ");
        mox_io.os.writeStderr(@errorName(err));
        mox_io.os.writeStderr("\n");
        return 1;
    };
    return 0;
}
