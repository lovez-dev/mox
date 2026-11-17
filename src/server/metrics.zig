//! Process-wide request counters, duration buckets, and JSON snapshots.

const std = @import("std");
const types = @import("../types.zig");

/// All admitted requests across server instances.
var metrics_total_requests = std.atomic.Value(u64).init(0);
/// Handler failures; status-class counters track final responses separately.
var metrics_total_errors = std.atomic.Value(u64).init(0);
/// Open connections across server instances.
var metrics_active_conns = std.atomic.Value(u64).init(0);
const Counter = std.atomic.Value(u64);
var active_requests: Counter = .init(0);
var completed_requests: Counter = .init(0);
var aborted_requests: Counter = .init(0);
var duration_ms_sum: Counter = .init(0);
var response_classes: [5]Counter = .{ .init(0), .init(0), .init(0), .init(0), .init(0) };
pub const duration_bounds_ms = [_]u64{ 1, 5, 10, 50, 100, 500, 1000, 5000 };
var duration_buckets: [8]Counter = .{ .init(0), .init(0), .init(0), .init(0), .init(0), .init(0), .init(0), .init(0) };

/// Fields are loaded independently; a snapshot is not transactional.
pub const Metrics = struct {
    total_requests: u64,
    total_errors: u64,
    active_conns: u64,
    active_requests: u64,
    completed_requests: u64,
    aborted_requests: u64,
    responses_1xx: u64,
    responses_2xx: u64,
    responses_3xx: u64,
    responses_4xx: u64,
    responses_5xx: u64,
    duration_ms_sum: u64,
    duration_bounds_ms: [8]u64,
    duration_buckets: [8]u64,
};

pub fn getMetrics() Metrics {
    var buckets: [8]u64 = undefined;
    for (&buckets, &duration_buckets) |*out, *counter| out.* = counter.load(.monotonic);
    return .{
        .total_requests = metrics_total_requests.load(.monotonic),
        .total_errors = metrics_total_errors.load(.monotonic),
        .active_conns = metrics_active_conns.load(.monotonic),
        .active_requests = active_requests.load(.monotonic),
        .completed_requests = completed_requests.load(.monotonic),
        .aborted_requests = aborted_requests.load(.monotonic),
        .responses_1xx = response_classes[0].load(.monotonic),
        .responses_2xx = response_classes[1].load(.monotonic),
        .responses_3xx = response_classes[2].load(.monotonic),
        .responses_4xx = response_classes[3].load(.monotonic),
        .responses_5xx = response_classes[4].load(.monotonic),
        .duration_ms_sum = duration_ms_sum.load(.monotonic),
        .duration_bounds_ms = duration_bounds_ms,
        .duration_buckets = buckets,
    };
}

/// JSON endpoint; its own request is included in active_requests.
pub fn metricsHandler(ctx: *types.Context) anyerror!types.Response {
    const body = try std.json.Stringify.valueAlloc(ctx.gpa, getMetrics(), .{});
    return .{ .body = body, .content_type = "application/json" };
}

pub fn requestStarted() u64 {
    _ = active_requests.fetchAdd(1, .monotonic);
    return metrics_total_requests.fetchAdd(1, .monotonic) +% 1;
}

pub fn requestFinished(event: types.RequestEvent) void {
    _ = active_requests.fetchSub(1, .monotonic);
    const ended = if (event.completed) &completed_requests else &aborted_requests;
    _ = ended.fetchAdd(1, .monotonic);
    if (event.status >= 100 and event.status < 600)
        _ = response_classes[event.status / 100 - 1].fetchAdd(1, .monotonic);
    _ = duration_ms_sum.fetchAdd(event.duration_ms, .monotonic);
    for (duration_bounds_ms, &duration_buckets) |bound, *counter| {
        if (event.duration_ms <= bound) _ = counter.fetchAdd(1, .monotonic);
    }
}

pub fn requestFailed() void {
    _ = metrics_total_errors.fetchAdd(1, .monotonic);
}

pub fn connectionOpened() void {
    _ = metrics_active_conns.fetchAdd(1, .monotonic);
}

pub fn connectionClosed() void {
    _ = metrics_active_conns.fetchSub(1, .monotonic);
}
