//! 中间件组合。
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

/// 中间件调用约定：`fn (comptime next: Handler) Handler`。
///
/// 该类型的值要么由普通函数从自身作用域返回函数得到，
/// 要么由 `requireHeader` 这样的带参工厂得到。
/// Zig 的函数值不携带捕获状态，因此 `next`
/// 始终是 comptime 参数。
pub const Middleware = fn (comptime next: Handler) Handler;

/// 把 `middlewares` 折叠到 `terminal` 外围；元组第一项在最外层执行。
///
/// 示例：const app = compose(.{ logging, requireHeader("x-api-key", "secret") }, index);
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
                @intFromEnum(response.status),
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
