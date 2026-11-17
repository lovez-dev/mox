//! Page-backed allocation through the selected operating system.

const base = @import("allocator.zig");
const os = @import("../os/root.zig");

/// Reserve native pages and retain the rounded length for release and accounting.
pub fn allocator() base.Allocator {
    return .{ .context = null, .vtable = &.{ .allocate = allocate, .release = release } };
}

fn allocate(_: ?*anyopaque, size: usize, alignment: usize) base.Error!base.Allocation {
    const page_size = os.pageSize();
    if (alignment > page_size) return error.InvalidAlignment;
    const added = @addWithOverflow(@max(size, 1), page_size - 1);
    if (added[1] != 0) return error.SizeOverflow;
    const rounded = added[0] & ~(page_size - 1);
    return .{ .bytes = os.mapPages(rounded) orelse return error.OutOfMemory, .requested = size, .alignment = alignment };
}

fn release(_: ?*anyopaque, allocation: base.Allocation) void {
    os.unmapPages(allocation.bytes);
}
