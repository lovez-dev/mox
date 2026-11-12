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

// ---- 静态文件 MIME 检测 ---------------------------------------------------

/// 根据文件扩展名猜测 Content-Type。
pub fn mimeFor(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html") or std.mem.endsWith(u8, path, ".htm"))
        return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".js")) return "text/javascript; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg"))
        return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".gif")) return "image/gif";
    if (std.mem.endsWith(u8, path, ".ico")) return "image/x-icon";
    if (std.mem.endsWith(u8, path, ".woff2")) return "font/woff2";
    if (std.mem.endsWith(u8, path, ".woff")) return "font/woff";
    if (std.mem.endsWith(u8, path, ".txt")) return "text/plain; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".xml")) return "application/xml";
    if (std.mem.endsWith(u8, path, ".pdf")) return "application/pdf";
    if (std.mem.endsWith(u8, path, ".wasm")) return "application/wasm";
    return "application/octet-stream";
}

/// 静态文件目录 handler 工厂。
///
/// `staticDir("/public")` 返回一个 Handler，把路由里的 `*path`
/// 参数拼到 `dir` 前缀后作为磁盘路径（走 Work 池读取）：
///
///     .{ .method = .GET, .path = "/static/*path", .handler = mox.staticDir("/public") }
///
/// 注意：`dir` 必须是编译期常量（comptime），路径拼接在堆上分配。
pub fn staticDir(comptime dir: []const u8) Handler {
    return struct {
        fn handle(ctx: *Context) anyerror!Response {
            const sub = ctx.param("path") orelse
                return Response{ .status = .not_found, .body = "not found\n" };
            // 防路径穿越：拒绝含 .. 的子路径。
            if (std.mem.indexOf(u8, sub, "..") != null)
                return Response{ .status = .bad_request, .body = "bad path\n" };
            const path = try std.fmt.allocPrint(ctx.gpa, dir ++ "{s}", .{sub});
            return Response{
                .file_path = path,
                .content_type = mimeFor(sub),
            };
        }
    }.handle;
}

// ---- 限流（滑动窗口 / per-IP token bucket）-------------------------------

/// 限流中间件配置。
pub const RateLimitOptions = struct {
    /// 窗口大小（毫秒）。
    window_ms: u64 = 60_000,
    /// 每个来源在窗口内允许的最大请求数。
    max_requests: u32 = 100,
    /// 超限时的响应体文字。
    message: []const u8 = "rate limit exceeded\n",
};

/// 返回基于内存的 per-IP 滑动计数器限流中间件。
///
/// **重要**：每次 `compose` 调用生成独立的全局计数器（comptime static），
/// 因此同一进程里不要对同一路由 `compose` 两次。
/// 生产用途建议用外部 Redis 计数器；此实现适合单节点测试/原型。
pub fn rateLimit(comptime opts: RateLimitOptions) Middleware {
    return struct {
        // 每个 Bucket 对应一个 IPv4/IPv6 来源。最多 1024 个桶；超出时 LRU 淘汰最旧。
        const max_buckets = 1024;
        const Bucket = struct {
            ip: [64]u8 = undefined,
            ip_len: usize = 0,
            count: u32 = 0,
            window_start: u64 = 0,
        };
        // comptime static —— 进程生命周期内持久。
        var buckets: [max_buckets]Bucket = std.mem.zeroes([max_buckets]Bucket);
        var bucket_len: usize = 0;
        // 自旋锁（单核场景退化为 nop；mox 使用单线程事件循环，
        // handler 在主线程运行，这里无竞争，仅做形式保护）。
        var lock = std.atomic.Value(bool).init(false);

        fn acquire() void {
            while (lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {}
        }
        fn release() void {
            lock.store(false, .release);
        }

        fn nowMs() u64 {
            const mox_io = @import("mox_io");
            return mox_io.platform.tickCount();
        }

        fn findOrCreate(ip: []const u8) *Bucket {
            for (buckets[0..bucket_len]) |*b| {
                if (std.mem.eql(u8, b.ip[0..b.ip_len], ip)) return b;
            }
            // 未找到：若有空位新建；否则复用最旧（count 最小）的桶。
            if (bucket_len < max_buckets) {
                const b = &buckets[bucket_len];
                bucket_len += 1;
                b.ip_len = @min(ip.len, b.ip.len);
                @memcpy(b.ip[0..b.ip_len], ip[0..b.ip_len]);
                b.count = 0;
                b.window_start = nowMs();
                return b;
            }
            var oldest: *Bucket = &buckets[0];
            for (buckets[1..bucket_len]) |*b| {
                if (b.window_start < oldest.window_start) oldest = b;
            }
            oldest.ip_len = @min(ip.len, oldest.ip.len);
            @memcpy(oldest.ip[0..oldest.ip_len], ip[0..oldest.ip_len]);
            oldest.count = 0;
            oldest.window_start = nowMs();
            return oldest;
        }

        fn wrap(comptime next: Handler) Handler {
            return struct {
                fn handle(ctx: *Context) anyerror!Response {
                    // 从 X-Forwarded-For 或 X-Real-IP 读来源 IP；
                    // 生产环境应只信任 nginx 转发的头，这里做简化实现。
                    const ip = ctx.request.header("x-real-ip") orelse
                        ctx.request.header("x-forwarded-for") orelse "unknown";

                    acquire();
                    defer release();

                    const now = nowMs();
                    const b = findOrCreate(ip);
                    // 窗口滚动
                    if (now - b.window_start >= opts.window_ms) {
                        b.count = 0;
                        b.window_start = now;
                    }
                    b.count += 1;
                    if (b.count > opts.max_requests) {
                        return Response{ .status = .too_many_requests, .body = opts.message };
                    }
                    return next(ctx);
                }
            }.handle;
        }
    }.wrap;
}

// ---- 结构化 JSON 日志 -------------------------------------------------------

/// JSON 日志中间件。把每个请求的方法、路径、状态、耗时写到 stderr（JSON Lines）。
///
/// 输出示例：{"ts":1731345670123,"method":"GET","path":"/api","status":200,"ms":3}
pub fn jsonLog(comptime next: Handler) Handler {
    return struct {
        fn nowMs() u64 {
            const mox_io = @import("mox_io");
            return mox_io.platform.tickCount();
        }
        fn handle(ctx: *Context) anyerror!Response {
            const t0 = nowMs();
            const response = try next(ctx);
            const elapsed = nowMs() - t0;
            // 直接写 stderr，不经过 std.log（避免 std.log 格式前缀影响解析）。
            std.debug.print(
                "{{\"ts\":{d},\"method\":\"{s}\",\"path\":\"{s}\",\"status\":{d},\"ms\":{d}}}\n",
                .{
                    t0,
                    @tagName(ctx.request.method),
                    ctx.request.path,
                    @backingInt(response.status),
                    elapsed,
                },
            );
            return response;
        }
    }.handle;
}

// ---- 新增测试 ---------------------------------------------------------------

test "mimeFor 识别常见扩展名" {
    try std.testing.expect(std.mem.startsWith(u8, mimeFor("app.js"), "text/javascript"));
    try std.testing.expect(std.mem.startsWith(u8, mimeFor("index.html"), "text/html"));
    try std.testing.expect(std.mem.startsWith(u8, mimeFor("style.css"), "text/css"));
    try std.testing.expectEqualStrings("application/octet-stream", mimeFor("file.bin"));
    try std.testing.expectEqualStrings("image/svg+xml", mimeFor("logo.svg"));
    try std.testing.expectEqualStrings("application/wasm", mimeFor("module.wasm"));
}

test "staticDir 拒绝路径穿越" {
    const http = @import("http.zig");
    const req: http.Request = .{
        .method = .GET,
        .target = "/static/../etc/passwd",
        .path = "/static/../etc/passwd",
        .version = "HTTP/1.1",
        .head = "",
        .body = "",
        .keep_alive = false,
    };
    var params: @import("types.zig").Params = .{};
    _ = params.push("path", "/../etc/passwd");
    var ctx: Context = .{
        .gpa = std.testing.allocator,
        .request = &req,
        .params = &params,
    };
    const h = staticDir("/public");
    const resp = try h(&ctx);
    try std.testing.expectEqual(std.http.Status.bad_request, resp.status);
}

test "rateLimit 超出限额后返回 429" {
    const http = @import("http.zig");
    const req: http.Request = .{
        .method = .GET,
        .target = "/",
        .path = "/",
        .version = "HTTP/1.1",
        .head = "x-real-ip: 1.2.3.4",
        .body = "",
        .keep_alive = true,
    };
    var params: @import("types.zig").Params = .{};
    var ctx: Context = .{
        .gpa = std.testing.allocator,
        .request = &req,
        .params = &params,
    };
    // 窗口 60s，限 1 次——用独立实例隔离 comptime 桶
    const limiter = rateLimit(.{ .window_ms = 60_000, .max_requests = 1 });
    const app = limiter(ok);
    _ = try app(&ctx); // 第 1 次：ok
    const resp = try app(&ctx); // 第 2 次：超限
    try std.testing.expectEqual(std.http.Status.too_many_requests, resp.status);
}


// ============================================================================
// Phase 6 中间件
// ============================================================================

/// 单线程事件循环下，响应头在 `respond()` 里被同步拷进每连接缓冲，
/// 故中间件复用一块静态暂存区即可，无需热路径堆分配（也无需 server 参与释放）。
/// 上限 16：上游已有头数达到上限时本中间件不再追加，避免静默截断或堆分配。
const header_scratch_cap = 16;

/// requestId 中间件：为每条请求生成递增 ID，写入响应头 `X-Request-Id`。
/// 单线程事件循环保证静态暂存区无竞争；若将来引入多 worker，需改回堆分配并
/// 在 server 侧增加 `headers_owned` 释放路径。
pub fn requestId(comptime next: Handler) Handler {
    return struct {
        const State = struct {
            var counter: std.atomic.Value(u64) = .init(0);
            var id_buf: [32]u8 = undefined;
            var headers: [header_scratch_cap]Header = undefined;
        };
        fn handle(ctx: *Context) anyerror!Response {
            var resp = try next(ctx);
            if (resp.headers.len >= State.headers.len) return resp;
            const id = State.counter.fetchAdd(1, .monotonic);
            const id_str = std.fmt.bufPrint(&State.id_buf, "{d}", .{id}) catch return resp;
            @memcpy(State.headers[0..resp.headers.len], resp.headers);
            State.headers[resp.headers.len] = .{ .name = "x-request-id", .value = id_str };
            resp.headers = State.headers[0 .. resp.headers.len + 1];
            return resp;
        }
    }.handle;
}

/// bodyLimit 中间件：当请求体超过 `max_bytes` 时直接以 413 短路，不调用 next。
/// 补充 Config.max_body_size 的全局限制，可在单条路由粒度覆盖。
pub fn bodyLimit(comptime max_bytes: usize) Middleware {
    return struct {
        fn wrap(comptime next: Handler) Handler {
            return struct {
                fn handle(ctx: *Context) anyerror!Response {
                    if (ctx.body.len > max_bytes) {
                        return .{
                            .status = .payload_too_large,
                            .body = "request body too large\n",
                        };
                    }
                    return next(ctx);
                }
            }.handle;
        }
    }.wrap;
}

/// cache 中间件：给成功响应（2xx）加 `Cache-Control: public, max-age=N`。
/// 非 2xx 响应不加缓存头，以免缓存错误页。
/// 与 requestId 一样复用静态暂存区（单线程事件循环，零热路径分配）。
pub fn cache(comptime max_age_seconds: u32) Middleware {
    const S = struct {
        const cc_len = std.fmt.count("public, max-age={d}", .{max_age_seconds});
        const cc_buf: [cc_len]u8 = blk: {
            var buf: [cc_len]u8 = undefined;
            _ = std.fmt.bufPrint(&buf, "public, max-age={d}", .{max_age_seconds}) catch unreachable;
            break :blk buf;
        };
        var headers: [header_scratch_cap]Header = undefined;
    };
    return struct {
        fn wrap(comptime next: Handler) Handler {
            return struct {
                fn handle(ctx: *Context) anyerror!Response {
                    var resp = try next(ctx);
                    const code = @intFromEnum(resp.status);
                    if (code >= 200 and code < 300 and resp.headers.len < S.headers.len) {
                        @memcpy(S.headers[0..resp.headers.len], resp.headers);
                        S.headers[resp.headers.len] = .{
                            .name = "cache-control",
                            .value = &S.cc_buf,
                        };
                        resp.headers = S.headers[0 .. resp.headers.len + 1];
                    }
                    return resp;
                }
            }.handle;
        }
    }.wrap;
}

// ---- Phase 6 测试 ----------------------------------------------------------

test "requestId 中间件给响应加 x-request-id 头" {
    const http = @import("http.zig");
    const req: http.Request = .{
        .method = .GET, .target = "/", .path = "/",
        .version = "HTTP/1.1", .head = "", .body = "", .keep_alive = true,
    };
    var params: @import("types.zig").Params = .{};
    var ctx: Context = .{
        .gpa = std.testing.allocator,
        .request = &req,
        .params = &params,
    };
    const h = requestId(ok);
    const resp = try h(&ctx);
    var found = false;
    for (resp.headers) |hdr| {
        if (std.mem.eql(u8, hdr.name, "x-request-id")) { found = true; break; }
    }
    try std.testing.expect(found);
}

test "bodyLimit 超限返回 413" {
    const http = @import("http.zig");
    var big_body: [1025]u8 = undefined;
    @memset(&big_body, '0');
    const req: http.Request = .{
        .method = .POST, .target = "/", .path = "/",
        .version = "HTTP/1.1", .head = "", .body = &big_body, .keep_alive = true,
    };
    var params: @import("types.zig").Params = .{};
    var ctx: Context = .{
        .gpa = std.testing.allocator,
        .request = &req,
        .params = &params,
        .body = req.body,
    };
    const app = bodyLimit(1024)(ok);
    const resp = try app(&ctx);
    try std.testing.expectEqual(std.http.Status.payload_too_large, resp.status);
}

test "cache 中间件给 2xx 加 Cache-Control" {
    const http = @import("http.zig");
    const req: http.Request = .{
        .method = .GET, .target = "/", .path = "/",
        .version = "HTTP/1.1", .head = "", .body = "", .keep_alive = true,
    };
    var params: @import("types.zig").Params = .{};
    var ctx: Context = .{
        .gpa = std.testing.allocator,
        .request = &req,
        .params = &params,
    };
    const h = cache(3600)(ok);
    const resp = try h(&ctx);
    var found = false;
    for (resp.headers) |hdr| {
        if (std.mem.eql(u8, hdr.name, "cache-control") and
            std.mem.indexOf(u8, hdr.value, "max-age=3600") != null)
        { found = true; break; }
    }
    try std.testing.expect(found);
}
