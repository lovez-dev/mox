//! Event-loop-owned admission control. No queue or per-client allocations.

const std = @import("std");

pub const Admission = struct {
    max_inflight: usize = 0,
    max_per_second: u32 = 0,
    active: usize = 0,
    max_websockets: usize = 0,
    active_websockets: usize = 0,
    window_start: ?u64 = null,
    count: u32 = 0,

    pub fn acquire(self: *Admission, now: u64) ?std.http.Status {
        if (self.max_inflight != 0 and self.active >= self.max_inflight) return .service_unavailable;
        if (self.max_per_second != 0) {
            if (self.window_start == null or now -| self.window_start.? >= 1000) {
                self.window_start = now;
                self.count = 0;
            }
            if (self.count >= self.max_per_second) return .too_many_requests;
            self.count += 1;
        }
        self.active += 1;
        return null;
    }

    pub fn acquireWebSocket(self: *Admission) bool {
        if (self.max_websockets != 0 and self.active_websockets >= self.max_websockets) return false;
        self.active_websockets += 1;
        return true;
    }

    pub fn releaseWebSocket(self: *Admission) void {
        std.debug.assert(self.active_websockets > 0);
        self.active_websockets -= 1;
    }

    pub fn release(self: *Admission) void {
        std.debug.assert(self.active > 0);
        self.active -= 1;
    }
};

test "websocket capacity is independent from ordinary HTTP admission" {
    var gate: Admission = .{ .max_inflight = 1, .max_websockets = 2 };
    try std.testing.expect(gate.acquireWebSocket());
    try std.testing.expect(gate.acquireWebSocket());
    try std.testing.expect(!gate.acquireWebSocket());
    try std.testing.expectEqual(null, gate.acquire(0));
    try std.testing.expectEqual(@as(usize, 1), gate.active);
    try std.testing.expectEqual(@as(usize, 2), gate.active_websockets);
    gate.release();
    gate.releaseWebSocket();
    try std.testing.expectEqual(@as(usize, 0), gate.active);
    try std.testing.expectEqual(@as(usize, 1), gate.active_websockets);
}

test "overload refuses work, release restores capacity, rate window expires" {
    var gate: Admission = .{ .max_inflight = 1, .max_per_second = 2 };
    try std.testing.expectEqual(null, gate.acquire(0));
    try std.testing.expectEqual(std.http.Status.service_unavailable, gate.acquire(0).?);
    gate.release();
    try std.testing.expectEqual(null, gate.acquire(10));
    gate.release();
    try std.testing.expectEqual(std.http.Status.too_many_requests, gate.acquire(999).?);
    try std.testing.expectEqual(null, gate.acquire(1000));
    gate.release();
    try std.testing.expectEqual(@as(usize, 0), gate.active);
}
