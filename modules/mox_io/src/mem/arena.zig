//! Aligned typed slices carved from caller-provided backing storage.

const Arena = @This();

bytes: []u8,
used: usize = 0,

/// A fixed partition; ownership remains with the backing allocator.
pub fn allocate(self: *Arena, comptime T: type, count: usize) error{OutOfMemory}![]T {
    const start = @intFromPtr(self.bytes.ptr) + self.used;
    const aligned = (start + @alignOf(T) - 1) & ~(@as(usize, @alignOf(T)) - 1);
    const product = @mulWithOverflow(@sizeOf(T), count);
    if (product[1] != 0) return error.OutOfMemory;
    const relative = aligned - @intFromPtr(self.bytes.ptr);
    const end = @addWithOverflow(relative, product[0]);
    if (end[1] != 0 or end[0] > self.bytes.len) return error.OutOfMemory;
    self.used = end[0];
    const pointer: [*]T = @ptrFromInt(aligned);
    return pointer[0..count];
}

pub fn remaining(self: *const Arena) usize {
    return self.bytes.len - self.used;
}
