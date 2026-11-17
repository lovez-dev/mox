//! Serialized allocation accounting for providers shared across Loop owners.

const base = @import("allocator.zig");
const Tracking = @import("tracking.zig");
const Mutex = @import("../sync/mutex.zig");
const Error = @import("../error.zig").Error;

const Shared = @This();

tracking: Tracking,
mutex: Mutex = .{},

/// Keep this wrapper alive until all allocations from it have been released.
pub fn init(self: *Shared, parent: base.Allocator) Error!void {
    self.* = .{ .tracking = .{ .parent = parent } };
    try self.mutex.init();
}

pub fn deinit(self: *Shared) Error!void {
    if (self.stats().live_reserved_bytes != 0) return error.Busy;
    self.mutex.deinit();
}

pub fn allocator(self: *Shared) base.Allocator {
    return .{ .context = self, .vtable = &.{ .allocate = allocate, .release = release } };
}

pub fn stats(self: *Shared) Tracking.Stats {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.tracking.stats();
}

fn allocate(context: ?*anyopaque, size: usize, alignment: usize) base.Error!base.Allocation {
    const self: *Shared = @ptrCast(@alignCast(context.?));
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.tracking.allocator().allocate(size, alignment);
}

fn release(context: ?*anyopaque, allocation: base.Allocation) void {
    const self: *Shared = @ptrCast(@alignCast(context.?));
    self.mutex.lock();
    defer self.mutex.unlock();
    self.tracking.allocator().release(allocation);
}
