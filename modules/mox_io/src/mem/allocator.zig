//! Injected allocation providers with explicit release metadata.

pub const Error = error{ OutOfMemory, InvalidAlignment, SizeOverflow };

pub const Allocation = struct { bytes: []u8, requested: usize, alignment: usize };

/// The provider decides thread safety. Allocations carry their release metadata.
pub const Allocator = struct {
    context: ?*anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        allocate: *const fn (?*anyopaque, usize, usize) Error!Allocation,
        release: *const fn (?*anyopaque, Allocation) void,
    };

    pub fn allocate(self: Allocator, size: usize, alignment: usize) Error!Allocation {
        if (alignment == 0 or alignment & (alignment - 1) != 0) return error.InvalidAlignment;
        const result = try self.vtable.allocate(self.context, size, alignment);
        if (result.bytes.len < size or @intFromPtr(result.bytes.ptr) & (alignment - 1) != 0) @panic("allocator contract violation");
        if (result.requested != size or result.alignment != alignment) @panic("invalid allocator release metadata");
        return result;
    }

    pub fn release(self: Allocator, allocation: Allocation) void {
        self.vtable.release(self.context, allocation);
    }
};
