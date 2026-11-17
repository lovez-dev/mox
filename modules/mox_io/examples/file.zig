//! Asynchronous open, stream cursor I/O, durability, metadata and memory accounting.

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

fn run() u8 {
    work() catch |err| {
        support.report(err);
        return 1;
    };
    return 0;
}

fn work() !void {
    const text = "Caller buffers are borrowed; Loop storage is allocated once.\n";
    var buffer: [128]u8 = undefined;
    var loop: Loop = undefined;
    try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 8, .resources = 2 });
    var active = true;
    defer if (active) {
        support.drain(&loop) catch @panic("example cleanup failed");
    };
    _ = try loop.openFileAsync("out/mox-io-example-file.bin", .{ .access = .read_write, .creation = .create_always }, .{ .tag = 1 });
    const opened = try support.one(&loop);
    try support.success(opened);
    const file: mox_io.fs.File(Loop) = .{ .loop = &loop, .handle = opened.opened orelse return error.OpenMissing };
    var stream = file.stream(0);
    _ = try stream.writeAll(text, .{ .tag = 2 });
    const written = try support.one(&loop);
    try support.success(written);
    if (!stream.complete(written)) return error.UnexpectedCompletion;
    _ = try file.sync(.{});
    try support.success(try support.one(&loop));
    try stream.seek(0);
    _ = try stream.readExact(buffer[0..text.len], .{ .tag = 3 });
    const read = try support.one(&loop);
    try support.success(read);
    if (!stream.complete(read) or !mox_io.mem.bytes.equal(text, buffer[0..text.len])) return error.DataMismatch;
    _ = try file.stat(.{});
    const metadata = try support.one(&loop);
    try support.success(metadata);
    mox_io.os.writeStdout(buffer[0..text.len]);
    support.number("File bytes: ", metadata.file_info.size);
    support.number("Loop requested bytes: ", loop.stats().memory.live_bytes);
    support.number("Loop allocation count: ", loop.stats().memory.allocations);
    try support.drain(&loop);
    active = false;
    support.number("Live bytes after deinit: ", loop.stats().memory.live_bytes);
}
