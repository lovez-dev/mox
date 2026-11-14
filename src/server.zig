//! HTTP 服务公共门面。实现按生命周期、协议和响应类型组织在 server/ 中。
const runtime = @import("server/runtime.zig");
const metrics = @import("server/metrics.zig");
const types = @import("types.zig");
pub const serve = runtime.serve;
pub const serveWith = runtime.serveWith;
pub const MountHook = runtime.MountHook;
pub const Response = types.Response;
pub const Context = types.Context;
pub const Handler = types.Handler;
pub const Config = types.Config;
pub const Metrics = metrics.Metrics;
pub const getMetrics = metrics.getMetrics;
pub const metricsHandler = metrics.metricsHandler;
test {
    _ = @import("server/tests.zig");
}
