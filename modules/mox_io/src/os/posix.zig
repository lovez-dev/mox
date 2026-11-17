//! POSIX page mapping, process output, clock and thread primitives.

const posix_abi = @import("abi/posix.zig");
const builtin = @import("builtin");

pub const Timespec = posix_abi.Timespec;
pub const getpagesize = posix_abi.getpagesize;
pub const mmap = posix_abi.mmap;
pub const munmap = posix_abi.munmap;
pub const write = posix_abi.write;
pub const _exit = posix_abi._exit;
pub const clock_gettime = posix_abi.clock_gettime;
pub const pthread_self = posix_abi.pthread_self;

pub fn pageSize() usize {
    return @intCast(getpagesize());
}

pub fn mapPages(length: usize) ?[]u8 {
    const anonymous: c_int = if (builtin.os.tag == .linux) 0x20 else 0x1000;
    const pointer = mmap(null, length, 3, 2 | anonymous, -1, 0) orelse return null;
    if (@intFromPtr(pointer) == ~@as(usize, 0)) return null;
    const bytes: [*]u8 = @ptrCast(pointer);
    return bytes[0..length];
}

pub fn unmapPages(bytes: []u8) void {
    if (munmap(bytes.ptr, bytes.len) != 0) @panic("munmap failed");
}

pub fn writeStderr(bytes: []const u8) void {
    writeHandle(2, bytes);
}

pub fn writeStdout(bytes: []const u8) void {
    writeHandle(1, bytes);
}

fn writeHandle(stream: c_int, bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = write(stream, bytes[offset..].ptr, bytes.len - offset);
        if (count <= 0) return;
        offset += @intCast(count);
    }
}

pub fn exit(code: u8) noreturn {
    _exit(code);
}

pub fn now() u64 {
    const monotonic: c_int = switch (builtin.os.tag) {
        .linux => 1,
        .macos => 6,
        .freebsd => 4,
        else => unreachable,
    };
    var value: Timespec = undefined;
    if (clock_gettime(monotonic, &value) != 0) @panic("clock_gettime failed");
    return @as(u64, @intCast(value.sec)) * 1_000_000_000 + @as(u64, @intCast(value.nsec));
}

pub fn threadId() u64 {
    return pthread_self();
}
