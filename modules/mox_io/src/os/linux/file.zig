//! Linux file primitives shared by synchronous opens and completion workers.

const s = @import("../abi/linux.zig");
const OpenOptions = @import("../../fs/types.zig").OpenOptions;
const Error = @import("../../error.zig").Error;

/// Preserve negative kernel errno values for asynchronous completion reporting.
pub fn open(path: []const u8, options: OpenOptions, scratch: []u8) Error!isize {
    if (path.len >= scratch.len) return error.Capacity;
    for (path) |byte| if (byte == 0) return error.InvalidOptions;
    @memcpy(scratch[0..path.len], path);
    scratch[path.len] = 0;
    const access: usize = switch (options.access) {
        .read => 0,
        .write => 1,
        .read_write => 2,
    };

    const creation: usize = switch (options.creation) {
        .open_existing => 0,
        .open_or_create => s.o_creat,
        .create_new => s.o_creat | s.o_excl,
        .truncate_existing => s.o_trunc,
        .create_always => s.o_creat | s.o_trunc,
    };
    while (true) {
        const result = s.openat(s.at_fdcwd, scratch[0..path.len :0].ptr, s.o_cloexec | access | creation, options.permissions);
        if (s.errno(result) != 4) return result;
    }
}

pub fn openFile(path: []const u8, options: OpenOptions, scratch: []u8) Error!usize {
    const result = try open(path, options, scratch);
    if (s.errno(result) != 0) return error.NativeFailure;
    return @intCast(result);
}
