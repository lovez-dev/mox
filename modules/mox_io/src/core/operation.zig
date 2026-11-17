//! Owner-only operation identities retained through terminal result consumption.

const t = @import("values.zig");
const Error = @import("../error.zig").Error;

// Retiring holds hidden cleanup; retired permanently excludes exhausted generations.
pub const State = enum { free, queued, submitted, retiring, completed, retired };

pub const Slot = struct {
    generation: u64 = 0,
    state: State = .free,

    next: u32 = t.none,
    timer: u32 = t.none,
    reason: ?t.Status = null,
    progress: usize = 0,
    child: u32 = t.none,

    resource_previous: u32 = t.none,
    resource_next: u32 = t.none,
};

pub const Request = @import("execution.zig").Request;

pub const Store = struct {
    slots: []Slot,
    requests: []Request,
    results: []t.Completion,
    free_head: u32,
    active: u32 = 0,
    high_water: u32 = 0,

    pub fn initialize(self: *Store) void {
        for (self.slots, 0..) |*slot, index| {
            slot.* = .{ .next = if (index + 1 < self.slots.len) @intCast(index + 1) else t.none };
        }
        self.free_head = 0;
    }

    pub fn reserve(self: *Store) Error!t.OpId {
        while (self.free_head != t.none) {
            const index = self.free_head;
            const slot = &self.slots[index];
            self.free_head = slot.next;
            // Never wrap identities: an ancient ID must not match a recycled slot.
            if (slot.generation == ~@as(u64, 0)) {
                slot.state = .retired;
                continue;
            }
            const generation = slot.generation + 1;
            slot.* = .{ .generation = generation, .state = .queued };
            self.active += 1;
            self.high_water = @max(self.high_water, self.active);
            return .{ .index = index, .generation = generation };
        }
        return error.Capacity;
    }

    pub fn get(self: *Store, id: t.OpId) Error!*Slot {
        if (id.index >= self.slots.len) return error.StaleOperation;
        const slot = &self.slots[id.index];
        if (slot.generation != id.generation or slot.state == .free or slot.state == .retired) return error.StaleOperation;
        return slot;
    }

    /// Release after failed admission, or after consuming the admitted terminal result.
    pub fn release(self: *Store, index: u32) void {
        const slot = &self.slots[index];
        slot.state = .free;
        slot.next = self.free_head;
        self.free_head = index;
        self.active -= 1;
    }
};
