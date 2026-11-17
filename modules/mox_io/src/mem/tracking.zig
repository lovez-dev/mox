//! Owner-serialized allocation counters over an injected provider.

const base = @import("allocator.zig");

const Tracking = @This();

parent: base.Allocator,
counters: Stats = .{},

pub const Stats = struct {
    allocations: u64 = 0,
    releases: u64 = 0,
    failures: u64 = 0,

    live_bytes: usize = 0,
    peak_bytes: usize = 0,
    live_reserved_bytes: usize = 0,
    peak_reserved_bytes: usize = 0,
};

/// Keep the tracker at a stable address. Its owner serializes access.
pub fn allocator(self: *Tracking) base.Allocator {
    return .{ .context = self, .vtable = &.{ .allocate = allocate, .release = release } };
}

pub fn stats(self: *const Tracking) Stats {
    return self.counters;
}

fn allocate(context: ?*anyopaque, size: usize, alignment: usize) base.Error!base.Allocation {
    const self: *Tracking = @ptrCast(@alignCast(context.?));
    const allocation = self.parent.allocate(size, alignment) catch |err| {
        self.counters.failures +|= 1;
        return err;
    };
    self.counters.allocations +|= 1;
    // Logical requests and provider-rounded backing measure different memory costs.
    self.counters.live_bytes += allocation.requested;
    self.counters.live_reserved_bytes += allocation.bytes.len;
    self.counters.peak_bytes = @max(self.counters.peak_bytes, self.counters.live_bytes);
    self.counters.peak_reserved_bytes = @max(self.counters.peak_reserved_bytes, self.counters.live_reserved_bytes);
    return allocation;
}

fn release(context: ?*anyopaque, allocation: base.Allocation) void {
    const self: *Tracking = @ptrCast(@alignCast(context.?));
    self.parent.release(allocation);
    self.counters.releases +|= 1;
    self.counters.live_bytes -= allocation.requested;
    self.counters.live_reserved_bytes -= allocation.bytes.len;
}
