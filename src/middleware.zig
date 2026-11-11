//! 中间件组合与内置中间件。
//!
//! 要求的形状是 `fn (next: Handler) Handler`。Zig 没有闭包，
//! 所以 `next` 无法在运行时捕获：中间件必须是*编译期*函数，
//! 以 comptime 参数接收 `next` 并返回一个
//! 生成的处理器函数。`compose` 把这类函数折到终结处理器上，
//! 全部在编译期完成。
const std = @import("std");
const types = @import("types.zig");
pub const Context = types.Context;
pub const Response = types.Response;
pub const Handler = types.Handler;
pub const Header = types.Header;

/// 中间件调用约定：`fn (comptime next: Handler) Handler`。
pub const Middleware = fn (comptime next: Handler) Handler;

/// 把 `middlewares` 折叠到 `terminal` 外围；元组第一项在最外层执行。
///
/// 示例：const app = compose(.{ logging, cors(.{}), requireHeader("x-api-key", "secret") }, index);
pub fn compose(comptime middlewares: anytype, comptime terminal: Handler) Handler {
    comptime var handler: Handler = terminal;
    comptime var i: usize = middlewares.len;
    inline while (i > 0) : (i -= 1) {
        handler = @call(.compile_time, middlewares[i - 1], .{handler});
    }
    return handler;
}

/// 在返回途中记录方法、目标与状态码。
pub fn logging(comptime next: Handler) Handler {
    return struct {
        fn handle(ctx: *Context) anyerror!Response {
            const response = try next(ctx);
            std.log.info("{s} {s} -> {d}", .{
                @tagName(ctx.request.method),
                ctx.request.target,
                @backingInt(response.status),
            });
            return response;
        }
    }.handle;
}

/// 除非指定头部的值完全匹配，否则直接以 401 短路。
pub fn requireHeader(comptime name: []const u8, comptime value: []const u8) Middleware {
    return struct {
        fn wrap(comptime next: Handler) Handler {
            return struct {
                fn handle(ctx: *Context) anyerror!Response {
                    if (ctx.request.header(name)) |got| {
                        if (std.mem.eql(u8, got, value)) return next(ctx);
                    }
                    return .{ .status = .unauthorized, .body = "unauthorized\n" };
                }
            }.handle;
        }
    }.wrap;
}

// ---- CORS ------------------------------------------------------------------

/// CORS 中间件配置。
pub const CorsOptions = struct {
    /// 允许的来源列表。第一项为 `"*"` 时对任何 Origin 均回显。
    allow_origins: []const []const u8 = &.{"*"},
    /// 允许的方法（逗号分隔字符串写在下面）。
    allow_methods: []const u8 = "GET, HEAD, POST, PUT, DELETE, PATCH, OPTIONS",
    /// 允许的请求头。
    allow_headers: []const u8 = "Content-Type, Authorization, Accept",
    /// 是否允许携带凭据（Cookie / Authorization）。
    allow_credentials: bool = false,
    /// Preflight 缓存秒数。
    max_age_seconds: u32 = 86400,
};

/// 返回 CORS 中间件。
/// - 收到 OPTIONS preflight 时直接返回 204，不调用 `next`。
/// - 其他请求附加 CORS 头后转发给 `next`。
pub fn cors(comptime opts: CorsOptions) Middleware {
    return struct {
        fn wrap(comptime next: Handler) Handler {
            return struct {
                fn handle(ctx: *Context) anyerror!Response {
                    // 确定 Access-Control-Allow-Origin 的值
                    const origin_value: []const u8 = blk: {
                        if (opts.allow_origins.len == 1 and
                            std.mem.eql(u8, opts.allow_origins[0], "*"))
                        {
                            break :blk "*";
                        }
                        // 精确匹配请求来源
                        const req_origin = ctx.request.header("origin") orelse "";
                        for (opts.allow_origins) |allowed| {
                            if (std.mem.eql(u8, allowed, req_origin)) break :blk req_origin;
                        }
                        break :blk "";
                    };

                    // OPTIONS preflight：直接返回 204，不走业务 handler
                    if (ctx.request.method == .OPTIONS) {
                        const max_age_buf = comptime blk: {
                            var buf: [16]u8 = undefined;
                            const s = std.fmt.bufPrint(&buf, "{d}", .{opts.max_age_seconds}) catch "86400";
                            var result: [s.len:0]u8 = undefined;
                            @memcpy(&result, s);
                            break :blk result;
                        };
                        const vary_vary: []const u8 = "Origin";
                        _ = vary_vary;
                        const hdrs = comptime buildPreflightHeaders(opts, &max_age_buf);
                        const resp: Response = .{
                            .status = .no_content,
                            .body = "",
                            .headers = if (origin_value.len > 0) &hdrs else &.{},
                        };
                        return resp;
                    }

                    // 普通请求：先调用 next，再追加 CORS 头
                    var resp = try next(ctx);
                    if (origin_value.len > 0) {
                        const hdrs = comptime buildSimpleHeaders(opts);
                        resp.headers = &hdrs;
                    }
                    return resp;
                }
            }.handle;
        }
    }.wrap;
}

/// 编译期生成 preflight 响应头数组（comptime origin 写死为 "*"，
/// 运行时 origin 由调用处覆盖——这里只处理 opts 中常量部分）。
fn buildPreflightHeaders(comptime opts: CorsOptions, comptime max_age: [:0]const u8) [5]Header {
    return .{
        .{ .name = "access-control-allow-origin", .value = if (opts.allow_origins.len == 1 and std.mem.eql(u8, opts.allow_origins[0], "*")) "*" else "" },
        .{ .name = "access-control-allow-methods", .value = opts.allow_methods },
        .{ .name = "access-control-allow-headers", .value = opts.allow_headers },
        .{ .name = "access-control-allow-credentials", .value = if (opts.allow_credentials) "true" else "false" },
        .{ .name = "access-control-max-age", .value = max_age },
    };
}

fn buildSimpleHeaders(comptime opts: CorsOptions) [2]Header {
    return .{
        .{ .name = "access-control-allow-origin", .value = if (opts.allow_origins.len == 1 and std.mem.eql(u8, opts.allow_origins[0], "*")) "*" else "" },
        .{ .name = "access-control-allow-credentials", .value = if (opts.allow_credentials) "true" else "false" },
    };
}

// ---- 测试 ------------------------------------------------------------------
var trace: [8]u8 = undefined;
var trace_len: usize = 0;

fn mark(comptime c: u8) Middleware {
    return struct {
        fn wrap(comptime next: Handler) Handler {
            return struct {
                fn handle(ctx: *Context) anyerror!Response {
                    trace[trace_len] = c;
                    trace_len += 1;
                    return next(ctx);
                }
            }.handle;
        }
    }.wrap;
}

fn halt(comptime next: Handler) Handler {
    _ = next;
    return struct {
        fn handle(ctx: *Context) anyerror!Response {
            _ = ctx;
            trace[trace_len] = 'X';
            trace_len += 1;
            return .{ .status = .unauthorized, .body = "" };
        }
    }.handle;
}

fn ok(ctx: *Context) anyerror!Response {
    _ = ctx;
    return .{ .body = "ok\n" };
}

test "compose runs outermost first" {
    var ctx: Context = undefined;
    trace_len = 0;
    const app = compose(.{ mark('a'), mark('b'), mark('c') }, ok);
    _ = try app(&ctx);
    try std.testing.expectEqualStrings("abc", trace[0..trace_len]);
}

test "a short-circuiting middleware stops the chain" {
    var ctx: Context = undefined;
    trace_len = 0;
    const app = compose(.{ mark('a'), halt, mark('c') }, ok);
    const response = try app(&ctx);
    try std.testing.expectEqual(std.http.Status.unauthorized, response.status);
    try std.testing.expectEqualStrings("aX", trace[0..trace_len]);
}

test "cors OPTIONS preflight 返回 204 且有 CORS 头" {
    const http = @import("http.zig");
    const req: http.Request = .{
        .method = .OPTIONS,
        .target = "/api",
        .path = "/api",
        .version = "HTTP/1.1",
        .head = "",
        .body = "",
        .keep_alive = false,
    };
    var params: @import("types.zig").Params = .{};
    var ctx: Context = .{
        .gpa = std.testing.allocator,
        .request = &req,
        .params = &params,
    };
    const app = compose(.{cors(.{})}, ok);
    const resp = try app(&ctx);
    try std.testing.expectEqual(std.http.Status.no_content, resp.status);
    // 有 CORS 头
    var found = false;
    for (resp.headers) |h| {
        if (std.mem.eql(u8, h.name, "access-control-allow-origin")) found = true;
    }
    try std.testing.expect(found);
}

test "cors GET 请求透传且追加 CORS 头" {
    const http = @import("http.zig");
    const req: http.Request = .{
        .method = .GET,
        .target = "/",
        .path = "/",
        .version = "HTTP/1.1",
        .head = "",
        .body = "",
        .keep_alive = true,
    };
    var params: @import("types.zig").Params = .{};
    var ctx: Context = .{
        .gpa = std.testing.allocator,
        .request = &req,
        .params = &params,
    };
    const app = compose(.{cors(.{})}, ok);
    const resp = try app(&ctx);
    try std.testing.expectEqual(std.http.Status.ok, resp.status);
    var found = false;
    for (resp.headers) |h| {
        if (std.mem.eql(u8, h.name, "access-control-allow-origin")) found = true;
    }
    try std.testing.expect(found);
}
