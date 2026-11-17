//! Bounded multi-producer inbox with one owner-side consumer.

const Error = @import("../error.zig").Error;

pub const Stats = struct {
    capacity: usize = 0,
    queued: usize = 0,
    high_water: usize = 0,
    posted: u64 = 0,
    processed: u64 = 0,
    rejected: u64 = 0,
    errors: u64 = 0,
    active_producers: usize = 0,
    sealed: bool = true,
};

pub fn Inbox(comptime Command: type) type {
    return struct {
        const Self = @This();
        const closed_bit = @as(usize, 1) << (@bitSizeOf(usize) - 1);

        // Sequence numbers distinguish free and published cells across ring wraparound.
        pub const Cell = struct { sequence: usize, command: Command = undefined };

        storage: []Cell = &.{},
        tail: usize align(64) = 0,
        head: usize align(64) = 0,
        // High bit seals admission; lower bits pin producers through their wake calls.
        gate: usize align(64) = closed_bit,
        wake_pending: u32 = 0,

        posted: u64 = 0,
        rejected: u64 = 0,
        high_water: usize = 0,
        processed: u64 = 0,
        errors: u64 = 0,

        /// Storage is empty or a power of two; its address remains stable while producers run.
        pub fn init(self: *Self, storage: []Cell) void {
            self.* = .{ .storage = storage, .gate = 0 };
            for (storage, 0..) |*cell, index| cell.* = .{ .sequence = index };
        }

        /// Seal before joining producers. The Loop must outlive every producer.
        pub fn seal(self: *Self) void {
            _ = @atomicRmw(usize, &self.gate, .Or, closed_bit, .acq_rel);
        }

        fn enter(self: *Self) Error!void {
            var gate = @atomicLoad(usize, &self.gate, .acquire);
            while (true) {
                if (gate & closed_bit != 0) {
                    _ = @atomicRmw(u64, &self.rejected, .Add, 1, .monotonic);
                    return error.Closing;
                }
                if (@cmpxchgWeak(usize, &self.gate, gate, gate + 1, .acq_rel, .acquire)) |observed| gate = observed else return;
            }
        }

        pub fn post(self: *Self, command: Command, context: anytype, comptime wake: fn (@TypeOf(context)) void) Error!void {
            try self.enter();
            defer _ = @atomicRmw(usize, &self.gate, .Sub, 1, .release);
            if (self.storage.len == 0) {
                _ = @atomicRmw(u64, &self.rejected, .Add, 1, .monotonic);
                return error.QueueFull;
            }
            var position = @atomicLoad(usize, &self.tail, .monotonic);
            const cell = while (true) {
                const candidate = &self.storage[position & (self.storage.len - 1)];
                const sequence = @atomicLoad(usize, &candidate.sequence, .acquire);
                const difference: isize = @bitCast(sequence -% position);
                if (difference == 0) {
                    if (@cmpxchgWeak(usize, &self.tail, position, position +% 1, .monotonic, .monotonic)) |observed| {
                        position = observed;
                    } else break candidate;
                } else if (difference < 0) {
                    _ = @atomicRmw(u64, &self.rejected, .Add, 1, .monotonic);
                    return error.QueueFull;
                } else position = @atomicLoad(usize, &self.tail, .monotonic);
            };

            const depth = @min(position +% 1 -% @atomicLoad(usize, &self.head, .acquire), self.storage.len);
            var peak = @atomicLoad(usize, &self.high_water, .monotonic);
            while (peak < depth) {
                if (@cmpxchgWeak(usize, &self.high_water, peak, depth, .monotonic, .monotonic)) |observed| peak = observed else break;
            }
            cell.command = command;
            _ = @atomicRmw(u64, &self.posted, .Add, 1, .monotonic);
            // Publish the payload before signaling its availability.
            @atomicStore(usize, &cell.sequence, position +% 1, .release);
            if (@atomicRmw(u32, &self.wake_pending, .Xchg, 1, .acq_rel) == 0) wake(context);
        }

        pub fn pop(self: *Self) ?Command {
            if (self.storage.len == 0) return null;
            const position = @atomicLoad(usize, &self.head, .monotonic);
            const cell = &self.storage[position & (self.storage.len - 1)];
            if (@atomicLoad(usize, &cell.sequence, .acquire) != position +% 1) return null;
            const command = cell.command;
            // Publish reuse only after copying the payload out of the claimed cell.
            @atomicStore(usize, &cell.sequence, position +% self.storage.len, .release);
            @atomicStore(usize, &self.head, position +% 1, .release);
            self.processed +|= 1;
            return command;
        }

        pub fn ready(self: *const Self) bool {
            if (self.storage.len == 0) return false;
            const position = @atomicLoad(usize, &self.head, .monotonic);
            const cell = &self.storage[position & (self.storage.len - 1)];
            return @atomicLoad(usize, &cell.sequence, .acquire) == position +% 1;
        }

        pub fn prepareWait(self: *Self) bool {
            if (self.storage.len == 0) return false;
            // Clear, then recheck: a racing producer either becomes visible or wakes us.
            _ = @atomicRmw(u32, &self.wake_pending, .Xchg, 0, .acq_rel);
            return self.ready();
        }

        /// True only after claimed cells are consumed and every admitted producer returns.
        pub fn quiescent(self: *const Self) bool {
            const gate = @atomicLoad(usize, &self.gate, .acquire);
            return gate & ~closed_bit == 0 and @atomicLoad(usize, &self.tail, .acquire) == @atomicLoad(usize, &self.head, .acquire);
        }

        pub fn stats(self: *const Self) Stats {
            const gate = @atomicLoad(usize, &self.gate, .acquire);
            return .{
                .capacity = self.storage.len,
                .queued = @atomicLoad(usize, &self.tail, .acquire) -% @atomicLoad(usize, &self.head, .acquire),
                .high_water = @atomicLoad(usize, &self.high_water, .monotonic),
                .posted = @atomicLoad(u64, &self.posted, .monotonic),
                .rejected = @atomicLoad(u64, &self.rejected, .monotonic),
                .processed = self.processed,
                .errors = self.errors,
                .active_producers = gate & ~closed_bit,
                .sealed = gate & closed_bit != 0,
            };
        }
    };
}
