//! HTTP/1.1 request parsing, body framing, and response serialization.
//! Parsed slices reference the input buffer; chunked decoding uses the caller allocator.

const std = @import("std");
const syntax = @import("http_syntax.zig");

const isToken = syntax.isToken;
const validValue = syntax.validValue;
const field = syntax.field;
const validHost = syntax.validHost;
const decimal = syntax.decimal;
const chunkSize = syntax.chunkSize;

/// Upper limit for the request header (request line + headers). If a client exceeds this before
/// terminating the headers, treat the input as malformed.
pub const max_head = 64 * 1024;

/// Extra response headers. Both name and value are borrowed slices; the caller owns their lifetime.
pub const Header = syntax.Field;

pub const ParseResult = union(enum) {
    /// Not enough bytes yet; read more and retry.
    incomplete,
    /// A complete request. Each slice points into the buffer passed to `parse`.
    request: Request,
    /// These bytes cannot be an HTTP/1.x request.
    malformed,
    /// Content-Length exceeds the caller-provided limit.
    body_too_large,
    /// Expectations are not negotiated; reject before waiting for a body.
    expectation_failed,
};

pub const Request = struct {
    method: std.http.Method,
    /// Request target kept verbatim, including the query string.
    target: []const u8,
    /// Path portion of the target with the query string removed; routing uses this.
    path: []const u8,
    version: []const u8,
    /// Raw header block without the trailing blank line; `header()` reads from here.
    head: []const u8,
    body: []const u8,
    keep_alive: bool,
    /// Whether the request body uses Transfer-Encoding: chunked on the wire.
    chunked: bool = false,
    /// Declared Content-Length. Streaming consumers receive the body in segments.
    body_expected: usize = 0,
    body_complete: bool = true,
    /// Bytes this request occupies in the input buffer (headers + blank line + body).
    /// For HTTP pipelining: where to resume parsing after this request.
    consumed: usize = 0,

    /// Case-insensitive header lookup; the returned value has whitespace trimmed.
    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        var lines = std.mem.splitSequence(u8, self.head, "\r\n");
        _ = lines.next(); // skip the request line
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) continue;
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
        return null;
    }
};

/// Try to read one request from `buf` without limiting body size. Never allocates.
pub fn parse(buf: []const u8) ParseResult {
    return parseWithLimit(buf, std.math.maxInt(usize));
}

/// Validate framing before dispatch. Reject oversized declared bodies before reading them.
/// max_body_size is literal; the server maps its Config value 0 to maxInt(usize).
pub fn parseWithLimit(buf: []const u8, max_body_size: usize) ParseResult {
    return parseInternal(buf, max_body_size, false);
}

/// Parse a request head even if its Content-Length body has not fully arrived.
/// A successful request then carries the available body prefix and its expected size.
pub fn parseHeadWithLimit(buf: []const u8, max_body_size: usize) ParseResult {
    return parseInternal(buf, max_body_size, true);
}

fn parseInternal(buf: []const u8, max_body_size: usize, allow_partial_body: bool) ParseResult {
    const head_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse {
        return if (buf.len >= max_head) .malformed else .incomplete;
    };
    const body_start = head_end + 4;
    if (body_start > max_head) return .malformed;
    const head = buf[0..head_end];
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const request_line = lines.next() orelse return .malformed;
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method_str = parts.next() orelse return .malformed;
    const target = parts.next() orelse return .malformed;
    const version = parts.next() orelse return .malformed;
    if (parts.next() != null) return .malformed;
    const is_http_1_1 = std.mem.eql(u8, version, "HTTP/1.1");
    if (!is_http_1_1 and !std.mem.eql(u8, version, "HTTP/1.0")) return .malformed;
    const method = std.meta.stringToEnum(std.http.Method, method_str) orelse return .malformed;
    // This origin server accepts origin-form and OPTIONS *. Proxy/CONNECT targets are unsupported.
    if (target.len == 0 or (target[0] != '/' and !(method == .OPTIONS and std.mem.eql(u8, target, "*")))) return .malformed;
    for (target) |c| if (c <= 0x20 or c >= 0x7f or c == '#') return .malformed;
    var content_length: ?usize = null;
    var chunked = false;
    var host_seen = false;
    var expectation = false;
    var connection_close = false;
    var connection_keep_alive = false;
    while (lines.next()) |line| {
        const h = field(line) orelse return .malformed;
        if (std.ascii.eqlIgnoreCase(h.name, "content-length")) {
            if (content_length != null) return .malformed;
            content_length = decimal(h.value) orelse return .malformed;
        } else if (std.ascii.eqlIgnoreCase(h.name, "transfer-encoding")) {
            if (chunked or !is_http_1_1 or !std.ascii.eqlIgnoreCase(h.value, "chunked")) return .malformed;
            chunked = true;
        } else if (std.ascii.eqlIgnoreCase(h.name, "host")) {
            if (host_seen or !validHost(h.value)) return .malformed;
            host_seen = true;
        } else if (std.ascii.eqlIgnoreCase(h.name, "expect")) {
            expectation = true;
        } else if (std.ascii.eqlIgnoreCase(h.name, "connection")) {
            var tokens = std.mem.splitScalar(u8, h.value, ',');
            while (tokens.next()) |item| {
                const token = std.mem.trim(u8, item, " \t");
                if (!isToken(token)) return .malformed;
                if (std.ascii.eqlIgnoreCase(token, "close")) connection_close = true;
                if (std.ascii.eqlIgnoreCase(token, "keep-alive")) connection_keep_alive = true;
                if (std.ascii.eqlIgnoreCase(token, "content-length") or
                    std.ascii.eqlIgnoreCase(token, "transfer-encoding") or
                    std.ascii.eqlIgnoreCase(token, "host")) return .malformed;
            }
        }
    }
    if (is_http_1_1 and !host_seen) return .malformed;
    // Never choose between two competing message boundaries, even for a zero length body.
    if (chunked and content_length != null) return .malformed;
    if (expectation) return .expectation_failed;
    const length = content_length orelse 0;
    if (length > max_body_size) return .body_too_large;
    const available = buf.len - body_start;
    if (length > available and !allow_partial_body) return .incomplete;
    const keep_alive = !connection_close and (connection_keep_alive or is_http_1_1);
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;
    return .{ .request = .{
        .method = method,
        .target = target,
        .path = path,
        .version = version,
        .head = head,
        .body = buf[body_start..][0..@min(length, available)],
        .keep_alive = keep_alive,
        .chunked = chunked,
        .body_expected = length,
        .body_complete = length <= available,
        .consumed = body_start + @min(length, available),
    } };
}

/// Result of decoding a chunked request body.
pub const ChunkedResult = union(enum) {
    /// Not enough bytes; call `recv` again and retry (no allocation).
    incomplete,
    /// Decoding complete. `body` is allocated with the caller-provided allocator and must be
    /// freed by the caller; `consumed` is the number of `input` bytes used by this request
    /// (including the trailing trailer and blank line).
    done: struct { body: []u8, consumed: usize },
    /// Malformed input (invalid hex chunk length, missing CRLF, missing final 0 chunk, etc.).
    malformed,
    /// Decoded length exceeds `max_body_size`.
    body_too_large,
};
///
/// `input` starts at the **first chunk-length line** (right after the header `\r\n\r\n`).
/// This is streaming decode: `input` may contain only part of a chunk, returning `.incomplete`;
/// the caller appends more bytes from `recv` and retries. Allocation happens only when a full
/// request is available.
///
/// Format (RFC 9112 section 7.1):
/// ```text
/// chunk-size [chunk-ext] CRLF
/// chunk-data CRLF
/// ...
/// 0 [chunk-ext] CRLF
/// trailer-part CRLF        ; may be empty, i.e. just a CRLF
/// ```
/// `chunk-ext` and `trailer-part` are syntax-checked then discarded, never exposed to the handler.
pub const max_chunk_line = 8 * 1024;
/// Cumulative chunk-size/extension/trailer/CRLF overhead, independent of payload size.
pub const max_chunk_metadata = 64 * 1024;

/// Append-only input may move on reallocation, but must retain preceding bytes.
/// Completed chunks are scanned once across recv calls. No input memory is owned here.
pub const ChunkedDecoder = struct {
    const Phase = enum { size, data, trailers, done };
    phase: Phase = .size,
    pos: usize = 0,
    pending: usize = 0,
    total: usize = 0,
    metadata: usize = 0,

    fn account(self: *ChunkedDecoder, amount: usize) bool {
        if (amount > max_chunk_metadata - self.metadata) return false;
        self.metadata += amount;
        return true;
    }

    pub fn decode(self: *ChunkedDecoder, gpa: std.mem.Allocator, input: []const u8, max_body_size: usize) ChunkedResult {
        if (self.pos > input.len or self.total > max_body_size) return .malformed;
        while (true) switch (self.phase) {
            .size, .trailers => {
                const end = std.mem.indexOfPos(u8, input, self.pos, "\r\n") orelse {
                    if (input.len - self.pos > max_chunk_line or input.len - self.pos > max_chunk_metadata - self.metadata) return .malformed;
                    return .incomplete;
                };
                const line = input[self.pos..end];
                if (line.len > max_chunk_line or !self.account(line.len + 2)) return .malformed;
                self.pos = end + 2;
                if (self.phase == .trailers) {
                    if (line.len == 0) {
                        self.phase = .done;
                    } else {
                        const h = field(line) orelse return .malformed;
                        if (syntax.forbiddenTrailer(h.name, .request)) return .malformed;
                    }
                } else {
                    const size = chunkSize(line) orelse return .malformed;
                    if (size > max_body_size - self.total) return .body_too_large;
                    self.pending = size;
                    self.phase = if (size == 0) .trailers else .data;
                }
            },
            .data => {
                const available = input.len - self.pos;
                if (self.pending > available or available - self.pending < 2) return .incomplete;
                const end = self.pos + self.pending;
                if (!std.mem.eql(u8, input[end..][0..2], "\r\n")) return .malformed;
                if (!self.account(2)) return .malformed;
                self.total += self.pending;
                self.pos = end + 2;
                self.phase = .size;
            },
            .done => {
                const body = gpa.alloc(u8, self.total) catch return .body_too_large;
                var read: usize = 0;
                var written: usize = 0;
                while (true) {
                    const end = std.mem.indexOfPos(u8, input, read, "\r\n").?;
                    const size = chunkSize(input[read..end]).?;
                    read = end + 2;
                    if (size == 0) break;
                    @memcpy(body[written..][0..size], input[read..][0..size]);
                    written += size;
                    read += size + 2;
                }
                return .{ .done = .{ .body = body, .consumed = self.pos } };
            },
        };
    }
};

pub fn decodeChunked(gpa: std.mem.Allocator, input: []const u8, max_body_size: usize) ChunkedResult {
    var decoder: ChunkedDecoder = .{};
    return decoder.decode(gpa, input, max_body_size);
}

pub const Response = struct {
    status: std.http.Status = .ok,
    body: []const u8 = "",
    content_type: []const u8 = "text/plain; charset=utf-8",
    /// Extra response headers, written after the fixed headers.
    headers: []const Header = &.{},
    chunked: bool = false,
    body_length: ?u64 = null,
};

fn reason(status: std.http.Status) []const u8 {
    return switch (status) {
        .ok => "OK",
        .created => "Created",
        .no_content => "No Content",
        .moved_permanently => "Moved Permanently",
        .found => "Found",
        .see_other => "See Other",
        .not_modified => "Not Modified",
        .temporary_redirect => "Temporary Redirect",
        .bad_request => "Bad Request",
        .unauthorized => "Unauthorized",
        .forbidden => "Forbidden",
        .not_found => "Not Found",
        .method_not_allowed => "Method Not Allowed",
        .conflict => "Conflict",
        .payload_too_large => "Payload Too Large",
        .expectation_failed => "Expectation Failed",
        .internal_server_error => "Internal Server Error",
        .not_implemented => "Not Implemented",
        .service_unavailable => "Service Unavailable",
        .too_many_requests => "Too Many Requests",
        .bad_gateway => "Bad Gateway",
        .http_version_not_supported => "HTTP Version Not Supported",
        .gateway_timeout => "Gateway Timeout",
        else => "Unknown",
    };
}

pub fn bodyAllowed(status: std.http.Status) bool {
    return @backingInt(status) >= 200 and status != .no_content and status != .reset_content and status != .not_modified;
}

/// Serialize `resp` into `buf`, returning the written slice.
/// - `error.NoSpaceLeft`: the response does not fit in `buf`.
/// - `error.InvalidHeader`: illegal field syntax, control characters, or reserved framing fields.
///
/// `head_only` is for HEAD requests: `content-length` still carries the real body length
/// (RFC 9110 section 9.3.2 requires HEAD headers to match the same GET), but no body bytes.
pub fn serialize(resp: Response, keep_alive: bool, head_only: bool, buf: []u8) error{ NoSpaceLeft, InvalidHeader }![]const u8 {
    if (!validValue(resp.content_type)) return error.InvalidHeader;
    for (resp.headers) |h| {
        if (!isToken(h.name) or !validValue(h.value)) return error.InvalidHeader;
        // Framing belongs to the runtime: conflicting headers can desynchronize clients.
        if (std.ascii.eqlIgnoreCase(h.name, "content-length") or
            std.ascii.eqlIgnoreCase(h.name, "transfer-encoding") or
            std.ascii.eqlIgnoreCase(h.name, "connection")) return error.InvalidHeader;
    }
    var pos: usize = 0;
    const prefix = std.fmt.bufPrint(buf, "HTTP/1.1 {d} {s}\r\ncontent-type: {s}\r\n", .{
        @backingInt(resp.status),
        reason(resp.status),
        resp.content_type,
    }) catch return error.NoSpaceLeft;
    pos += prefix.len;
    // 205 has no payload; an explicit zero length keeps persistent connections framed.
    const framing = if (resp.status == .reset_content)
        std.fmt.bufPrint(buf[pos..], "content-length: 0\r\n", .{}) catch return error.NoSpaceLeft
    else if (!bodyAllowed(resp.status))
        buf[pos..pos]
    else if (resp.chunked)
        std.fmt.bufPrint(buf[pos..], "transfer-encoding: chunked\r\n", .{}) catch return error.NoSpaceLeft
    else
        std.fmt.bufPrint(buf[pos..], "content-length: {d}\r\n", .{resp.body_length orelse resp.body.len}) catch return error.NoSpaceLeft;
    pos += framing.len;
    const connection = std.fmt.bufPrint(buf[pos..], "connection: {s}\r\n", .{if (keep_alive) @as([]const u8, "keep-alive") else @as([]const u8, "close")}) catch return error.NoSpaceLeft;
    pos += connection.len;
    // Write extra response headers (already checked for CRLF above)
    for (resp.headers) |h| {
        const hdr = std.fmt.bufPrint(buf[pos..], "{s}: {s}\r\n", .{ h.name, h.value }) catch return error.NoSpaceLeft;
        pos += hdr.len;
    }
    // Blank line + body (HEAD writes only the blank line, no body bytes)
    if (buf.len - pos < 2) return error.NoSpaceLeft;
    if (!head_only and bodyAllowed(resp.status) and resp.body.len > buf.len - pos - 2) return error.NoSpaceLeft;
    buf[pos] = '\r';
    buf[pos + 1] = '\n';
    pos += 2;
    if (!head_only and bodyAllowed(resp.status)) {
        @memcpy(buf[pos .. pos + resp.body.len], resp.body);
        pos += resp.body.len;
    }
    return buf[0..pos];
}

// ---- Tests ------------------------------------------------------------------
test "parses a complete GET request" {
    const raw = "GET /users/42?x=1 HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const result = parse(raw);
    try std.testing.expect(result == .request);
    const req = result.request;
    try std.testing.expectEqual(std.http.Method.GET, req.method);
    try std.testing.expectEqualStrings("/users/42?x=1", req.target);
    try std.testing.expectEqualStrings("/users/42", req.path);
    try std.testing.expectEqualStrings("HTTP/1.1", req.version);
    try std.testing.expect(req.keep_alive);
    try std.testing.expectEqualStrings("localhost", req.header("host").?);
    try std.testing.expectEqualStrings("localhost", req.header("HOST").?);
    try std.testing.expectEqualStrings("", req.body);
}
test "an incomplete head asks for more" {
    try std.testing.expect(parse("GET / HTTP/1.1\r\nHost: x\r\n") == .incomplete);
    try std.testing.expect(parse("GET / HT") == .incomplete);
}
test "a request with a body waits for the body, then surfaces it" {
    const head = "POST /submit HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\n";
    try std.testing.expect(parse(head ++ "hel") == .incomplete);
    const done = parse(head ++ "hello");
    try std.testing.expect(done == .request);
    try std.testing.expectEqual(std.http.Method.POST, done.request.method);
    try std.testing.expectEqualStrings("hello", done.request.body);
}
test "connection: close disables keep-alive even on HTTP/1.1" {
    const raw = "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
    try std.testing.expect(!parse(raw).request.keep_alive);
}
test "malformed request lines are rejected" {
    try std.testing.expect(parse("NOTAMETHOD / HTTP/1.1\r\n\r\n") == .malformed);
    try std.testing.expect(parse("GET / SPAM/1.1\r\n\r\n") == .malformed);
    try std.testing.expect(parse("GET /\r\n\r\n") == .malformed);
}
test "serializes a response with headers and body" {
    var buf: [256]u8 = undefined;
    const text = try serialize(.{ .body = "hi" }, true, false, &buf);
    try std.testing.expect(std.mem.startsWith(u8, text, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "content-length: 2\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "connection: keep-alive\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "\r\n\r\nhi"));
}

test "reset content suppresses payload and frames persistent connections" {
    var buffer: [256]u8 = undefined;
    const response = try serialize(.{ .status = .reset_content, .body = "discard", .body_length = 99, .chunked = true }, true, false, &buffer);
    try std.testing.expect(!bodyAllowed(.reset_content));
    try std.testing.expect(std.mem.indexOf(u8, response, "content-length: 0\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "transfer-encoding") == null);
    try std.testing.expect(std.mem.endsWith(u8, response, "\r\n\r\n"));
}

test "serializes standard gateway status phrases" {
    var buf: [256]u8 = undefined;
    const bad_gateway = try serialize(.{ .status = .bad_gateway }, false, false, &buf);
    try std.testing.expect(std.mem.startsWith(u8, bad_gateway, "HTTP/1.1 502 Bad Gateway\r\n"));
    const timeout = try serialize(.{ .status = .gateway_timeout }, false, false, &buf);
    try std.testing.expect(std.mem.startsWith(u8, timeout, "HTTP/1.1 504 Gateway Timeout\r\n"));
}
test "a not-found response says so" {
    var buf: [256]u8 = undefined;
    const text = try serialize(.{ .status = .not_found, .body = "nope" }, false, false, &buf);
    try std.testing.expect(std.mem.startsWith(u8, text, "HTTP/1.1 404 Not Found\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "connection: close\r\n") != null);
}
test "chunked transfer-encoding is detected" {
    const raw = "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n";
    const result = parse(raw);
    try std.testing.expect(result == .request);
    try std.testing.expect(result.request.chunked);
}
test "duplicate content-length is malformed" {
    const raw = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\nhello";
    try std.testing.expect(parse(raw) == .malformed);
}
test "parseWithLimit returns body_too_large when content-length exceeds limit" {
    const raw = "POST /submit HTTP/1.1\r\nHost: x\r\nContent-Length: 1000\r\n\r\n";
    try std.testing.expect(parseWithLimit(raw, 100) == .body_too_large);
    try std.testing.expect(parseWithLimit(raw, 2000) == .incomplete);
}
test "serialize writes extra response headers" {
    var buf: [512]u8 = undefined;
    const hdrs = [_]Header{
        .{ .name = "x-request-id", .value = "abc" },
        .{ .name = "cache-control", .value = "no-cache" },
    };
    const text = try serialize(.{ .body = "ok", .headers = &hdrs }, false, false, &buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "x-request-id: abc\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cache-control: no-cache\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "\r\n\r\nok"));
}

// CRLF-injection regression: header names/values containing CR/LF must be rejected; no injected
// The teeth of this test: temporarily remove the serialization check and every assertion below
// and output containing X-Injected - i.e. a forged second response.
test "serialize rejects response header CRLF injection" {
    var buf: [512]u8 = undefined;

    const evil = "abc\r\nX-Injected: pwned\r\n\r\nHTTP/1.1 200 OK";
    const cases = [_]Response{
        .{ .body = "ok", .headers = &.{.{ .name = "x-user", .value = evil }} },
        .{ .body = "ok", .headers = &.{.{ .name = "x-user\r\nX-Injected: 1", .value = "v" }} },
        .{ .body = "ok", .headers = &.{.{ .name = "x-user", .value = "a\nb" }} },
        .{ .body = "ok", .content_type = "text/plain\r\nX-Injected: 1" },
    };
    for (cases) |r| {
        try std.testing.expectError(error.InvalidHeader, serialize(r, false, false, &buf));
    }

    // Positive case: CRLF inside the body is legal (not a header) and must not be rejected.
    const ok_text = try serialize(.{ .body = "line1\r\nline2\n" }, false, false, &buf);
    try std.testing.expect(std.mem.endsWith(u8, ok_text, "\r\n\r\nline1\r\nline2\n"));
}

// HEAD semantics (RFC 9110 section 9.3.2): headers match the same GET (including the real
// content-length), but no body bytes are written. If `head_only` is ignored, the last assertion
test "serialize head_only preserves content-length without a body" {
    var buf: [256]u8 = undefined;
    const resp = Response{ .body = "hello world" };

    const get_text = try serialize(resp, true, false, &buf);
    try std.testing.expect(std.mem.endsWith(u8, get_text, "\r\n\r\nhello world"));

    const head_text = try serialize(resp, true, true, &buf);
    // content-length must be the real body length (11), not 0.
    try std.testing.expect(std.mem.indexOf(u8, head_text, "content-length: 11\r\n") != null);
    // Ends with a blank line; not a single body byte is written.
    try std.testing.expect(std.mem.endsWith(u8, head_text, "\r\n\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, head_text, "hello") == null);
    // Header part is identical to GET (only the body is missing).
    try std.testing.expect(std.mem.startsWith(u8, get_text, head_text));
}

// ---- chunked decode tests --------------------------------------------------

test "decodeChunked decodes a basic body" {
    const gpa = std.testing.allocator;
    // "Wiki" + "pedia" + " in\r\n\r\nchunks."
    const raw = "4\r\nWiki\r\n5\r\npedia\r\nE\r\n in\r\n\r\nchunks.\r\n0\r\n\r\n";
    const r = decodeChunked(gpa, raw, 1024 * 1024);
    try std.testing.expect(r == .done);
    defer gpa.free(r.done.body);
    try std.testing.expectEqualStrings("Wikipedia in\r\n\r\nchunks.", r.done.body);
    try std.testing.expectEqual(raw.len, r.done.consumed);
}

test "decodeChunked skips chunk extensions and trailers" {
    const gpa = std.testing.allocator;
    // Chunk length with extension parameters and a trailing trailer header
    const raw = "5;name=value\r\nhello\r\n0\r\nX-Checksum: abc\r\n\r\n";
    const r = decodeChunked(gpa, raw, 1024);
    try std.testing.expect(r == .done);
    defer gpa.free(r.done.body);
    try std.testing.expectEqualStrings("hello", r.done.body);
    try std.testing.expectEqual(raw.len, r.done.consumed);
}

test "decodeChunked handles an empty body" {
    const gpa = std.testing.allocator;
    const raw = "0\r\n\r\n";
    const r = decodeChunked(gpa, raw, 1024);
    try std.testing.expect(r == .done);
    defer gpa.free(r.done.body);
    try std.testing.expectEqual(@as(usize, 0), r.done.body.len);
    try std.testing.expectEqual(@as(usize, 5), r.done.consumed);
}

test "decodeChunked accepts mixed-case hexadecimal" {
    const gpa = std.testing.allocator;
    // a = 10 bytes; uppercase A must also be accepted
    const raw = "A\r\n0123456789\r\n0\r\n\r\n";
    const r = decodeChunked(gpa, raw, 1024);
    try std.testing.expect(r == .done);
    defer gpa.free(r.done.body);
    try std.testing.expectEqualStrings("0123456789", r.done.body);
}

test "decodeChunked returns incomplete without allocating" {
    const gpa = std.testing.allocator;
    // Chunk-length line complete but data not yet arrived: must return incomplete, and
    // testing.allocator will prove this path performs no allocation at all.
    try std.testing.expect(decodeChunked(gpa, "5\r\nhel", 1024) == .incomplete);
    try std.testing.expect(decodeChunked(gpa, "5\r\nhello", 1024) == .incomplete); // missing final CRLF
    try std.testing.expect(decodeChunked(gpa, "5", 1024) == .incomplete); // length line incomplete
    try std.testing.expect(decodeChunked(gpa, "0\r\n", 1024) == .incomplete); // trailer blank line missing
}

test "decodeChunked rejects malformed input" {
    const gpa = std.testing.allocator;
    // Non-hexadecimal chunk length
    try std.testing.expect(decodeChunked(gpa, "zz\r\nhello\r\n0\r\n\r\n", 1024) == .malformed);
    // Missing CRLF after chunk data
    try std.testing.expect(decodeChunked(gpa, "5\r\nhelloXX0\r\n\r\n", 1024) == .malformed);
}

test "decodeChunked enforces its body limit" {
    const gpa = std.testing.allocator;
    // Two 10-byte chunks with a limit of 15, so the second chunk exceeds the limit
    const raw = "A\r\n0123456789\r\nA\r\n0123456789\r\n0\r\n\r\n";
    try std.testing.expect(decodeChunked(gpa, raw, 15) == .body_too_large);
    // Limit is just enough
    const ok = decodeChunked(gpa, raw, 20);
    try std.testing.expect(ok == .done);
    defer gpa.free(ok.done.body);
    try std.testing.expectEqual(@as(usize, 20), ok.done.body.len);
}

test "decodeChunked returns an allocation the caller can free" {
    const gpa = std.testing.allocator;
    // Regression: the first version allocated by input length but returned a shortened slice,
    // bookkeeping to enforce that the returned slice len equals the allocated length.
    const raw = "3\r\nabc\r\n3\r\ndef\r\n0\r\n\r\n";
    const r = decodeChunked(gpa, raw, 1024);
    try std.testing.expect(r == .done);
    try std.testing.expectEqualStrings("abcdef", r.done.body);
    gpa.free(r.done.body); // a length mismatch panics here
}

test "request framing rejects ambiguity and invalid syntax" {
    const heads = [_][]const u8{
        "Content-Length: 0\r\nTransfer-Encoding: chunked\r\n",
        "Transfer-Encoding: chunked\r\nContent-Length: 0\r\n",
        "Transfer-Encoding: gzip\r\n",
        "Transfer-Encoding: gzip, chunked\r\n",
        "Transfer-Encoding: chunked, chunked\r\n",
        "Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n",
        "Content-Length: 1\r\nContent-Length: 1\r\n",
        "Content-Length: 1, 1\r\n",
        "Content-Length: +1\r\n",
        "Content-Length: -1\r\n",
        "Content-Length: 1_0\r\n",
        "Content-Length: 0x10\r\n",
        "Content-Length: 18446744073709551616\r\n",
        "Content-Length : 0\r\n",
        " Transfer-Encoding: chunked\r\n",
        "X : a\r\n",
        ": a\r\n",
        "X(a): b\r\n",
        "X: a\x00b\r\n",
        "X: a\nb\r\n",
        "X: a\rb\r\n",
        "X: a\x7fb\r\n",
        "X: first\r\n second\r\n",
        "Host: second\r\n",
        "Connection: content-length\r\n",
        "Connection: host\r\n",
        "Connection: close,,keep-alive\r\n",
    };
    var buffer: [1024]u8 = undefined;
    for (heads) |head| {
        const request = try std.fmt.bufPrint(&buffer, "POST / HTTP/1.1\r\nHost: x\r\n{s}\r\n", .{head});
        try std.testing.expect(parse(request) == .malformed);
    }
    const requests = [_][]const u8{
        "GET / HTTP/1.1\r\n\r\n",                               "GET / HTTP/1.1\r\nHost: \r\n\r\n",
        "GET / HTTP/1.1\r\nHost: x,y\r\n\r\n",                  "GET / HTTP/1.1\r\nHost: x y\r\n\r\n",
        "GET / HTTP/2.0\r\nHost: x\r\n\r\n",                    "GET / HTTP/1.10\r\nHost: x\r\n\r\n",
        "GET  HTTP/1.1\r\nHost: x\r\n\r\n",                     "GET /bad#fragment HTTP/1.1\r\nHost: x\r\n\r\n",
        "GET /bad\tpath HTTP/1.1\r\nHost: x\r\n\r\n",           "GET http://x/ HTTP/1.1\r\nHost: x\r\n\r\n",
        "GET / HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n",
    };
    for (requests) |request| try std.testing.expect(parse(request) == .malformed);
}

test "request boundary and connection token lists are exact" {
    const wire = "POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nConnection: keep-alive, CLOSE\r\n\r\nabc";
    const pipeline = wire ++ "GET /b HTTP/1.1\r\nHost: x\r\n\r\n";
    for (0..wire.len) |n| try std.testing.expect(parse(wire[0..n]) == .incomplete);
    const request = parse(pipeline).request;
    try std.testing.expectEqual(wire.len, request.consumed);
    try std.testing.expectEqualStrings("abc", request.body);
    try std.testing.expect(!request.keep_alive);
    try std.testing.expectEqualStrings("/b", parse(pipeline[request.consumed..]).request.path);
    const huge = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 18446744073709551615\r\n\r\n";
    if (@bitSizeOf(usize) == 64) try std.testing.expect(parse(huge) == .incomplete);
    try std.testing.expect(parseWithLimit(huge, 1) == .body_too_large or @bitSizeOf(usize) != 64);
    try std.testing.expect(parse("OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n") == .request);
    try std.testing.expect(parse("GET / HTTP/1.0\r\n\r\n") == .request);
    try std.testing.expect(parse("POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 9\r\n\r\n") == .expectation_failed);
}

test "completed and partial request heads obey the same limit" {
    const buffer = try std.testing.allocator.alloc(u8, max_head + 1);
    defer std.testing.allocator.free(buffer);
    @memset(buffer, 'x');
    const prefix = "GET / HTTP/1.1\r\nHost: x\r\nX: ";
    @memcpy(buffer[0..prefix.len], prefix);
    @memcpy(buffer[max_head - 4 .. max_head], "\r\n\r\n");
    try std.testing.expect(parse(buffer[0..max_head]) == .request);
    @memset(buffer[max_head - 4 ..], 'x');
    @memcpy(buffer[max_head - 3 ..][0..4], "\r\n\r\n");
    try std.testing.expect(parse(buffer) == .malformed);
    @memset(buffer[max_head - 3 ..], 'x');
    try std.testing.expect(parse(buffer) == .malformed);
}

test "chunk syntax and trailers reject alternate message boundaries" {
    const cases = [_][]const u8{
        "+1\r\na\r\n0\r\n\r\n",           " 1\r\na\r\n0\r\n\r\n",
        "1 \r\na\r\n0\r\n\r\n",           "0x1\r\na\r\n0\r\n\r\n",
        "1_0\r\n",                        "1;\r\na\r\n0\r\n\r\n",
        "1;name=\r\na\r\n0\r\n\r\n",      "1;name=\"unterminated\r\na\r\n0\r\n\r\n",
        "0\r\nContent-Length: 1\r\n\r\n", "0\r\nTransfer-Encoding: chunked\r\n\r\n",
        "0\r\nHost: other\r\n\r\n",       "0\r\nAuthorization: secret\r\n\r\n",
        "0\r\nBroken trailer\r\n\r\n",    "0\r\nX : a\r\n\r\n",
        "0\r\n X: a\r\n\r\n",
    };
    for (cases) |wire| try std.testing.expect(decodeChunked(std.testing.allocator, wire, 1024) == .malformed);
    try std.testing.expect(decodeChunked(std.testing.allocator, "ffffffffffffffff\r\n", 1024) == .body_too_large or @bitSizeOf(usize) != 64);
    if (@bitSizeOf(usize) == 64) try std.testing.expect(decodeChunked(std.testing.allocator, "ffffffffffffffff\r\n", std.math.maxInt(usize)) == .incomplete);
}

test "incremental chunk boundaries preserve trailers and pipelined tail" {
    const wire = "1 ; x=\"a;\\\"b\";flag\r\na\r\n2\r\nbc\r\n0\r\nX-Checksum: ok\r\n\r\n";
    var decoder: ChunkedDecoder = .{};
    for (0..wire.len) |n| try std.testing.expect(decoder.decode(std.testing.allocator, wire[0..n], 3) == .incomplete);
    const result = decoder.decode(std.testing.allocator, wire ++ "GET /next", 3);
    try std.testing.expect(result == .done);
    defer std.testing.allocator.free(result.done.body);
    try std.testing.expectEqualStrings("abc", result.done.body);
    try std.testing.expectEqual(wire.len, result.done.consumed);
}

test "chunk metadata is bounded even with unlimited body size" {
    const buffer = try std.testing.allocator.alloc(u8, 2 * max_chunk_metadata + 64);
    defer std.testing.allocator.free(buffer);
    @memset(buffer, 'a');
    try std.testing.expect(decodeChunked(std.testing.allocator, buffer[0 .. max_chunk_line + 1], std.math.maxInt(usize)) == .malformed);
    const chunk = "1\r\na\r\n";
    var pos: usize = 0;
    while (pos + chunk.len <= buffer.len - 5) : (pos += chunk.len) @memcpy(buffer[pos..][0..chunk.len], chunk);
    @memcpy(buffer[pos..][0..5], "0\r\n\r\n");
    try std.testing.expect(decodeChunked(std.testing.allocator, buffer[0 .. pos + 5], std.math.maxInt(usize)) == .malformed);
}

fn checkFuzzInput(_: void, smith: *std.testing.Smith) !void {
    var storage: [4096]u8 = undefined;
    const len = smith.sliceWithHash(&storage, 0x6d6f7801);
    const input = storage[0..len];
    const parsed = parseWithLimit(input, 4096);
    if (parsed == .request) {
        const request = parsed.request;
        try std.testing.expect(request.consumed <= input.len);
        try std.testing.expect(request.body.len <= 4096);
        try std.testing.expect(request.head.len <= max_head);
        const again = parseWithLimit(input[0..request.consumed], 4096);
        try std.testing.expect(again == .request);
        try std.testing.expectEqual(request.consumed, again.request.consumed);
        try std.testing.expectEqualStrings(request.body, again.request.body);
    }
    const whole = decodeChunked(std.testing.allocator, input, 4096);
    defer if (whole == .done) std.testing.allocator.free(whole.done.body);
    var decoder: ChunkedDecoder = .{};
    var fragmented: ChunkedResult = .incomplete;
    var end: usize = 0;
    while (fragmented == .incomplete and end < input.len) {
        end = @min(input.len, end + 7);
        fragmented = decoder.decode(std.testing.allocator, input[0..end], 4096);
    }
    if (input.len == 0) fragmented = decoder.decode(std.testing.allocator, input, 4096);
    defer if (fragmented == .done) std.testing.allocator.free(fragmented.done.body);
    try std.testing.expectEqual(std.meta.activeTag(whole), std.meta.activeTag(fragmented));
    if (whole == .done and fragmented == .done) {
        try std.testing.expect(whole.done.consumed <= input.len);
        try std.testing.expect(whole.done.body.len <= 4096);
        try std.testing.expectEqual(whole.done.consumed, fragmented.done.consumed);
        try std.testing.expectEqualSlices(u8, whole.done.body, fragmented.done.body);
    }
}

fn fuzzSeed(comptime bytes: []const u8) []const u8 {
    return std.mem.toBytes(std.mem.nativeToLittle(u32, bytes.len)) ++ bytes;
}

test "fuzz HTTP and incremental chunk boundaries" {
    try std.testing.fuzz({}, checkFuzzInput, .{ .corpus = &.{
        fuzzSeed("GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
        fuzzSeed("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabcGET /next HTTP/1.1\r\nHost: x\r\n\r\n"),
        fuzzSeed("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"),
        fuzzSeed("3\r\nabc\r\n0\r\nX-Checksum: ok\r\n\r\nGET /next"),
        fuzzSeed("1 ; x=\"a;b\"\r\na\r\n0\r\n\r\n"),
        fuzzSeed("ffffffffffffffff\r\n"),
        fuzzSeed("0\r\nContent-Length: 1\r\n\r\n"),
    } });
}
