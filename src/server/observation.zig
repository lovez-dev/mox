//! Request-scoped observations with bounded, callback-scoped paths.

const std = @import("std");
const types = @import("../types.zig");
const metrics = @import("metrics.zig");

pub const Observation = struct {
    active: bool = false,
    id: u64 = 0,
    started_ms: u64 = 0,
    method: []const u8 = "",
    path: [256]u8 = undefined,
    path_len: usize = 0,
    path_truncated: bool = false,
    status: u16 = 0,
    error_name: ?[]const u8 = null,

    pub fn start(self: *Observation, now: u64) void {
        if (self.active) return;
        self.* = .{ .active = true, .id = metrics.requestStarted(), .started_ms = now };
    }

    pub fn identify(self: *Observation, method: std.http.Method, path: []const u8) void {
        self.method = @tagName(method);
        self.path_len = @min(path.len, self.path.len);
        @memcpy(self.path[0..self.path_len], path[0..self.path_len]);
        self.path_truncated = path.len > self.path.len;
    }

    pub fn finish(self: *Observation, now: u64, completed: bool) ?types.RequestEvent {
        if (!self.active) return null;
        self.active = false;
        const event: types.RequestEvent = .{
            .request_id = self.id,
            .method = self.method,
            .path = self.path[0..self.path_len],
            .path_truncated = self.path_truncated,
            .status = self.status,
            .duration_ms = now -| self.started_ms,
            .completed = completed,
            .error_name = self.error_name orelse if (completed) null else "Interrupted",
        };
        metrics.requestFinished(event);
        return event;
    }
};

/// Optional Config.on_request_complete sink. JSON escaping prevents log injection.
/// No headers, query strings, or bodies are logged. stderr output is synchronous.
pub fn jsonAccessLog(event: types.RequestEvent) void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    std.json.Stringify.value(event, .{ .emit_null_optional_fields = true }, &writer) catch return;
    std.debug.print("{s}\n", .{writer.buffered()});
}

test "observation owns path and finishes once" {
    const before = metrics.getMetrics();
    var obs: Observation = .{};
    obs.start(10);
    var path: [300]u8 = @splat('x');
    obs.identify(.POST, &path);
    path[0] = 'y';
    obs.status = 503;
    const event = obs.finish(35, true).?;
    try std.testing.expectEqual(@as(u64, 25), event.duration_ms);
    try std.testing.expect(event.path_truncated);
    try std.testing.expectEqual(@as(u8, 'x'), event.path[0]);
    try std.testing.expectEqual(null, obs.finish(40, false));
    obs.start(40);
    const interrupted = obs.finish(50, false).?;
    try std.testing.expectEqualStrings("Interrupted", interrupted.error_name.?);
    const after = metrics.getMetrics();
    try std.testing.expectEqual(before.active_requests, after.active_requests);
    try std.testing.expectEqual(before.completed_requests + 1, after.completed_requests);
    try std.testing.expectEqual(before.aborted_requests + 1, after.aborted_requests);
    try std.testing.expectEqual(before.responses_5xx + 1, after.responses_5xx);
    try std.testing.expectEqual(before.duration_ms_sum + 35, after.duration_ms_sum);
}
