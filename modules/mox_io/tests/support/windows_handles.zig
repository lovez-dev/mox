//! Separate system-owned Event caches from the handles managed by the library.

const std = @import("std");

const Win = struct {
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) *anyopaque;
    extern "ntdll" fn NtQueryInformationProcess(*anyopaque, u32, *anyopaque, u32, *u32) callconv(.winapi) i32;
    extern "ntdll" fn NtQueryObject(usize, u32, *anyopaque, u32, *u32) callconv(.winapi) i32;
};

const Entry = extern struct {
    handle: usize,
    references: usize,
    pointers: usize,
    access: u32,
    type_index: u32,
    attributes: u32,
    reserved: u32,
};

const NativeSnapshot = extern struct { count: usize = 0, reserved: usize = 0, entries: [4096]Entry = undefined };

const Unicode = extern struct { length: u16, maximum: u16, text: [*]const u16 };

pub const Snapshot = struct { total: usize, events: usize };

/// Runtime uses File, Thread and IoCompletion handles, never creates Event handles.
pub fn snapshot() !Snapshot {
    // A system helper may close a handle while its type is being inspected.
    for (0..4) |_| if (try capture()) |result| return result;
    return error.NativeHandleSnapshotBusy;
}

fn capture() !?Snapshot {
    var native: NativeSnapshot = .{};
    var length: u32 = 0;
    if (Win.NtQueryInformationProcess(Win.GetCurrentProcess(), 51, &native, @sizeOf(NativeSnapshot), &length) != 0 or native.count > native.entries.len)
        return error.NativeHandleSnapshotFailed;
    var kinds: [256]enum { unknown, event, other } = @splat(.unknown);
    var events: usize = 0;
    for (native.entries[0..native.count]) |entry| {
        if (entry.type_index >= kinds.len) return error.NativeHandleTypeUnknown;
        const kind = &kinds[entry.type_index];
        if (kind.* == .unknown) {
            var buffer: [4096]u8 align(8) = undefined;
            const status = Win.NtQueryObject(entry.handle, 2, &buffer, buffer.len, &length);
            if (@as(u32, @bitCast(status)) == 0xc0000008) return null;
            if (status != 0) return error.NativeHandleTypeFailed;
            const name: *const Unicode = @ptrCast(&buffer);
            kind.* = if (std.mem.eql(u16, name.text[0 .. name.length / 2], &.{ 'E', 'v', 'e', 'n', 't' })) .event else .other;
        }
        if (kind.* == .event) events += 1;
    }
    return .{ .total = native.count, .events = events };
}
