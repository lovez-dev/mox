//! Synchronized allocation budget shared by connection buffers and request arenas.

const std = @import("std");

pub const Budget = struct {
    backing: std.mem.Allocator,
    limit: usize,
    used: usize = 0,
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(self: *Budget) void {
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Budget) void {
        self.locked.store(false, .release);
    }

    pub fn allocator(self: *Budget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    /// Keep room for live work instead of retaining idle request storage.
    pub fn isUnderPressure(self: *Budget) bool {
        if (self.limit == 0) return false;
        self.lock();
        defer self.unlock();
        return self.used >= self.limit - self.limit / 4;
    }

    fn fits(self: *Budget, amount: usize) bool {
        return amount <= std.math.maxInt(usize) - self.used and (self.limit == 0 or amount <= self.limit -| self.used);
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ptr));
        self.lock();
        defer self.unlock();
        if (!self.fits(len)) return null;
        const bytes = self.backing.rawAlloc(len, alignment, ra) orelse return null;
        self.used += len;
        return bytes;
    }

    fn resize(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *Budget = @ptrCast(@alignCast(ptr));
        self.lock();
        defer self.unlock();
        if (len > bytes.len and !self.fits(len - bytes.len)) return false;
        if (!self.backing.rawResize(bytes, alignment, len, ra)) return false;
        self.used = self.used - bytes.len + len;
        return true;
    }

    fn remap(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ptr));
        self.lock();
        defer self.unlock();
        if (len > bytes.len and !self.fits(len - bytes.len)) return null;
        const result = self.backing.rawRemap(bytes, alignment, len, ra) orelse return null;
        self.used = self.used - bytes.len + len;
        return result;
    }

    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Budget = @ptrCast(@alignCast(ptr));
        self.lock();
        defer self.unlock();
        self.backing.rawFree(bytes, alignment, ra);
        self.used -= bytes.len;
    }
};

/// Called only after response I/O and request cleanup finish on the loop thread.
/// A failed consolidation may leave a larger arena, so release it on failure.
pub fn resetRequestArena(arena: *std.heap.ArenaAllocator, budget: *Budget, retain_bytes: usize) void {
    if (retain_bytes == 0 or budget.isUnderPressure()) {
        _ = arena.reset(.free_all);
    } else if (!arena.reset(.{ .retain_with_limit = retain_bytes })) {
        _ = arena.reset(.free_all);
    }
}

test "request arena reuses bounded storage charged through connection retirement" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var budget: Budget = .{ .backing = tracking.allocator(), .limit = 16 * 1024 };
    var arena = std.heap.ArenaAllocator.init(budget.allocator());
    const first = try arena.allocator().alloc(u8, 128);
    @memset(first, 0xa5);
    resetRequestArena(&arena, &budget, 1024);
    try std.testing.expect(arena.queryCapacity() > 0 and arena.queryCapacity() <= 1024);
    try std.testing.expect(budget.used > 0);
    const before = tracking.allocations;
    _ = try arena.allocator().alloc(u8, 128);
    try std.testing.expectEqual(before, tracking.allocations);
    resetRequestArena(&arena, &budget, 1024);
    arena.deinit();
    try std.testing.expectEqual(@as(usize, 0), budget.used);
    try std.testing.expectEqual(tracking.allocated_bytes, tracking.freed_bytes);
}

test "request arena frees oversized requests and honors disabled retention" {
    var budget: Budget = .{ .backing = std.testing.allocator, .limit = 0 };
    var arena = std.heap.ArenaAllocator.init(budget.allocator());
    defer arena.deinit();
    _ = try arena.allocator().alloc(u8, 32 * 1024);
    resetRequestArena(&arena, &budget, 1024);
    try std.testing.expect(arena.queryCapacity() <= 1024);
    _ = try arena.allocator().alloc(u8, 64);
    resetRequestArena(&arena, &budget, 0);
    try std.testing.expectEqual(@as(usize, 0), arena.queryCapacity());
    try std.testing.expectEqual(@as(usize, 0), budget.used);
}

test "request arena retention failure releases remaining backing storage" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
    var budget: Budget = .{ .backing = failing.allocator(), .limit = 0 };
    var arena = std.heap.ArenaAllocator.init(budget.allocator());
    defer arena.deinit();
    _ = try arena.allocator().alloc(u8, 4096);
    resetRequestArena(&arena, &budget, 128);
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), arena.queryCapacity());
    try std.testing.expectEqual(@as(usize, 0), budget.used);
}

test "request arena retention yields to the shared memory budget" {
    var budget: Budget = .{ .backing = std.testing.allocator, .limit = 4096 };
    var arena = std.heap.ArenaAllocator.init(budget.allocator());
    defer arena.deinit();
    _ = try arena.allocator().alloc(u8, 64);
    resetRequestArena(&arena, &budget, 512);
    try std.testing.expect(!budget.isUnderPressure());
    const active = try budget.allocator().alloc(u8, budget.limit - budget.used);
    try std.testing.expect(budget.isUnderPressure());
    resetRequestArena(&arena, &budget, 512);
    try std.testing.expectEqual(@as(usize, 0), arena.queryCapacity());
    try std.testing.expectEqual(active.len, budget.used);
    budget.allocator().free(active);
    try std.testing.expect(!budget.isUnderPressure());
}

test "budget pressure starts at three quarters and ignores unlimited budgets" {
    var budget: Budget = .{ .backing = std.testing.allocator, .limit = 4096 };
    const below = try budget.allocator().alloc(u8, 3071);
    defer budget.allocator().free(below);
    try std.testing.expect(!budget.isUnderPressure());
    const edge = try budget.allocator().alloc(u8, 1);
    defer budget.allocator().free(edge);
    try std.testing.expect(budget.isUnderPressure());
    budget.limit = 0;
    try std.testing.expect(!budget.isUnderPressure());
}

test "budget rejects growth and restores capacity after release" {
    var budget: Budget = .{ .backing = std.testing.allocator, .limit = 32 };
    const allocator = budget.allocator();
    const bytes = try allocator.alloc(u8, 24);
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 9));
    allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), budget.used);
}

test "budget resize and remap charge only committed size changes" {
    var storage: [64]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var budget: Budget = .{ .backing = fixed.allocator(), .limit = 32 };
    const allocator = budget.allocator();
    var bytes = try allocator.alloc(u8, 16);
    @memset(bytes, 0xa5);

    try std.testing.expect(allocator.resize(bytes, 24));
    bytes = bytes.ptr[0..24];
    try std.testing.expectEqual(@as(usize, 24), budget.used);
    try std.testing.expect(!allocator.resize(bytes, 33));
    try std.testing.expect(allocator.remap(bytes, 33) == null);
    try std.testing.expectEqual(@as(usize, 24), budget.used);

    bytes = allocator.remap(bytes, 32).?;
    try std.testing.expectEqual(@as(usize, 32), budget.used);
    try std.testing.expectEqualSlices(u8, &(@as([16]u8, @splat(0xa5))), bytes[0..16]);
    bytes = allocator.remap(bytes, 8).?;
    try std.testing.expectEqual(@as(usize, 8), budget.used);
    allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), budget.used);
}

test "backing allocator rejection leaves budget and live data unchanged" {
    var storage: [32]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var failing = std.testing.FailingAllocator.init(fixed.allocator(), .{ .fail_index = 1, .resize_fail_index = 0 });
    var budget: Budget = .{ .backing = failing.allocator(), .limit = 64 };
    const allocator = budget.allocator();
    const bytes = try allocator.dupe(u8, "still valid");
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 1));
    try std.testing.expect(!allocator.resize(bytes, 16));
    try std.testing.expect(allocator.remap(bytes, 16) == null);
    try std.testing.expectEqual(bytes.len, budget.used);
    try std.testing.expectEqualStrings("still valid", bytes);
    allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), budget.used);
}

test "unlimited budget still prevents accounting overflow before backing allocation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var budget: Budget = .{ .backing = failing.allocator(), .limit = 0, .used = std.math.maxInt(usize) - 1 };
    const allocator = budget.allocator();
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 2));
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    budget.used = 0;
    const bytes = try allocator.alloc(u8, 64);
    try std.testing.expectEqual(@as(usize, 64), budget.used);
    allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), budget.used);
}
