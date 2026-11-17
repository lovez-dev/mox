//! Owner-only deadline heap with operation-slot back pointers.

const op = @import("operation.zig");
const none = @import("../types.zig").none;

pub const Entry = struct { deadline: u64, index: u32 };

/// Indexed heap: cancellation and completion remove a deadline in O(log N).
pub const Heap = struct {
    storage: []Entry,
    slots: []op.Slot,
    count: u32 = 0,

    pub fn add(self: *Heap, index: u32, deadline: u64) void {
        const position = self.count;
        self.count += 1;
        self.storage[position] = .{ .index = index, .deadline = deadline };
        self.slots[index].timer = position;
        self.up(position);
    }

    pub fn remove(self: *Heap, index: u32) void {
        const position = self.slots[index].timer;
        if (position == none) return;
        self.slots[index].timer = none;
        self.count -= 1;
        if (position == self.count) return;
        // Repair the moved entry's back pointer before restoring heap order.
        self.storage[position] = self.storage[self.count];
        self.slots[self.storage[position].index].timer = position;
        if (position != 0 and self.storage[position].deadline < self.storage[(position - 1) / 2].deadline) {
            self.up(position);
        } else {
            self.down(position);
        }
    }

    pub fn peek(self: *const Heap) ?Entry {
        return if (self.count == 0) null else self.storage[0];
    }

    fn swap(self: *Heap, a: u32, b: u32) void {
        const value = self.storage[a];
        self.storage[a] = self.storage[b];
        self.storage[b] = value;
        self.slots[self.storage[a].index].timer = a;
        self.slots[self.storage[b].index].timer = b;
    }

    fn up(self: *Heap, from: u32) void {
        var position = from;
        while (position != 0) {
            const parent = (position - 1) / 2;
            if (self.storage[parent].deadline <= self.storage[position].deadline) break;
            self.swap(position, parent);
            position = parent;
        }
    }

    fn down(self: *Heap, from: u32) void {
        var position = from;
        while (true) {
            var child = position * 2 + 1;
            if (child >= self.count) return;
            if (child + 1 < self.count and self.storage[child + 1].deadline < self.storage[child].deadline) child += 1;
            if (self.storage[position].deadline <= self.storage[child].deadline) return;
            self.swap(position, child);
            position = child;
        }
    }
};
