//! Loop-thread allocation budget shared by connection buffers and request arenas.

const std = @import("std");

pub const Budget = struct {
    backing: std.mem.Allocator,
    limit: usize,
    used: usize = 0,

    pub fn allocator(self: *Budget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn fits(self: *Budget, amount: usize) bool {
        return amount <= std.math.maxInt(usize) - self.used and (self.limit == 0 or amount <= self.limit -| self.used);
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ptr));
        if (!self.fits(len)) return null;
        const bytes = self.backing.rawAlloc(len, alignment, ra) orelse return null;
        self.used += len;
        return bytes;
    }

    fn resize(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *Budget = @ptrCast(@alignCast(ptr));
        if (len > bytes.len and !self.fits(len - bytes.len)) return false;
        if (!self.backing.rawResize(bytes, alignment, len, ra)) return false;
        self.used = self.used - bytes.len + len;
        return true;
    }

    fn remap(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ptr));
        if (len > bytes.len and !self.fits(len - bytes.len)) return null;
        const result = self.backing.rawRemap(bytes, alignment, len, ra) orelse return null;
        self.used = self.used - bytes.len + len;
        return result;
    }

    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Budget = @ptrCast(@alignCast(ptr));
        self.backing.rawFree(bytes, alignment, ra);
        self.used -= bytes.len;
    }
};

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
