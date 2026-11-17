//! Caller-owned operation groups; unrelated completions remain visible to callers.

const t = @import("../types.zig");
const Error = @import("../error.zig").Error;

pub const Mode = enum { all, any };

pub const Entry = struct { id: t.OpId, result: ?t.Completion = null };

pub fn Group(comptime LoopType: type) type {
    return struct {
        const Self = @This();

        loop: *LoopType,
        storage: []Entry,
        mode: Mode,
        count: usize = 0,
        completed: usize = 0,
        winner: ?usize = null,
        sealed: bool = false,

        pub fn init(loop: *LoopType, storage: []Entry, mode: Mode) Self {
            return .{ .loop = loop, .storage = storage, .mode = mode };
        }

        /// Add admitted operations from this group's Loop before sealing.
        pub fn add(self: *Self, id: t.OpId) Error!void {
            if (self.sealed) return error.InvalidState;
            _ = try self.loop.operations.get(id);
            for (self.storage[0..self.count]) |entry|
                if (same(entry.id, id)) return error.InvalidOptions;
            if (self.count == self.storage.len) return error.Capacity;
            self.storage[self.count] = .{ .id = id };
            self.count += 1;
        }

        pub fn seal(self: *Self) void {
            self.sealed = true;
        }

        /// Any-mode readiness selects a result; losing members still require retirement.
        pub fn ready(self: *const Self) bool {
            if (!self.sealed) return false;
            return switch (self.mode) {
                .all => self.completed == self.count,
                .any => self.winner != null,
            };
        }

        /// Feed every consumed result, including canceled race losers.
        pub fn complete(self: *Self, result: t.Completion) bool {
            const id = result.id orelse return false;
            for (self.storage[0..self.count], 0..) |*entry, index| {
                if (!same(entry.id, id)) continue;
                if (entry.result == null) {
                    entry.result = result;
                    self.completed += 1;
                    if (self.winner == null) self.winner = index;
                }
                return true;
            }
            return false;
        }

        /// Poll once, preserving all results for normal application dispatch.
        pub fn poll(self: *Self, output: []t.Completion, wait: t.Wait) Error!usize {
            if (!self.sealed) return error.InvalidState;
            const count = try self.loop.poll(output, wait);
            for (output[0..count]) |result| _ = self.complete(result);
            return count;
        }

        pub fn cancelRemaining(self: *Self) Error!void {
            var first_error: ?Error = null;
            for (self.storage[0..self.count]) |entry| {
                if (entry.result != null) continue;
                _ = self.loop.cancel(entry.id) catch |err| {
                    if (first_error == null) first_error = err;
                    continue;
                };
            }
            if (first_error) |err| return err;
        }

        /// A race being ready does not mean its losing operations have retired.
        pub fn reset(self: *Self, mode: Mode) Error!void {
            if (self.completed != self.count) return error.Busy;
            self.count = 0;
            self.completed = 0;
            self.winner = null;
            self.sealed = false;
            self.mode = mode;
        }

        fn same(a: t.OpId, b: t.OpId) bool {
            return a.index == b.index and a.generation == b.generation;
        }
    };
}
