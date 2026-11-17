//! Compile-time middleware composition and built-in request policies.

const std = @import("std");
const types = @import("types.zig");

pub const Context = types.Context;
pub const Response = types.Response;
pub const Handler = types.Handler;
pub const Header = types.Header;

/// Middleware receives the next handler at compile time.
pub const Middleware = fn (comptime next: Handler) Handler;

/// Wrap terminal at compile time; the first tuple entry runs outermost.
pub fn compose(comptime middlewares: anytype, comptime terminal: Handler) Handler {
    comptime var handler: Handler = terminal;
    comptime var i: usize = middlewares.len;
    inline while (i > 0) : (i -= 1) {
        handler = @call(.compile_time, middlewares[i - 1], .{handler});
    }
    return handler;
}

/// Log the method, target, and response status.
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

/// Return 401 unless the named header matches exactly.
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

/// Cross-origin request policy.
pub const CorsOptions = struct {
    /// Allowed origins; a single `"*"` permits any origin.
    allow_origins: []const []const u8 = &.{"*"},
    /// Comma-separated allowed methods.
    allow_methods: []const u8 = "GET, HEAD, POST, PUT, DELETE, PATCH, OPTIONS",
    /// Comma-separated allowed request headers.
    allow_headers: []const u8 = "Content-Type, Authorization, Accept",
    /// Allow cookies and authorization credentials.
    allow_credentials: bool = false,
    /// Preflight cache duration in seconds.
    max_age_seconds: u32 = 86400,
};

/// Answer OPTIONS requests with 204; append CORS headers to other responses.
pub fn cors(comptime opts: CorsOptions) Middleware {
    return struct {
        fn wrap(comptime next: Handler) Handler {
            return struct {
                fn handle(ctx: *Context) anyerror!Response {
                    const wildcard = opts.allow_origins.len == 1 and std.mem.eql(u8, opts.allow_origins[0], "*");
                    const origin_value: []const u8 = blk: {
                        if (wildcard and !opts.allow_credentials) break :blk "*";
                        const req_origin = ctx.request.header("origin") orelse "";
                        if (wildcard) break :blk req_origin;
                        for (opts.allow_origins) |allowed| {
                            if (std.mem.eql(u8, allowed, req_origin)) break :blk req_origin;
                        }
                        break :blk "";
                    };

                    const preflight = ctx.request.method == .OPTIONS;
                    var resp: Response = if (preflight) .{ .status = .no_content } else try next(ctx);
                    if (origin_value.len == 0) return resp;
                    var headers: [6]Header = undefined;
                    var count: usize = 0;
                    headers[count] = .{ .name = "access-control-allow-origin", .value = origin_value };
                    count += 1;
                    if (!wildcard or opts.allow_credentials) {
                        headers[count] = .{ .name = "vary", .value = "Origin" };
                        count += 1;
                    }
                    if (opts.allow_credentials) {
                        headers[count] = .{ .name = "access-control-allow-credentials", .value = "true" };
                        count += 1;
                    }
                    if (preflight) {
                        headers[count] = .{ .name = "access-control-allow-methods", .value = opts.allow_methods };
                        headers[count + 1] = .{ .name = "access-control-allow-headers", .value = opts.allow_headers };
                        headers[count + 2] = .{ .name = "access-control-max-age", .value = std.fmt.comptimePrint("{d}", .{opts.max_age_seconds}) };
                        count += 3;
                    }
                    resp.headers = try appendHeaders(ctx.gpa, resp.headers, headers[0..count]);
                    return resp;
                }
            }.handle;
        }
    }.wrap;
}

/// Header arrays use the request allocator and survive asynchronous transmission.
fn appendHeaders(gpa: std.mem.Allocator, existing: []const Header, extra: []const Header) ![]const Header {
    const headers = try gpa.alloc(Header, existing.len + extra.len);
    @memcpy(headers[0..existing.len], existing);
    @memcpy(headers[existing.len..], extra);
    return headers;
}

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

test "cors OPTIONS returns 204 with CORS headers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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
        .gpa = arena.allocator(),
        .request = &req,
        .params = &params,
    };
    const app = compose(.{cors(.{})}, ok);
    const resp = try app(&ctx);
    try std.testing.expectEqual(std.http.Status.no_content, resp.status);
    var found = false;
    for (resp.headers) |h| {
        if (std.mem.eql(u8, h.name, "access-control-allow-origin")) found = true;
    }
    try std.testing.expect(found);
}

test "cors GET forwards the request and adds CORS headers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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
        .gpa = arena.allocator(),
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

/// Infer Content-Type from a filename extension.
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

/// Serve the `*path` route parameter relative to a compile-time directory.
/// The resulting path is allocated from the request allocator.
pub fn staticDir(comptime dir: []const u8) Handler {
    return struct {
        fn handle(ctx: *Context) anyerror!Response {
            const sub = ctx.param("path") orelse
                return Response{ .status = .not_found, .body = "not found\n" };
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

/// In-memory fixed-window rate limit.
pub const RateLimitOptions = struct {
    /// Enable only behind a proxy that overwrites incoming forwarding headers.
    /// Without this option, requests share a single bucket.
    trust_proxy_headers: bool = false,
    /// Window duration in milliseconds.
    window_ms: u64 = 60_000,
    /// Maximum requests per source within one window.
    max_requests: u32 = 100,
    /// Response body when the limit is exceeded.
    message: []const u8 = "rate limit exceeded\n",
};

/// Identical compile-time options share process-local counters. By default all
/// requests share one bucket. Forwarding headers require a trusted proxy;
/// separate processes require an external counter for a global limit.
pub fn rateLimit(comptime opts: RateLimitOptions) Middleware {
    return rateLimitWithClock(opts, monotonicMs);
}

fn monotonicMs() u64 {
    return @import("mox_io").os.now() / 1_000_000;
}

fn rateLimitWithClock(comptime opts: RateLimitOptions, comptime clock: fn () u64) Middleware {
    return struct {
        // Bound memory by replacing the bucket with the oldest window when full.
        const max_buckets = 1024;
        const Bucket = struct {
            ip: [64]u8 = undefined,
            ip_len: usize = 0,
            count: u32 = 0,
            window_start: u64 = 0,
        };
        // Shared by this compile-time instantiation for the process lifetime.
        var buckets: [max_buckets]Bucket = std.mem.zeroes([max_buckets]Bucket);
        var bucket_len: usize = 0;
        // Serialize shared counters when multiple server loops use this middleware.
        var lock = std.atomic.Value(bool).init(false);

        fn acquire() void {
            while (lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {}
        }
        fn release() void {
            lock.store(false, .release);
        }

        fn findOrCreate(ip: []const u8, now: u64) *Bucket {
            for (buckets[0..bucket_len]) |*b| {
                if (std.mem.eql(u8, b.ip[0..b.ip_len], ip)) return b;
            }
            // Create a bucket if capacity remains; otherwise replace the oldest window.
            if (bucket_len < max_buckets) {
                const b = &buckets[bucket_len];
                bucket_len += 1;
                b.ip_len = @min(ip.len, b.ip.len);
                @memcpy(b.ip[0..b.ip_len], ip[0..b.ip_len]);
                b.count = 0;
                b.window_start = now;
                return b;
            }
            var oldest: *Bucket = &buckets[0];
            for (buckets[1..bucket_len]) |*b| {
                if (b.window_start < oldest.window_start) oldest = b;
            }
            oldest.ip_len = @min(ip.len, oldest.ip.len);
            @memcpy(oldest.ip[0..oldest.ip_len], ip[0..oldest.ip_len]);
            oldest.count = 0;
            oldest.window_start = now;
            return oldest;
        }

        fn wrap(comptime next: Handler) Handler {
            return struct {
                fn handle(ctx: *Context) anyerror!Response {
                    // Only inspect forwarding headers when the configured proxy overwrites them.
                    const ip = if (opts.trust_proxy_headers)
                        ctx.request.header("x-real-ip") orelse ctx.request.header("x-forwarded-for") orelse "unknown"
                    else
                        "global";

                    acquire();

                    // Initialize and check a bucket with the same clock sample.
                    const now = clock();
                    const b = findOrCreate(ip, now);
                    if (now - b.window_start >= opts.window_ms) {
                        b.count = 0;
                        b.window_start = now;
                    }
                    if (b.count >= opts.max_requests) {
                        release();
                        const retry = struct {
                            const headers = [_]Header{.{ .name = "retry-after", .value = std.fmt.comptimePrint("{d}", .{@max(@as(u64, 1), opts.window_ms / 1000 + @intFromBool(opts.window_ms % 1000 != 0))}) }};
                        };
                        return Response{ .status = .too_many_requests, .body = opts.message, .headers = &retry.headers };
                    }
                    b.count += 1;
                    release();
                    return next(ctx);
                }
            }.handle;
        }
    }.wrap;
}

/// Write method, path, status, and elapsed time to stderr as JSON Lines.
/// ts is monotonic milliseconds, not a wall-clock timestamp.
pub fn jsonLog(comptime next: Handler) Handler {
    return struct {
        fn nowMs() u64 {
            return @import("mox_io").os.now() / 1_000_000;
        }
        fn handle(ctx: *Context) anyerror!Response {
            const t0 = nowMs();
            const response = try next(ctx);
            const elapsed = nowMs() - t0;
            var buffer: [4096]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buffer);
            std.json.Stringify.value(.{
                .ts = t0,
                .method = @tagName(ctx.request.method),
                .path = ctx.request.path[0..@min(ctx.request.path.len, 256)],
                .path_truncated = ctx.request.path.len > 256,
                .status = @backingInt(response.status),
                .ms = elapsed,
            }, .{}, &writer) catch return response;
            std.debug.print("{s}\n", .{writer.buffered()});
            return response;
        }
    }.handle;
}

test "mimeFor recognizes common extensions" {
    try std.testing.expect(std.mem.startsWith(u8, mimeFor("app.js"), "text/javascript"));
    try std.testing.expect(std.mem.startsWith(u8, mimeFor("index.html"), "text/html"));
    try std.testing.expect(std.mem.startsWith(u8, mimeFor("style.css"), "text/css"));
    try std.testing.expectEqualStrings("application/octet-stream", mimeFor("file.bin"));
    try std.testing.expectEqualStrings("image/svg+xml", mimeFor("logo.svg"));
    try std.testing.expectEqualStrings("application/wasm", mimeFor("module.wasm"));
}

test "staticDir rejects path traversal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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
        .gpa = arena.allocator(),
        .request = &req,
        .params = &params,
    };
    const h = staticDir("/public");
    const resp = try h(&ctx);
    try std.testing.expectEqual(std.http.Status.bad_request, resp.status);
}

test "rateLimit returns 429 after the limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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
        .gpa = arena.allocator(),
        .request = &req,
        .params = &params,
    };
    // Use distinct options to isolate this compile-time counter.
    const limiter = rateLimit(.{ .window_ms = 60_000, .max_requests = 1 });
    const app = limiter(ok);
    _ = try app(&ctx); // First request succeeds.
    const resp = try app(&ctx); // Second request exceeds the limit.
    try std.testing.expectEqual(std.http.Status.too_many_requests, resp.status);
    try std.testing.expectEqualStrings("retry-after", resp.headers[0].name);
    try std.testing.expectEqualStrings("60", resp.headers[0].value);
}

test "rateLimit releases the bucket lock before calling another limiter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req: @import("http.zig").Request = .{
        .method = .GET,
        .target = "/",
        .path = "/",
        .version = "HTTP/1.1",
        .head = "",
        .body = "",
        .keep_alive = true,
    };
    var params: types.Params = .{};
    var ctx: Context = .{ .gpa = arena.allocator(), .request = &req, .params = &params };
    const limiter = rateLimit(.{ .window_ms = 60_000, .max_requests = 7 });
    const app = limiter(limiter(ok));
    const response = try app(&ctx);
    try std.testing.expectEqual(std.http.Status.ok, response.status);
}

test "rateLimit starts and replaces buckets when the clock advances each read" {
    const Clock = struct {
        var time: u64 = 1000;
        fn read() u64 {
            const value = time;
            time += 1;
            return value;
        }
    };
    Clock.time = 1000;
    var req: @import("http.zig").Request = .{
        .method = .GET,
        .target = "/",
        .path = "/",
        .version = "HTTP/1.1",
        .head = "",
        .body = "",
        .keep_alive = true,
    };
    var params: types.Params = .{};
    var ctx: Context = .{ .gpa = std.testing.allocator, .request = &req, .params = &params };
    const limiter = rateLimitWithClock(.{ .trust_proxy_headers = true, .window_ms = 60_000, .max_requests = 1 }, Clock.read);
    const app = limiter(ok);
    var head: [64]u8 = undefined;
    // The final identity replaces the oldest of the 1024 bounded buckets.
    for (0..1025) |index| {
        req.head = try std.fmt.bufPrint(&head, "GET / HTTP/1.1\r\nx-real-ip: client-{d}", .{index});
        try std.testing.expectEqual(std.http.Status.ok, (try app(&ctx)).status);
        try std.testing.expectEqual(std.http.Status.too_many_requests, (try app(&ctx)).status);
    }
}

test "rateLimit resets at the exact window boundary" {
    const Clock = struct {
        var time: u64 = 1000;
        fn read() u64 {
            return time;
        }
    };
    Clock.time = 1000;
    const req: @import("http.zig").Request = .{
        .method = .GET,
        .target = "/",
        .path = "/",
        .version = "HTTP/1.1",
        .head = "",
        .body = "",
        .keep_alive = true,
    };
    var params: types.Params = .{};
    var ctx: Context = .{ .gpa = std.testing.allocator, .request = &req, .params = &params };
    const limiter = rateLimitWithClock(.{ .window_ms = 10, .max_requests = 1 }, Clock.read);
    const app = limiter(ok);
    try std.testing.expectEqual(std.http.Status.ok, (try app(&ctx)).status);
    Clock.time = 1009;
    try std.testing.expectEqual(std.http.Status.too_many_requests, (try app(&ctx)).status);
    Clock.time = 1010;
    try std.testing.expectEqual(std.http.Status.ok, (try app(&ctx)).status);
    try std.testing.expectEqual(std.http.Status.too_many_requests, (try app(&ctx)).status);
}

/// Append an incrementing X-Request-Id using the request allocator.
pub fn requestId(comptime next: Handler) Handler {
    return struct {
        const State = struct {
            var counter: std.atomic.Value(u64) = .init(0);
        };
        fn handle(ctx: *Context) anyerror!Response {
            var resp = try next(ctx);
            const id = State.counter.fetchAdd(1, .monotonic);
            const id_str = try std.fmt.allocPrint(ctx.gpa, "{d}", .{id});
            errdefer ctx.gpa.free(id_str);
            resp.headers = try appendHeaders(ctx.gpa, resp.headers, &.{.{ .name = "x-request-id", .value = id_str }});
            return resp;
        }
    }.handle;
}

/// Reject buffered bodies above a route-specific limit with 413.
/// Config.max_body_size remains the limit enforced before buffering.
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

/// Append Cache-Control to successful responses using the request allocator.
pub fn cache(comptime max_age_seconds: u32) Middleware {
    const S = struct {
        const cc_len = std.fmt.count("public, max-age={d}", .{max_age_seconds});
        const cc_buf: [cc_len]u8 = blk: {
            var buf: [cc_len]u8 = undefined;
            _ = std.fmt.bufPrint(&buf, "public, max-age={d}", .{max_age_seconds}) catch unreachable;
            break :blk buf;
        };
    };
    return struct {
        fn wrap(comptime next: Handler) Handler {
            return struct {
                fn handle(ctx: *Context) anyerror!Response {
                    var resp = try next(ctx);
                    const code = @backingInt(resp.status);
                    if (code >= 200 and code < 300) {
                        resp.headers = try appendHeaders(ctx.gpa, resp.headers, &.{.{
                            .name = "cache-control",
                            .value = &S.cc_buf,
                        }});
                    }
                    return resp;
                }
            }.handle;
        }
    }.wrap;
}

test "requestId appends x-request-id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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
        .gpa = arena.allocator(),
        .request = &req,
        .params = &params,
    };
    const h = requestId(ok);
    const resp = try h(&ctx);
    var found = false;
    for (resp.headers) |hdr| {
        if (std.mem.eql(u8, hdr.name, "x-request-id")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "bodyLimit returns 413 above its limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const http = @import("http.zig");
    var big_body: [1025]u8 = undefined;
    @memset(&big_body, '0');
    const req: http.Request = .{
        .method = .POST,
        .target = "/",
        .path = "/",
        .version = "HTTP/1.1",
        .head = "",
        .body = &big_body,
        .keep_alive = true,
    };
    var params: @import("types.zig").Params = .{};
    var ctx: Context = .{
        .gpa = arena.allocator(),
        .request = &req,
        .params = &params,
        .body = req.body,
    };
    const app = bodyLimit(1024)(ok);
    const resp = try app(&ctx);
    try std.testing.expectEqual(std.http.Status.payload_too_large, resp.status);
}

test "cache appends Cache-Control to successful responses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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
        .gpa = arena.allocator(),
        .request = &req,
        .params = &params,
    };
    const h = cache(3600)(ok);
    const resp = try h(&ctx);
    var found = false;
    for (resp.headers) |hdr| {
        if (std.mem.eql(u8, hdr.name, "cache-control") and
            std.mem.indexOf(u8, hdr.value, "max-age=3600") != null)
        {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "cors reflects allowed origins and preserves handler headers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const terminal = struct {
        fn handle(_: *Context) anyerror!Response {
            return .{ .body = "ok", .headers = &.{.{ .name = "x-handler", .value = "retained" }} };
        }
    }.handle;
    const app = cors(.{ .allow_origins = &.{"https://example.com"} })(terminal);
    const req: @import("http.zig").Request = .{
        .method = .GET,
        .target = "/",
        .path = "/",
        .version = "HTTP/1.1",
        .head = "GET / HTTP/1.1\r\nOrigin: https://example.com\r\n\r\n",
        .body = "",
        .keep_alive = true,
    };
    var params: types.Params = .{};
    var ctx: Context = .{ .gpa = arena.allocator(), .request = &req, .params = &params };
    const response = try app(&ctx);
    try std.testing.expectEqualStrings("x-handler", response.headers[0].name);
    try std.testing.expectEqualStrings("https://example.com", response.headers[1].value);
    try std.testing.expectEqualStrings("vary", response.headers[2].name);
}

test "credentialed wildcard cors reflects the request origin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req: @import("http.zig").Request = .{
        .method = .OPTIONS,
        .target = "/",
        .path = "/",
        .version = "HTTP/1.1",
        .head = "OPTIONS / HTTP/1.1\r\nOrigin: https://example.com\r\n\r\n",
        .body = "",
        .keep_alive = true,
    };
    var params: types.Params = .{};
    var ctx: Context = .{ .gpa = arena.allocator(), .request = &req, .params = &params };
    const response = try cors(.{ .allow_credentials = true })(ok)(&ctx);
    try std.testing.expectEqualStrings("https://example.com", response.headers[0].value);
    try std.testing.expectEqualStrings("access-control-allow-credentials", response.headers[2].name);
    try std.testing.expectEqualStrings("true", response.headers[2].value);
}

test "middleware response headers survive the next invocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req: @import("http.zig").Request = .{
        .method = .GET,
        .target = "/",
        .path = "/",
        .version = "HTTP/1.1",
        .head = "",
        .body = "",
        .keep_alive = true,
    };
    var params: types.Params = .{};
    var ctx: Context = .{ .gpa = arena.allocator(), .request = &req, .params = &params };
    const app = requestId(cache(12345)(ok));
    const first = try app(&ctx);
    const first_id = try arena.allocator().dupe(u8, first.headers[1].value);
    const second = try app(&ctx);
    try std.testing.expectEqualStrings(first_id, first.headers[1].value);
    try std.testing.expect(!std.mem.eql(u8, first.headers[1].value, second.headers[1].value));
    try std.testing.expectEqualStrings("cache-control", first.headers[0].name);
}
