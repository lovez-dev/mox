//! 请求指标与指标端点；计数器独立于连接及协议实现。
const std = @import("std");
const types = @import("../types.zig");

/// 总请求数（所有连接累计）
var metrics_total_requests = std.atomic.Value(u64).init(0);
/// 总错误数（handler 返回错误 + not_found 兜底算作 4xx，不计入）
var metrics_total_errors = std.atomic.Value(u64).init(0);
/// 当前活跃连接数（register/unregister 同步）
var metrics_active_conns = std.atomic.Value(u64).init(0);

/// 读取当前指标快照（非事务性，各字段独立 load）。
pub const Metrics = struct {
    total_requests: u64,
    total_errors: u64,
    active_conns: u64,
};
pub fn getMetrics() Metrics {
    return .{
        .total_requests = metrics_total_requests.load(.monotonic),
        .total_errors = metrics_total_errors.load(.monotonic),
        .active_conns = metrics_active_conns.load(.monotonic),
    };
}

/// 可直接注册为路由 handler 的指标端点。
/// 返回 JSON：{"total_requests":N,"total_errors":N,"active_conns":N}
pub fn metricsHandler(ctx: *types.Context) anyerror!types.Response {
    const m = getMetrics();
    const body = try std.fmt.allocPrint(
        ctx.gpa,
        "{{\"total_requests\":{d},\"total_errors\":{d},\"active_conns\":{d}}}",
        .{ m.total_requests, m.total_errors, m.active_conns },
    );
    return .{ .body = body, .content_type = "application/json" };
}

pub fn requestStarted() void {
    _ = metrics_total_requests.fetchAdd(1, .monotonic);
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
