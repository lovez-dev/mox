//! Owner-only native resources and their pending-close reservations.

const t = @import("../types.zig");
const Error = @import("../error.zig").Error;

pub const State = enum { free, reserved, opening, open, closing, closed, retired };

pub const Slot = struct {
    generation: u64 = 0,
    state: State = .free,
    kind: t.ResourceKind = .tcp,
    native: usize = t.invalid_native,

    next: u32 = t.none,
    read_op: u32 = t.none,
    write_op: u32 = t.none,

    // Native close waits for all borrowing operations to retire.
    references: u32 = 0,
    operation_head: u32 = t.none,

    close_tag: usize = 0,
    close_error: i32 = 0,
    close_submitted: bool = false,
    retry_queued: bool = false,
    retry_at: u64 = 0,

    opening_operation: u32 = t.none,
    connection: t.Connection = .unconnected,
};

pub const Store = struct {
    slots: []Slot,
    free_head: u32,
    active: u32 = 0,
    high_water: u32 = 0,

    pub fn initialize(self: *Store) void {
        for (self.slots, 0..) |*slot, index| slot.* = .{ .next = if (index + 1 < self.slots.len) @intCast(index + 1) else t.none };
        self.free_head = 0;
    }

    pub fn reserve(self: *Store) Error!t.Handle {
        while (self.free_head != t.none) {
            const index = self.free_head;
            const slot = &self.slots[index];
            self.free_head = slot.next;
            // Exhausted slots stay unavailable rather than allowing identity wraparound.
            if (slot.generation == ~@as(u64, 0)) {
                slot.state = .retired;
                continue;
            }
            slot.* = .{ .generation = slot.generation + 1, .state = .reserved };
            self.active += 1;
            self.high_water = @max(self.high_water, self.active);
            return .{ .index = index, .generation = slot.generation };
        }
        return error.Capacity;
    }

    pub fn get(self: *Store, key: t.Handle) Error!*Slot {
        if (key.index >= self.slots.len) return error.StaleHandle;
        const slot = &self.slots[key.index];
        if (slot.generation != key.generation or slot.state == .free or slot.state == .retired) return error.StaleHandle;
        return slot;
    }

    pub fn handle(self: *const Store, index: u32) t.Handle {
        return .{ .index = index, .generation = self.slots[index].generation };
    }

    /// Release a reservation or retired ownership; published close IDs stay pinned until delivery.
    pub fn release(self: *Store, index: u32) void {
        const slot = &self.slots[index];
        slot.state = .free;
        slot.next = self.free_head;
        self.free_head = index;
        self.active -= 1;
    }
};
