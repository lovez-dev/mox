//! 领域模型：框架各处共享的请求 / 响应 / 处理器 / 配置类型。
//!
//! 单独成文件是为了切断 `router`/`middleware` 对 `server` 的反向依赖：
//! 这里只依赖 `std` 与 `http.zig`，因此任何层都能安全 import，不产生环。
const std = @import("std");
const http = @import("http.zig");

/// 重导出 `http.Header`，让调用方只需 `mox.Header`，无需感知内部分层。
pub const Header = http.Header;

/// 单次请求捕获到的路径参数。值是指向
/// 请求目标的切片，故仅在本次请求期间有效。
pub const Params = struct {
    items: [max]Item = undefined,
    len: usize = 0,

    pub const max = 8;
    pub const Item = struct { name: []const u8, value: []const u8 };

    pub fn get(self: *const Params, name: []const u8) ?[]const u8 {
        for (self.items[0..self.len]) |item| {
            if (std.mem.eql(u8, item.name, name)) return item.value;
        }
        return null;
    }

    /// 由路由器在匹配时写入捕获值。
    pub fn push(self: *Params, name: []const u8, value: []const u8) bool {
        if (self.len == max) return false;
        self.items[self.len] = .{ .name = name, .value = value };
        self.len += 1;
        return true;
    }
};

/// 处理器的返回值。`body` 是借用的，必须存活到响应写出完毕为止。
pub const Response = struct {
    status: std.http.Status = .ok,
    body: []const u8 = "",
    content_type: []const u8 = "text/plain; charset=utf-8",
    /// 额外响应头（调用方拥有生命周期，仅在响应写出期间有效）。
    headers: []const Header = &.{},
    /// 设置后，文件内容在 `Work` 池线程读取并作为 body 发送，
    /// 此时忽略 `body`。路径会被复制，故该切片无需活过处理器调用。
    file_path: []const u8 = "",
    /// `file_path` 由处理器堆分配时置位（由 mox 释放）。
    file_path_owned: bool = false,

    /// 返回 JSON 响应：content_type 自动设为 application/json。
    /// `json_body` 必须是已序列化的 JSON 字节切片。
    pub fn withJson(json_body: []const u8) Response {
        return .{
            .body = json_body,
            .content_type = "application/json; charset=utf-8",
        };
    }

    /// 编译期 URL 重定向（适用于 URL 是常量的场景）。
    /// 运行时 URL 场景：直接构造
    ///   `var hdrs = [_]Header{.{ .name = "location", .value = url }};`
    ///   `return .{ .status = s, .headers = &hdrs };`
    pub fn redirect(comptime url: []const u8, status: std.http.Status) Response {
        // 利用匿名 struct 把 headers 数组存入静态区，确保指针生命周期。
        const S = struct {
            const h = [_]Header{.{ .name = "location", .value = url }};
        };
        return .{ .status = status, .headers = &S.h };
    }
};

/// 交给每个处理器与中间件的单次请求状态，仅在调用期间有效。
pub const Context = struct {
    gpa: std.mem.Allocator,
    request: *const http.Request,
    /// 捕获到的路径参数，仅在本次请求期间有效。
    params: *const Params,
    /// 已读完的请求体（空则为 ""）。指向 conn recv_buf，不额外分配。
    body: []const u8 = "",

    pub fn param(self: *const Context, name: []const u8) ?[]const u8 {
        return self.params.get(name);
    }

    /// 读取 URL 查询参数（`?key=val&...`）。
    /// 返回指向 request.target 的切片，不分配内存；值未 URL 解码。
    pub fn query(self: *const Context, name: []const u8) ?[]const u8 {
        const target = self.request.target;
        const q_start = (std.mem.indexOfScalar(u8, target, '?') orelse return null) + 1;
        var pairs = std.mem.splitScalar(u8, target[q_start..], '&');
        while (pairs.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
        }
        return null;
    }

    /// 把请求体解析为 JSON 类型 `T`。调用方负责 `parsed.deinit()`。
    pub fn json(self: *const Context, comptime T: type) !std.json.Parsed(T) {
        return std.json.parseFromSlice(T, self.gpa, self.body, .{});
    }
};

pub const Handler = *const fn (*Context) anyerror!Response;

pub const Route = struct {
    method: std.http.Method,
    path: []const u8,
    handler: Handler,
};


/// 路由分组：在编译期把 `prefix` 拼到每条路由的路径前，
/// 返回扩展后的路由切片。用于 `Config.routes` 组合：
///
///     const v1 = mox.group("/api/v1", &.{
///         .{ .method = .GET,  .path = "/users", .handler = listUsers },
///         .{ .method = .POST, .path = "/users", .handler = createUser },
///     });
///     const cfg = mox.Config{ .routes = v1, ... };
pub fn group(comptime prefix: []const u8, comptime defs: []const Route) []const Route {
    comptime {
        var out: [defs.len]Route = undefined;
        for (defs, 0..) |r, i| {
            out[i] = .{
                .method = r.method,
                // 编译期字符串拼接
                .path = prefix ++ r.path,
                .handler = r.handler,
            };
        }
        const result = out;
        return &result;
    }
}

/// 合并多个路由切片为一个（编译期展平）。
///
///     const all = mox.routes(.{ v1_routes, v2_routes, public_routes });
pub fn routes(comptime groups: anytype) []const Route {
    comptime {
        var total: usize = 0;
        for (groups) |g| total += g.len;
        var out: [total]Route = undefined;
        var pos: usize = 0;
        for (groups) |g| {
            for (g) |r| {
                out[pos] = r;
                pos += 1;
            }
        }
        const result = out;
        return &result;
    }
}

pub const Config = struct {
    gpa: std.mem.Allocator,
    address: std.Io.net.IpAddress,
    routes: []const Route,

    /// 并发连接上限。达到上限后不再 `accept`，新连接在内核 backlog 排队。
    max_connections: usize = 1024,

    /// 空闲超时（毫秒）：两次请求之间允许的最长静默时间。0 = 不设。
    idle_timeout_ms: u32 = 60_000,

    /// `accept` 失败后的退避毫秒数。
    accept_backoff_ms: u32 = 50,

    /// 优雅停机总预算（毫秒）。
    shutdown_timeout_ms: u32 = 5_000,

    /// 请求体上限（字节）。超出返回 413 Payload Too Large。0 = 不限。
    max_body_size: usize = 4 * 1024 * 1024,

    /// 单次请求最长处理时间（毫秒）。超时后强制关闭连接。0 = 不限。默认 30s。
    request_timeout_ms: u32 = 30_000,

    /// handler 返回错误时的兜底响应。默认返回 500 + 错误名字字符串。
    error_handler: ErrorHandler = defaultErrorHandler,

    /// 路由未命中时的兜底响应。默认返回 404 "not found\n"。
    not_found: Handler = defaultNotFound,
};

pub fn defaultNotFound(_: *Context) anyerror!Response {
    return .{ .status = .not_found, .body = "not found\n" };
}

pub fn defaultErrorHandler(_: *Context, err: anyerror) Response {
    return .{ .status = .internal_server_error, .body = @errorName(err) };
}

pub const ErrorHandler = *const fn (*Context, anyerror) Response;

// ---- 测试 ------------------------------------------------------------------
test "query 解析 URL 查询参数" {
    const req: http.Request = .{
        .method = .GET,
        .target = "/path?name=alice&age=30",
        .path = "/path",
        .version = "HTTP/1.1",
        .head = "",
        .body = "",
        .keep_alive = true,
    };
    var params: Params = .{};
    const ctx: Context = .{
        .gpa = std.testing.allocator,
        .request = &req,
        .params = &params,
        .body = "",
    };
    try std.testing.expectEqualStrings("alice", ctx.query("name").?);
    try std.testing.expectEqualStrings("30", ctx.query("age").?);
    try std.testing.expectEqual(@as(?[]const u8, null), ctx.query("missing"));
    try std.testing.expectEqual(@as(?[]const u8, null), ctx.query("NAME")); // 大小写敏感，不匹配
}
test "query 无查询串返回 null" {
    const req: http.Request = .{
        .method = .GET,
        .target = "/path",
        .path = "/path",
        .version = "HTTP/1.1",
        .head = "",
        .body = "",
        .keep_alive = true,
    };
    var params: Params = .{};
    const ctx: Context = .{
        .gpa = std.testing.allocator,
        .request = &req,
        .params = &params,
    };
    try std.testing.expectEqual(@as(?[]const u8, null), ctx.query("key"));
}
test "Response.withJson 设置 application/json content_type" {
    const r = Response.withJson("{\"ok\":true}");
    try std.testing.expectEqualStrings("{\"ok\":true}", r.body);
    try std.testing.expect(std.mem.startsWith(u8, r.content_type, "application/json"));
}
test "Response.redirect 生成 Location 头" {
    const r = Response.redirect("/new-path", .moved_permanently);
    try std.testing.expectEqual(std.http.Status.moved_permanently, r.status);
    try std.testing.expectEqual(@as(usize, 1), r.headers.len);
    try std.testing.expectEqualStrings("location", r.headers[0].name);
    try std.testing.expectEqualStrings("/new-path", r.headers[0].value);
}
test "ctx.json 解析 JSON 请求体" {
    const body = "{\"n\":42}";
    const req: http.Request = .{
        .method = .POST,
        .target = "/",
        .path = "/",
        .version = "HTTP/1.1",
        .head = "",
        .body = body,
        .keep_alive = false,
    };
    var params: Params = .{};
    const ctx: Context = .{
        .gpa = std.testing.allocator,
        .request = &req,
        .params = &params,
        .body = body,
    };
    const T = struct { n: i64 };
    const parsed = try ctx.json(T);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 42), parsed.value.n);
}
