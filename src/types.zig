//! Request, response, handler, and server configuration contracts.

const std = @import("std");
const http = @import("http.zig");
const mox_io = @import("mox_io");

/// Expose http.Header as mox.Header without exposing internal module boundaries.
pub const Header = http.Header;

/// Decode a URL-encoded slice using gpa, normally the request arena ctx.gpa.
/// %XX accepts either hexadecimal case; + becomes a space for form encoding.
/// Malformed or truncated escapes return InvalidEncoding instead of silently
/// turning malformed input into a different valid value. Allocated results have
/// the exact decoded length, so they can be freed with the same allocator.
pub fn urlDecode(gpa: std.mem.Allocator, s: []const u8) ![]const u8 {
    // Return the original slice when no decoding is needed.
    if (std.mem.indexOfScalar(u8, s, '%') == null and std.mem.indexOfScalar(u8, s, '+') == null) {
        return s;
    }
    // First validate and calculate the exact result length. Returning a shortened
    // slice of an input-sized allocation would violate the allocator's free contract.
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
    // Allocate the exact length and decode on the second pass.
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
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch unreachable; // Validated on the first pass.
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

/// Path parameters captured for one request. Values borrow slices of the request target.
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

    /// Store a parameter captured during route matching.
    pub fn push(self: *Params, name: []const u8, value: []const u8) bool {
        if (self.len == max) return false;
        self.items[self.len] = .{ .name = name, .value = value };
        self.len += 1;
        return true;
    }
};

/// Bounded streaming output window. Each callback can write at most capacity() bytes; it never grows automatically.
pub const StreamWriter = struct {
    buffer: []u8,
    len: usize = 0,
    finished: bool = false,

    pub fn capacity(self: *const StreamWriter) usize {
        return self.buffer.len - self.len;
    }

    pub fn writeAll(self: *StreamWriter, bytes: []const u8) error{ NoSpaceLeft, StreamFinished }!void {
        if (self.finished) return error.StreamFinished;
        if (bytes.len > self.capacity()) return error.NoSpaceLeft;
        @memcpy(self.buffer[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    pub fn finish(self: *StreamWriter) void {
        self.finished = true;
    }
};

/// Demand-driven response producer: next runs only after the previous chunk is sent.
/// Callbacks run on the event loop and must return promptly without retaining writer.
/// Each call must produce data or finish. Failure closes the connection without a success terminator.
/// state may use ctx.gpa and remains valid until close returns; close runs exactly once on the loop thread.
pub const Stream = struct {
    pub const End = enum { complete, failed, cancelled };
    state: *anyopaque,
    next: *const fn (*anyopaque, *StreamWriter) anyerror!void,
    close: ?*const fn (*anyopaque, End) void = null,
};

/// Handler result. body is borrowed and must remain valid until the response has been sent.
pub const Response = struct {
    status: std.http.Status = .ok,
    body: []const u8 = "",
    content_type: []const u8 = "text/plain; charset=utf-8",
    /// Additional borrowed response headers, valid throughout response transmission.
    headers: []const Header = &.{},
    /// HTTP/1.1 chunked output, taking precedence over file_path and body. HEAD does not call next.
    stream: ?Stream = null,
    /// Read the file in the Work pool and send its contents instead of body.
    /// The path must remain valid until the runtime submits the file open after the
    /// handler returns; allocate dynamic paths with ctx.gpa, never on the stack.
    file_path: []const u8 = "",
    /// WebSocket handler interpreted by the server runtime.
    ws_handler: ?WsHandler = null,
    /// Complete text/binary messages run on a worker and return one text frame.
    blocking_ws: ?WsWorkHandler = null,
    /// Application state kept valid until the upgraded connection retires.
    ws_state: ?*anyopaque = null,
    /// SSE handler interpreted by the server runtime.
    sse_handler: ?SseHandler = null,
    /// Return already serialized JSON bytes with content_type set to application/json.
    pub fn withJson(json_body: []const u8) Response {
        return .{
            .body = json_body,
            .content_type = "application/json; charset=utf-8",
        };
    }

    /// Redirect to a compile-time URL. The static header array outlives transmission.
    /// For a runtime URL, allocate both header storage and its value with ctx.gpa.
    /// Never return headers backed by a handler's stack array: they would dangle after return.
    pub fn redirect(comptime url: []const u8, status: std.http.Status) Response {
        // Keep the header array in static storage using an anonymous struct.
        const S = struct {
            const h = [_]Header{.{ .name = "location", .value = url }};
        };
        return .{ .status = status, .headers = &S.h };
    }

    /// Request a WebSocket upgrade. After the handshake, invoke ws_handler until the connection closes.
    pub fn upgrade(handler: WsHandler) Response {
        return .{ .ws_handler = handler };
    }

    /// Run complete data messages serially on workers; control frames stay on the loop.
    /// Returned text may reference message.data, state, or the supplied arena.
    pub fn upgradeBlocking(state: ?*anyopaque, handler: WsWorkHandler) Response {
        return .{ .ws_handler = ignoreWs, .blocking_ws = handler, .ws_state = state };
    }

    fn ignoreWs(_: WsConn, _: WsMessage) void {}

    /// Start an SSE stream. If the handler returns true, send completions or
    /// writer.setTick(ms) schedule subsequent invocations after the response headers.
    pub fn sse(handler: SseHandler) Response {
        return .{ .sse_handler = handler };
    }
};

/// WebSocket opcodes.
pub const WsOpcode = enum(u8) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xa,
    _,
};

/// Reassembled message or control frame. data is valid only during the current callback.
pub const WsMessage = struct {
    opcode: WsOpcode,
    data: []u8,
};

/// WebSocket connection handle, kept valid by the runtime for the duration of ws_handler.
pub const WsConn = struct {
    /// Opaque runtime Connection pointer accessed through the vtable.
    ptr: *anyopaque,
    vtable: *const WsVtable,

    /// Send a UTF-8 text frame.
    pub fn sendText(self: WsConn, data: []const u8) WsSendError!void {
        return self.vtable.send(self.ptr, .text, data);
    }
    /// Send a binary frame.
    pub fn sendBinary(self: WsConn, data: []const u8) WsSendError!void {
        return self.vtable.send(self.ptr, .binary, data);
    }
    /// Send a close frame, then wait for the peer acknowledgement or close deadline.
    pub fn close(self: WsConn) void {
        self.vtable.close(self.ptr);
    }
};

pub const WsSendError = error{ Closed, MessageTooLarge, QueueFull, OutOfMemory, InvalidUtf8 };

pub const WsVtable = struct {
    send: *const fn (ptr: *anyopaque, opcode: WsOpcode, data: []const u8) WsSendError!void,
    close: *const fn (ptr: *anyopaque) void,
};

/// Event-loop callback for complete text/binary messages, ping/pong, and valid peer close frames.
/// The handle must not escape the callback or cross threads. Ping is answered automatically.
pub const WsHandler = *const fn (conn: WsConn, msg: WsMessage) void;
/// Runs off the loop. The message and arena remain valid until its terminal
/// completion; never retain either or call WsConn from this callback. Errors close
/// the WebSocket with 1011. Other messages on this connection wait for completion.
pub const WsWorkHandler = *const fn (state: ?*anyopaque, arena: std.mem.Allocator, msg: WsMessage) anyerror![]const u8;

/// Runtime-owned writer used by an SSE handler to publish events.
pub const SseWriter = struct {
    ptr: *anyopaque,
    vtable: *const SseVtable,

    /// Send an SSE event. An empty event name uses the default message event.
    pub fn send(self: SseWriter, event: []const u8, data: []const u8) void {
        self.vtable.send(self.ptr, event, data);
    }
    /// Set the automatic pump interval in milliseconds. When the handler returns true
    /// without sending data, this timer schedules another invocation. Defaults to 1000ms.
    /// Zero disables timer-driven pumping; send completions can still trigger the next call.
    pub fn setTick(self: SseWriter, interval_ms: u32) void {
        self.vtable.set_tick(self.ptr, interval_ms);
    }
    /// Close the SSE stream.
    pub fn close(self: SseWriter) void {
        self.vtable.close(self.ptr);
    }
};

pub const SseVtable = struct {
    send: *const fn (ptr: *anyopaque, event: []const u8, data: []const u8) void,
    set_tick: *const fn (ptr: *anyopaque, interval_ms: u32) void,
    close: *const fn (ptr: *anyopaque) void,
};

/// Return true to keep the SSE stream open, false to finish.
/// If writer.send() was called, its completion pumps the handler again.
/// Otherwise the timer uses writer.setTick(ms), defaulting to 1s; setTick(0) disables it.
pub const SseHandler = *const fn (writer: SseWriter) bool;

/// Per-request state passed to handlers and middleware, valid during invocation.
pub const Context = struct {
    /// Socket peer, independent of untrusted forwarded request headers.
    peer: mox_io.types.Address = .{},
    gpa: std.mem.Allocator,
    request: *const http.Request,
    /// Captured path parameters, valid for this request only.
    params: *const Params,
    /// Completed request body, or an empty slice. Borrows the receive buffer without allocation.
    body: []const u8 = "",

    /// Read a raw, undecoded path parameter.
    pub fn param(self: *const Context, name: []const u8) ?[]const u8 {
        return self.params.get(name);
    }

    /// URL-decode a path parameter: %XX escapes and + as a space.
    /// The decoded value uses ctx.gpa and remains valid until the request ends.
    pub fn paramDecoded(self: *const Context, name: []const u8) !?[]const u8 {
        const raw = self.params.get(name) orelse return null;
        return try urlDecode(self.gpa, raw);
    }

    /// Read a query parameter from ?key=val&... without allocation.
    /// The value borrows request.target and remains encoded; use queryDecoded for decoding.
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

    /// URL-decode a query parameter using the request arena.
    /// Missing parameters return null; invalid % escapes return InvalidEncoding.
    pub fn queryDecoded(self: *const Context, name: []const u8) !?[]const u8 {
        const raw = self.query(name) orelse return null;
        return try urlDecode(self.gpa, raw);
    }

    /// Parse the request body as T, returning std.json.Parsed(T).
    /// In a mox server its arena uses ctx.gpa. Calling deinit is safe but optional,
    /// because request cleanup reclaims the underlying arena.
    pub fn json(self: *const Context, comptime T: type) !std.json.Parsed(T) {
        return std.json.parseFromSlice(T, self.gpa, self.body, .{});
    }

    /// Read a named cookie from the raw Cookie header without allocation.
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

    /// Read a required path parameter, or return MissingParam.
    pub fn requireParam(self: *const Context, name: []const u8) ![]const u8 {
        return self.param(name) orelse error.MissingParam;
    }

    /// Read a required query parameter, or return MissingQuery.
    pub fn requireQuery(self: *const Context, name: []const u8) ![]const u8 {
        return self.query(name) orelse error.MissingQuery;
    }

    /// Read a required request header, or return MissingHeader.
    pub fn requireHeader(self: *const Context, name: []const u8) ![]const u8 {
        return self.request.header(name) orelse error.MissingHeader;
    }
};

pub const Handler = *const fn (*Context) anyerror!Response;

/// Called once for each request body segment on the event-loop thread.
/// The final call has `final = true`; consumers must not retain `chunk`.
pub const BodyChunkHandler = *const fn (*Context, ?*anyopaque, []const u8, bool) anyerror!void;
pub const BodyStreamInit = *const fn (*Context) anyerror!?*anyopaque;
pub const BodyStreamDeinit = *const fn (*Context, ?*anyopaque) void;

// ============================================================================
// Problem Details (RFC 9457)
// ============================================================================

/// RFC 9457 structured error response. body uses the supplied allocator.
/// When using ctx.gpa, the framework reclaims it with the request arena; do not free it early.
pub fn problem(
    gpa: std.mem.Allocator,
    status: std.http.Status,
    title: []const u8,
    detail: []const u8,
) !Response {
    // Quoted struct field names produce the required JSON keys, including the Zig keyword type.
    const pd = struct {
        type: []const u8,
        status: u16,
        title: []const u8,
        detail: []const u8,
    }{
        .type = "about:blank",
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

// Cookie support.

/// Options for constructing a Set-Cookie header.
pub const CookieOptions = struct {
    /// Cookie path, defaulting to /.
    path: []const u8 = "/",
    /// Set the HTTPS-only Secure flag.
    secure: bool = false,
    /// Set HttpOnly to prevent JavaScript access.
    http_only: bool = true,
    /// SameSite policy: Strict, Lax, or None. Empty omits the attribute.
    same_site: []const u8 = "Lax",
    /// Lifetime in seconds; null creates a session cookie.
    max_age: ?i64 = null,
};

/// Build a set-cookie response header using gpa. With ctx.gpa, the request arena
/// owns its value; freeing it before transmission would leave a dangling header.
/// Allocate the header array with ctx.gpa as well, since respond reads it after return:
///
///     const header = try mox.setCookieHeader(ctx.gpa, "session", token, .{});
///     const headers = try ctx.gpa.alloc(mox.Header, 1);
///     headers[0] = header;
///     return .{ .headers = headers, .body = "logged in\n" };
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
    /// Optional bounded-memory request body consumer for Content-Length bodies.
    on_body: ?BodyChunkHandler = null,
    body_stream_init: ?BodyStreamInit = null,
    body_stream_deinit: ?BodyStreamDeinit = null,
    proxy: ?ProxyOptions = null,
};

/// Fixed-IP HTTP/1 upstream used by `proxyRoute`. TLS and DNS are intentionally
/// handled by an external proxy in this first implementation.
pub const ProxyOptions = struct {
    address: mox_io.types.Address,
    timeout_ms: u32 = 10_000,
    max_response_bytes: usize = 8 * 1024 * 1024,
};

fn proxyPlaceholder(_: *Context) anyerror!Response {
    return error.ProxyRouteDispatchedByServer;
}

pub fn proxyRoute(method: std.http.Method, path: []const u8, options: ProxyOptions) Route {
    return .{ .method = method, .path = path, .handler = proxyPlaceholder, .proxy = options };
}

/// Prefix every route at compile time for composition in Config.routes.
///
///     const v1 = mox.group("/api/v1", &.{
///         .{ .method = .GET, .path = "/users", .handler = listUsers },
///         .{ .method = .POST, .path = "/users", .handler = createUser },
///     });
pub fn group(comptime prefix: []const u8, comptime defs: []const Route) []const Route {
    comptime {
        var out: [defs.len]Route = undefined;
        for (defs, 0..) |r, i| {
            out[i] = .{
                .method = r.method,
                // Concatenate strings at compile time.
                .path = prefix ++ r.path,
                .handler = r.handler,
                .on_body = r.on_body,
                .body_stream_init = r.body_stream_init,
                .body_stream_deinit = r.body_stream_deinit,
                .proxy = r.proxy,
            };
        }
        const result = out;
        return &result;
    }
}

/// Flatten route slices at compile time: mox.routes(.{ v1_routes, v2_routes, public_routes }).
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

/// Borrowed only during on_request_complete. Path omits query strings and is
/// bounded to 256 bytes; callbacks run on the loop and must return promptly.
pub const RequestEvent = struct {
    request_id: u64,
    method: []const u8,
    path: []const u8,
    path_truncated: bool,
    status: u16,
    duration_ms: u64,
    completed: bool,
    error_name: ?[]const u8,
};

pub const Backend = enum { default, epoll, uring, kqueue, iocp };

pub const Config = struct {
    /// Run route, not_found and error handlers on the existing I/O worker pool.
    /// Callbacks may overlap across requests; body, stream and SSE callbacks stay
    /// on the loop. Request storage is retained until running callbacks return.
    blocking_handlers: bool = false,
    backend: Backend = .default,
    /// Optional embedded files, kept valid until serve() returns; disk is the fallback.
    assets: ?*const mox_io.fs.EmbeddedFs = null,
    /// Called on the loop after listening begins, with the bound address.
    ready: ?*const fn (mox_io.types.Address) void = null,
    /// Optional cross-thread shutdown/close handle; must outlive serve().
    control: ?*@import("server/control.zig").ServerControl = null,
    /// Runs once after response completion or request interruption.
    on_request_complete: ?*const fn (RequestEvent) void = null,
    gpa: std.mem.Allocator,
    address: mox_io.types.Address,
    routes: []const Route,

    /// Maximum concurrent connections. At capacity, stop accepting and leave new connections in the kernel backlog.
    max_connections: usize = 1024,
    /// Per-server requests from parsed head through response completion; SSE holds its slot for the stream lifetime; 0 disables.
    max_inflight_requests: usize = 0,
    /// Maximum upgraded WebSocket connections, independent of ordinary request capacity; 0 disables this limit.
    max_websocket_connections: usize = 256,
    /// Per-server fixed one-second window, shared across all routes; 0 disables.
    max_requests_per_second: u32 = 0,
    /// Aggregate dynamic framework/request memory budget across active connections, excluding kernel and loop infrastructure; 0 is unlimited.
    max_memory_bytes: usize = 256 * 1024 * 1024,
    /// Usable request-arena capacity retained per idle HTTP connection; 0 frees all.
    /// Retained storage stays in max_memory_bytes and is reclaimed under pressure.
    request_arena_retain_bytes: usize = 8 * 1024,
    /// WebSocket frame/message and queued output byte limits, per connection.
    ws_max_message_size: usize = 1024 * 1024,
    ws_max_queue_size: usize = 4 * 1024 * 1024,

    /// Maximum idle time between requests in milliseconds; 0 disables it.
    idle_timeout_ms: u32 = 60_000,

    /// Backoff after an accept failure, in milliseconds.
    accept_backoff_ms: u32 = 50,

    /// Request grace period during shutdown, in milliseconds. 0 cancels immediately; I/O reclamation is awaited separately.
    shutdown_timeout_ms: u32 = 5_000,

    /// Maximum request body size in bytes. Exceeding it returns 413; 0 is unlimited.
    max_body_size: usize = 4 * 1024 * 1024,

    /// Maximum request processing time in milliseconds; expiry closes the connection. Default 30s; 0 is unlimited.
    request_timeout_ms: u32 = 30_000,

    /// Fallback for handler errors. Defaults to status 500 with the error name.
    error_handler: ErrorHandler = defaultErrorHandler,

    /// Fallback for unmatched routes. Defaults to status 404 and not found.
    not_found: Handler = defaultNotFound,
};

pub fn defaultNotFound(_: *Context) anyerror!Response {
    return .{ .status = .not_found, .body = "not found\n" };
}

pub fn defaultErrorHandler(_: *Context, err: anyerror) Response {
    return .{ .status = .internal_server_error, .body = @errorName(err) };
}

pub const ErrorHandler = *const fn (*Context, anyerror) Response;

// Tests.
test "query parses URL query parameters" {
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
    try std.testing.expectEqual(@as(?[]const u8, null), ctx.query("NAME")); // Lookup is case-sensitive.
}
test "query returns null without a query string" {
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
test "Response.withJson sets application/json content_type" {
    const r = Response.withJson("{\"ok\":true}");
    try std.testing.expectEqualStrings("{\"ok\":true}", r.body);
    try std.testing.expect(std.mem.startsWith(u8, r.content_type, "application/json"));
}
test "Response.redirect generates a Location header" {
    const r = Response.redirect("/new-path", .moved_permanently);
    try std.testing.expectEqual(std.http.Status.moved_permanently, r.status);
    try std.testing.expectEqual(@as(usize, 1), r.headers.len);
    try std.testing.expectEqualStrings("location", r.headers[0].name);
    try std.testing.expectEqualStrings("/new-path", r.headers[0].value);
}
test "ctx.json parses a JSON request body" {
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

test "urlDecode decodes percent escapes and plus signs" {
    const gpa = std.testing.allocator;
    // Accept spaces, escaped slashes, plus signs, and both hexadecimal cases.
    const a = try urlDecode(gpa, "hello%20world+again");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("hello world again", a);

    const b = try urlDecode(gpa, "a%2Fb%3Dc%25d");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("a/b=c%d", b);

    // Mixed hexadecimal case.
    const c = try urlDecode(gpa, "%4a%4A");
    defer gpa.free(c);
    try std.testing.expectEqualStrings("JJ", c);
}

test "urlDecode returns unencoded input without allocation" {
    const gpa = std.testing.allocator;
    // Return the input slice directly; testing.allocator verifies that no allocation leaks.
    const s = "plain-ascii-only";
    const out = try urlDecode(gpa, s);
    try std.testing.expectEqualStrings(s, out);
    try std.testing.expect(out.ptr == s.ptr);
}

test "urlDecode rejects malformed escapes with InvalidEncoding" {
    const gpa = std.testing.allocator;
    // Truncated escape: fewer than two digits after %.
    try std.testing.expectError(error.InvalidEncoding, urlDecode(gpa, "abc%2"));
    try std.testing.expectError(error.InvalidEncoding, urlDecode(gpa, "abc%"));
    // Non-hexadecimal digits.
    try std.testing.expectError(error.InvalidEncoding, urlDecode(gpa, "abc%zz"));
    try std.testing.expectError(error.InvalidEncoding, urlDecode(gpa, "abc%g1"));
}

test "ctx.queryDecoded and paramDecoded decode values" {
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

    // query preserves the raw encoded value.
    try std.testing.expectEqualStrings("Jane+Doe", ctx.query("name").?);

    // queryDecoded converts + to a space.
    const name = (try ctx.queryDecoded("name")).?;
    defer gpa.free(name);
    try std.testing.expectEqualStrings("Jane Doe", name);

    // Multibyte UTF-8: the percent-encoded value represents Beijing in Chinese.
    const city = (try ctx.queryDecoded("city")).?;
    defer gpa.free(city);
    try std.testing.expectEqualStrings("\u{5317}\u{4eac}", city);

    // paramDecoded decodes path parameters.
    const user = (try ctx.paramDecoded("user")).?;
    defer gpa.free(user);
    try std.testing.expectEqualStrings("john doe", user);

    // Missing parameters return null rather than an error.
    try std.testing.expect((try ctx.queryDecoded("nope")) == null);
    try std.testing.expect((try ctx.paramDecoded("nope")) == null);
}
