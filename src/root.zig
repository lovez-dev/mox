//! HTTP routing, streaming, and sessions over mox.io.

pub const types = @import("types.zig");
pub const server = @import("server.zig");
pub const router = @import("router.zig");
pub const middleware = @import("middleware.zig");
pub const template = @import("template.zig");
pub const Template = template.Template;
pub const TemplateLimits = template.Limits;

pub const serve = server.serve;
pub const mox_io = @import("mox_io");
pub const io = mox_io;
pub const http = @import("http.zig");
pub const Config = types.Config;
pub const ServerControl = @import("server/control.zig").ServerControl;
pub const Context = types.Context;
pub const Response = types.Response;
pub const Stream = types.Stream;
pub const StreamWriter = types.StreamWriter;
pub const Handler = types.Handler;

pub const Route = router.Route;
pub const ProxyOptions = types.ProxyOptions;
pub const proxyRoute = types.proxyRoute;
pub const Router = router.Router;
pub const Params = router.Params;

pub const compose = middleware.compose;
pub const Middleware = middleware.Middleware;
pub const cors = middleware.cors;
pub const CorsOptions = middleware.CorsOptions;
pub const logging = middleware.logging;
pub const requireHeader = middleware.requireHeader;
pub const mimeFor = middleware.mimeFor;
pub const staticDir = middleware.staticDir;
pub const rateLimit = middleware.rateLimit;
pub const RateLimitOptions = middleware.RateLimitOptions;
pub const jsonLog = middleware.jsonLog;
pub const Header = types.Header;
pub const ErrorHandler = types.ErrorHandler;
pub const group = types.group;
pub const routes = types.routes;
pub const multipart = @import("multipart.zig");
pub const Multipart = multipart.Part;
pub const MultipartStreamParser = multipart.StreamParser;
pub const MultipartStreamEvent = multipart.StreamEvent;
pub const MultipartStreamHandler = multipart.StreamHandler;
pub const extractBoundary = multipart.extractBoundary;
pub const parseMultipart = multipart.parse;
pub const WsConn = types.WsConn;
pub const WsMessage = types.WsMessage;
pub const WsOpcode = types.WsOpcode;
pub const WsHandler = types.WsHandler;
pub const WsSendError = types.WsSendError;
pub const SseWriter = types.SseWriter;
pub const SseHandler = types.SseHandler;
pub const problem = types.problem;
pub const CookieOptions = types.CookieOptions;
pub const setCookieHeader = types.setCookieHeader;
pub const Metrics = server.Metrics;
pub const getMetrics = server.getMetrics;
pub const metricsHandler = server.metricsHandler;
pub const RequestEvent = types.RequestEvent;
pub const jsonAccessLog = @import("server/observation.zig").jsonAccessLog;
pub const requestId = middleware.requestId;
pub const bodyLimit = middleware.bodyLimit;
pub const cache = middleware.cache;
pub const urlDecode = types.urlDecode;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("server/session.zig");
    _ = @import("server/memory.zig");
    _ = @import("server/admission.zig");
    _ = @import("server/proxy_protocol.zig");
    _ = @import("server/proxy_framing.zig");
    _ = @import("websocket/protocol.zig");
}
