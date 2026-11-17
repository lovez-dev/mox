//! Adapt std.testing allocators so mox_io allocations participate in leak checks.

const std = @import("std");
const mox_io = @import("mox_io");

const Adapter = @This();

parent: std.mem.Allocator,

pub fn allocator(self: *Adapter) mox_io.mem.Allocator {
    return .{ .context = self, .vtable = &.{ .allocate = allocate, .release = release } };
}

fn allocate(context: ?*anyopaque, size: usize, alignment: usize) error{OutOfMemory}!mox_io.mem.Allocation {
    const self: *Adapter = @ptrCast(@alignCast(context.?));
    const length = @max(size, 1);
    const pointer = self.parent.rawAlloc(length, .fromByteUnits(alignment), @returnAddress()) orelse return error.OutOfMemory;
    return .{ .bytes = pointer[0..length], .requested = size, .alignment = alignment };
}

fn release(context: ?*anyopaque, allocation: mox_io.mem.Allocation) void {
    const self: *Adapter = @ptrCast(@alignCast(context.?));
    self.parent.rawFree(allocation.bytes, .fromByteUnits(allocation.alignment), @returnAddress());
}
