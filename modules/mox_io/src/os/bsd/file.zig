//! Native file opening for Darwin and FreeBSD.

const builtin = @import("builtin");
const abi = @import("../abi/posix.zig");
const types = @import("../../fs/types.zig");
const Error = @import("../../error.zig").Error;

const darwin = builtin.os.tag == .macos;

pub fn openFile(path: []const u8, options: types.OpenOptions, scratch: []u8) Error!usize {
    if (path.len >= scratch.len) return error.Capacity;
    for (path) |byte| if (byte == 0) return error.InvalidOptions;
    @memcpy(scratch[0..path.len], path);
    scratch[path.len] = 0;
    const access: c_int = switch (options.access) {
        .read => 0,
        .write => 1,
        .read_write => 2,
    };

    const creation: c_int = switch (options.creation) {
        .open_existing => 0,
        .open_or_create => 0x200,
        .create_new => 0x200 | 0x800,
        .truncate_existing => 0x400,
        .create_always => 0x200 | 0x400,
    };

    const descriptor = while (true) {
        const value = abi.open(scratch[0..path.len :0].ptr, (if (darwin) @as(c_int, 0x1000000) else 0x100000) | access | creation, @as(c_uint, options.permissions));
        if (value >= 0 or abi.__error().* != 4) break value;
    };
    if (descriptor < 0) return error.NativeFailure;
    return @intCast(descriptor);
}
