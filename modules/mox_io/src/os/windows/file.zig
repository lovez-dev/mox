//! Windows overlapped file opening with caller-owned path storage.

const abi = @import("../abi/windows.zig");
const types = @import("../../fs/types.zig");
const path_codec = @import("../../fs/path.zig");
const Error = @import("../../error.zig").Error;

pub fn openFile(path: []const u8, options: types.OpenOptions, scratch: []u8) Error!usize {
    const units: [*]u16 = @ptrCast(@alignCast(scratch.ptr));
    const wide = try path_codec.utf16(path, units[0 .. scratch.len / 2]);
    const access: u32 = switch (options.access) {
        .read => 0x80000000,
        .write => 0x40000000,
        .read_write => 0xc0000000,
    };

    const creation: u32 = switch (options.creation) {
        .create_new => 1,
        .create_always => 2,
        .open_existing => 3,
        .open_or_create => 4,
        .truncate_existing => 5,
    };
    // Overlapped handles are created on workers and attached to IOCP by the owner.
    const handle = abi.CreateFileW(wide.ptr, access, 7, null, creation, 0x40000080, null);
    if (handle == abi.invalid_handle) return error.NativeFailure;
    return @intFromPtr(handle);
}
