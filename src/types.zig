//! 领域模型：框架各处共享的请求 / 响应 / 处理器 / 配置类型。
//!
//! 单独成文件是为了切断 `router`/`middleware` 对 `server` 的反向依赖：
//! 这里只依赖 `std` 与 `http.zig`，因此任何层都能安全 import，不产生环。
const std = @import("std");
const http = @import("http.zig");

/// 重导出 `http.Header`，让调用方只需 `mox.Header`，无需感知内部分层。
pub const Header = http.Header;

/// 对 URL 编码的切片做解码，结果由 `gpa` 分配（通常传 `ctx.gpa`，即每请求
/// arena，无需调用方释放）。
///
/// - `%XX` 解成对应字节，十六进制大小写均可。
/// - `+` 解成空格（application/x-www-form-urlencoded 约定）。
/// - 非法序列（`%` 后不足两位、或非十六进制）返回 `error.InvalidEncoding`，
///   不静默丢弃——静默会把畸形输入变成另一种合法输入，比报错更危险。
///
/// 返回的切片长度精确等于解码结果（不是输入长度），调用方可以安全 free。
pub fn urlDecode(gpa: std.mem.Allocator, s: []const u8) ![]const u8 {
    // 没有 `%` 和 `+` 时原样返回，避免无谓分配。
    if (std.mem.indexOfScalar(u8, s, '%') == null and std.mem.indexOfScalar(u8, s, '+') == null) {
        return s;
    }
    // 第一遍：只校验并算出精确长度。先算长度再分配，避免「按输入长度分配、
    // 返回缩短切片」——那种切片的 len 与底层分配对不上，调用方 free 会 panic。
    var out_len: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '+') {
            out_len += 1;
            i += 1;
        } else if (s[i] == '%') {
            if (i + 2 >= s.len) return error.InvalidEncoding;
            _ = std.fmt.charToDigit(s[i + 1], 16) catch return error.InvalidEncoding;
            _ = std.fmt.charToDigit(s[i + 2], 16) catch return error.InvalidEncoding;
            out_len += 1;
            i += 3;
        } else {
            out_len += 1;
            i += 1;
        }
    }
    // 第二遍：按精确长度分配并解码。
    const out = try gpa.alloc(u8, out_len);
    errdefer gpa.free(out);
    var w: usize = 0;
    i = 0;
    while (i < s.len) {
        if (s[i] == '+') {
            out[w] = ' ';
            w += 1;
            i += 1;
        } else if (s[i] == '%') {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch unreachable; // 第一遍已校验
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch unreachable;
            out[w] = (hi << 4) | lo;
            w += 1;
            i += 3;
        } else {
            out[w] = s[i];
            w += 1;
            i += 1;
        }
    }
    return out;
}

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
    /// 此时忽略 `body`。路径会被复制到每连接内联缓冲，切片可用 ctx.gpa
    /// 分配（由每请求 arena 统一回收），无需活过处理器调用。
    file_path: []const u8 = "",
    /// WebSocket handler 函数指针（由 server.zig 解释）。
    ws_handler: ?WsHandler = null,
    /// SSE handler 函数指针（由 server.zig 解释）。
    sse_handler: ?SseHandler = null,
    /// 返回 JSON 响应：content_type 自动设为 application/json。
    /// `json_body` 必须是已序列化的 JSON 字节切片。
    pub fn withJson(json_body: []const u8) Response {
        return .{
            .body = json_body,
            .content_type = "application/json; charset=utf-8",
        };
    }

    /// 编译期 URL 重定向（适用于 URL 是常量的场景）。
    /// 运行时 URL：Header 值若由 ctx.gpa 分配，可放在 ctx 上或每请求 arena 中；
    /// 直接返回指向栈局部数组的切片会在 handler 返回后悬垂，不要这样做。
    /// 可用 `mox.setCookieHeader` 之外的自定义头构造，或提前在 ctx 生命周期内组装。
    pub fn redirect(comptime url: []const u8, status: std.http.Status) Response {
        // 利用匿名 struct 把 headers 数组存入静态区，确保指针生命周期。
        const S = struct {
            const h = [_]Header{.{ .name = "location", .value = url }};
        };
        return .{ .status = status, .headers = &S.h };
    }

    /// 触发 WebSocket 升级。handler 返回此值后，mox 完成握手并循环调用
    /// `ws_handler`，直到连接关闭。
    pub fn upgrade(handler: WsHandler) Response {
        return .{ .ws_handler = handler };
    }

    /// 触发 SSE 流。发出 SSE 头后开始 pump：handler 返回 true 时，
    /// 由 send 完成回调或 `writer.setTick(ms)` 定时器驱动下一次调用。
    pub fn sse(handler: SseHandler) Response {
        return .{ .sse_handler = handler };
    }
};

/// WebSocket 操作码。
pub const WsOpcode = enum(u8) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xa,
    _,
};

/// 单帧解码后的 WebSocket 消息。data 借用接收缓冲区（掩码已原地去除）。
pub const WsMessage = struct {
    opcode: WsOpcode,
    data: []u8,
};

/// 传给 ws_handler 的 WebSocket 连接句柄。
/// server.zig 负责在 handler 返回前保持此结构有效。
pub const WsConn = struct {
    /// 不透明指针，指向 server.zig 内部的 Connection；通过 vtable 操作。
    ptr: *anyopaque,
    vtable: *const WsVtable,

    /// 发送文本帧（UTF-8）。
    pub fn sendText(self: WsConn, data: []const u8) void {
        self.vtable.send(self.ptr, .text, data);
    }
    /// 发送二进制帧。
    pub fn sendBinary(self: WsConn, data: []const u8) void {
        self.vtable.send(self.ptr, .binary, data);
    }
    /// 发送 close 帧并关闭连接。
    pub fn close(self: WsConn) void {
        self.vtable.close(self.ptr);
    }
};

pub const WsVtable = struct {
    send: *const fn (ptr: *anyopaque, opcode: WsOpcode, data: []const u8) void,
    close: *const fn (ptr: *anyopaque) void,
};

/// WebSocket handler 签名：每收到一帧（或连接关闭）调用一次。
pub const WsHandler = *const fn (conn: WsConn, msg: WsMessage) void;

/// SSE writer 由 server.zig 管理；handler 通过它推送 event。
pub const SseWriter = struct {
    ptr: *anyopaque,
    vtable: *const SseVtable,

    /// 发送一个 SSE event。event 可为空（使用默认 "message"）。
    pub fn send(self: SseWriter, event: []const u8, data: []const u8) void {
        self.vtable.send(self.ptr, event, data);
    }
    /// 设置自动 pump 周期（毫秒）。handler 返回 true 且本次没有调用 send 时，
    /// 框架按此周期重新调用 handler，用于心跳 / 轮询式推送。
    /// 默认 1000ms；设为 0 关闭自动 tick（此时只有 send 完成回调能驱动下一次）。
    pub fn setTick(self: SseWriter, interval_ms: u32) void {
        self.vtable.set_tick(self.ptr, interval_ms);
    }
    /// 关闭 SSE 流。
    pub fn close(self: SseWriter) void {
        self.vtable.close(self.ptr);
    }
};

pub const SseVtable = struct {
    send: *const fn (ptr: *anyopaque, event: []const u8, data: []const u8) void,
    set_tick: *const fn (ptr: *anyopaque, interval_ms: u32) void,
    close: *const fn (ptr: *anyopaque) void,
};

/// SSE handler 签名：返回 true 保持流，false 结束流。
/// 返回 true 后，若本次调用了 `writer.send()`，发送完成回调会重新 pump；
/// 若本次没有 send，则按 `writer.setTick(ms)` 的周期由定时器重新 pump
/// （默认 1s，`setTick(0)` 可关闭）。
pub const SseHandler = *const fn (writer: SseWriter) bool;

/// 交给每个处理器与中间件的单次请求状态，仅在调用期间有效。
pub const Context = struct {
    gpa: std.mem.Allocator,
    request: *const http.Request,
    /// 捕获到的路径参数，仅在本次请求期间有效。
    params: *const Params,
    /// 已读完的请求体（空则为 ""）。指向 conn recv_buf，不额外分配。
    body: []const u8 = "",

    /// 读取路径参数，返回原始（未解码）切片。
    pub fn param(self: *const Context, name: []const u8) ?[]const u8 {
        return self.params.get(name);
    }

    /// 读取路径参数并做 URL 解码（`%XX` 与 `+` → 空格）。
    /// 结果由 `ctx.gpa` 分配（每请求 arena），生命周期到本次请求结束。
    pub fn paramDecoded(self: *const Context, name: []const u8) !?[]const u8 {
        const raw = self.params.get(name) orelse return null;
        return try urlDecode(self.gpa, raw);
    }

    /// 读取 URL 查询参数（`?key=val&...`）。
    /// 返回指向 request.target 的切片，不分配内存；值**未** URL 解码
    /// （`%20` 保持原样、`+` 不转空格）。需要解码后的值用 `queryDecoded`。
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

    /// 读取查询参数并做 URL 解码（`%XX` 与 `+` → 空格）。
    /// 结果由 `ctx.gpa` 分配（每请求 arena），生命周期到本次请求结束。
    /// 参数不存在返回 null；解码失败（非法 `%` 序列）返回 error.InvalidEncoding。
    pub fn queryDecoded(self: *const Context, name: []const u8) !?[]const u8 {
        const raw = self.query(name) orelse return null;
        return try urlDecode(self.gpa, raw);
    }

    /// 把请求体解析为 JSON 类型 `T`。返回 `std.json.Parsed(T)`；
    /// 在 mox 服务中其 arena 由每请求的 ctx.gpa 支撑，调用 `.deinit()` 无害，
    /// 不调用也会在请求结束时由框架统一回收。
    pub fn json(self: *const Context, comptime T: type) !std.json.Parsed(T) {
        return std.json.parseFromSlice(T, self.gpa, self.body, .{});
    }

    /// 解析 Cookie 请求头，返回指定名称的 cookie 值（指向原始头字符串，不分配）。
    pub fn cookie(self: *const Context, name: []const u8) ?[]const u8 {
        const hdr = self.request.header("cookie") orelse return null;
        var parts = std.mem.splitSequence(u8, hdr, "; ");
        while (parts.next()) |part| {
            const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
            const k = std.mem.trim(u8, part[0..eq], " ");
            if (std.mem.eql(u8, k, name)) return part[eq + 1 ..];
        }
        return null;

    }

    /// 读取必填路径参数；不存在则返回 error.MissingParam。
    pub fn requireParam(self: *const Context, name: []const u8) ![]const u8 {
        return self.param(name) orelse error.MissingParam;
    }

    /// 读取必填查询参数；不存在则返回 error.MissingQuery。
    pub fn requireQuery(self: *const Context, name: []const u8) ![]const u8 {
        return self.query(name) orelse error.MissingQuery;
    }

    /// 读取必填请求头；不存在则返回 error.MissingHeader。
    pub fn requireHeader(self: *const Context, name: []const u8) ![]const u8 {
        return self.request.header(name) orelse error.MissingHeader;
    }
};

pub const Handler = *const fn (*Context) anyerror!Response;


// ============================================================================
// Problem Details（RFC 9457）
// ============================================================================

/// RFC 9457 结构化错误响应。
/// `body` 由传入的 gpa 分配。在 mox 服务中 `ctx.gpa` 是每请求 arena，
/// 由框架在下次请求/连接关闭时统一回收，**调用方不要 free**。
pub fn problem(
    gpa: std.mem.Allocator,
    status: std.http.Status,
    title: []const u8,
    detail: []const u8,
) !Response {
    // 用带引号字段名的匿名 struct 保证 JSON key 合法（"type" 是 Zig 关键字）。
    const pd = struct {
        @"type": []const u8,
        status: u16,
        title: []const u8,
        detail: []const u8,
    }{
        .@"type" = "about:blank",
        .status = @backingInt(status),
        .title = title,
        .detail = detail,
    };
    const body = try std.json.Stringify.valueAlloc(gpa, pd, .{});
    return .{
        .status = status,
        .body = body,
        .content_type = "application/problem+json; charset=utf-8",
    };
}

// ============================================================================
// Cookie 支持
// ============================================================================

/// Set-Cookie 头构建选项。
pub const CookieOptions = struct {
    /// Cookie 路径，默认 "/"。
    path: []const u8 = "/",
    /// 是否加 Secure 标志（HTTPS 专用）。
    secure: bool = false,
    /// 是否加 HttpOnly 标志（阻止 JS 访问）。
    http_only: bool = true,
    /// SameSite 策略：Strict / Lax / None，空字符串则不加。
    same_site: []const u8 = "Lax",
    /// Cookie 有效时长（秒）；null = 会话 cookie。
    max_age: ?i64 = null,
};

/// 构建 `set-cookie` 响应头。值由 gpa 分配；在 mox 服务中 `ctx.gpa` 是每请求
/// arena，由框架统一回收，**调用方不要 free**（提前 free 会让响应头悬垂）。
///
/// 示例（headers 数组必须由 ctx.gpa 分配，不能用栈局部数组——handler
/// 返回后 respond() 才读它）：
///     const sc_hdr = try mox.setCookieHeader(ctx.gpa, "session", token, .{});
///     const hdrs = try ctx.gpa.alloc(mox.Header, 1);
///     hdrs[0] = sc_hdr;
///     return .{ .headers = hdrs, .body = "logged in\n" };
pub fn setCookieHeader(
    gpa: std.mem.Allocator,
    name: []const u8,
    value: []const u8,
    opts: CookieOptions,
) !Header {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, name);
    try buf.append(gpa, '=');
    try buf.appendSlice(gpa, value);
    if (opts.path.len > 0) {
        try buf.appendSlice(gpa, "; Path=");
        try buf.appendSlice(gpa, opts.path);
    }
    if (opts.secure) try buf.appendSlice(gpa, "; Secure");
    if (opts.http_only) try buf.appendSlice(gpa, "; HttpOnly");
    if (opts.same_site.len > 0) {
        try buf.appendSlice(gpa, "; SameSite=");
        try buf.appendSlice(gpa, opts.same_site);
    }
    if (opts.max_age) |age| {
        const age_str = try std.fmt.allocPrint(gpa, "; Max-Age={d}", .{age});
        defer gpa.free(age_str);
        try buf.appendSlice(gpa, age_str);
    }
    return .{ .name = "set-cookie", .value = try buf.toOwnedSlice(gpa) };
}

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

test "urlDecode 解码 %XX 与 +" {
    const gpa = std.testing.allocator;
    // %20 → 空格，%2F → /，+ → 空格，大小写十六进制都要认。
    const a = try urlDecode(gpa, "hello%20world+again");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("hello world again", a);

    const b = try urlDecode(gpa, "a%2Fb%3Dc%25d");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("a/b=c%d", b);

    // 大小写混写
    const c = try urlDecode(gpa, "%4a%4A");
    defer gpa.free(c);
    try std.testing.expectEqualStrings("JJ", c);
}

test "urlDecode 无编码时原样返回（零分配）" {
    const gpa = std.testing.allocator;
    // 没有 % 和 + 时直接返回入参切片，不分配——testing.allocator 会证明这点。
    const s = "plain-ascii-only";
    const out = try urlDecode(gpa, s);
    try std.testing.expectEqualStrings(s, out);
    try std.testing.expect(out.ptr == s.ptr);
}

test "urlDecode 非法序列返回 InvalidEncoding" {
    const gpa = std.testing.allocator;
    // 截断：% 后面不足两位
    try std.testing.expectError(error.InvalidEncoding, urlDecode(gpa, "abc%2"));
    try std.testing.expectError(error.InvalidEncoding, urlDecode(gpa, "abc%"));
    // 非十六进制
    try std.testing.expectError(error.InvalidEncoding, urlDecode(gpa, "abc%zz"));
    try std.testing.expectError(error.InvalidEncoding, urlDecode(gpa, "abc%g1"));
}

test "ctx.queryDecoded 与 paramDecoded 解码" {
    const gpa = std.testing.allocator;
    const req = http.Request{
        .method = .GET,
        .target = "/u/john%20doe?name=Jane+Doe&city=%E5%8C%97%E4%BA%AC",
        .path = "/u/john%20doe",
        .version = "HTTP/1.1",
        .head = "GET /u/john%20doe?name=Jane+Doe HTTP/1.1\r\n",
        .body = "",
        .keep_alive = true,
    };
    var params: Params = .{};
    _ = params.push("user", "john%20doe");
    var ctx = Context{ .gpa = gpa, .request = &req, .params = &params };

    // query 保持原始（未解码）
    try std.testing.expectEqualStrings("Jane+Doe", ctx.query("name").?);

    // queryDecoded 解码 + → 空格
    const name = (try ctx.queryDecoded("name")).?;
    defer gpa.free(name);
    try std.testing.expectEqualStrings("Jane Doe", name);

    // 多字节 UTF-8：%E5%8C%97%E4%BA%AC = 北京
    const city = (try ctx.queryDecoded("city")).?;
    defer gpa.free(city);
    try std.testing.expectEqualStrings("北京", city);

    // paramDecoded 解码路径参数
    const user = (try ctx.paramDecoded("user")).?;
    defer gpa.free(user);
    try std.testing.expectEqualStrings("john doe", user);

    // 不存在的参数返回 null（不是错误）
    try std.testing.expect((try ctx.queryDecoded("nope")) == null);
    try std.testing.expect((try ctx.paramDecoded("nope")) == null);
}
