//! 一个精简的 HTTP/1.1 编解码器。
//!
//! `std.http.Server` 围绕 `std.Io` reader/writer 构建，
//! 与完成循环不合：没有可以阻塞 `read` 的位置，且请求
//! 是按 `recv` 分块到达而非字节流。因此 mox 直接
//! 从接收缓冲里解析请求。
//!
//! 当前范围：每次解析一个请求、仅 `Content-Length` 请求体，
//! 不支持分块传输编码（收到 chunked 请求标记后由上层返回 501）。
const std = @import("std");

/// 请求头（请求行 + 头部）的上限。客户端若在未结束头部前
/// 超出此长度，一律视为格式错误。
pub const max_head = 64 * 1024;

/// 额外响应头。name/value 均为借用切片，生命周期由调用方保证。
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const ParseResult = union(enum) {
    /// 字节还不够；继续读取后重试。
    incomplete,
    /// 一个完整请求。各切片指向传给 `parse` 的缓冲区。
    request: Request,
    /// 这些字节不可能是 HTTP/1.x 请求。
    malformed,
    /// Content-Length 超过调用方传入的上限。
    body_too_large,
};

pub const Request = struct {
    method: std.http.Method,
    /// 原样保留的请求目标，含查询串。
    target: []const u8,
    /// 仅目标里的路径部分，已去掉查询串；路由用的就是它。
    path: []const u8,
    version: []const u8,
    /// 原始头部块，不含结尾空行；`header()` 从这里读取。
    head: []const u8,
    body: []const u8,
    keep_alive: bool,
    /// 是否收到 Transfer-Encoding: chunked。服务层应返回 501。
    chunked: bool = false,

    /// 大小写不敏感的头部查找，返回值已去掉首尾空白。
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

/// 尝试从 `buf` 读出一个请求，不限制请求体大小。绝不分配。
pub fn parse(buf: []const u8) ParseResult {
    return parseWithLimit(buf, std.math.maxInt(usize));
}

/// 同 `parse`，但当 Content-Length 超过 `max_body_size` 时
/// 返回 `.body_too_large`，让调用方在读入整个 body 之前提前拒绝。
pub fn parseWithLimit(buf: []const u8, max_body_size: usize) ParseResult {
    const head_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse {
        return if (buf.len > max_head) .malformed else .incomplete;
    };
    const head = buf[0..head_end];
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const request_line = lines.next() orelse return .malformed;
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method_str = parts.next() orelse return .malformed;
    const target = parts.next() orelse return .malformed;
    const version = parts.next() orelse return .malformed;
    if (parts.next() != null) return .malformed;
    if (!std.mem.startsWith(u8, version, "HTTP/")) return .malformed;
    const method = std.meta.stringToEnum(std.http.Method, method_str) orelse return .malformed;
    var content_length: usize = 0;
    var chunked = false;
    var connection_close = false;
    var connection_keep_alive = false;
    var cl_count: usize = 0;
    const rest = head[request_line.len..];
    var hit = std.mem.splitSequence(u8, rest, "\r\n");
    _ = hit.next(); // empty first element
    while (hit.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return .malformed;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            cl_count += 1;
            if (cl_count > 1) return .malformed; // 重复 Content-Length → 400
            content_length = std.fmt.parseInt(usize, value, 10) catch return .malformed;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            if (std.ascii.eqlIgnoreCase(value, "chunked")) chunked = true;
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            if (std.ascii.eqlIgnoreCase(value, "close")) connection_close = true;
            if (std.ascii.eqlIgnoreCase(value, "keep-alive")) connection_keep_alive = true;
        }
    }
    // 超过 body 上限：提前拒绝，防止内存耗尽。
    if (content_length > max_body_size) return .body_too_large;
    const body_start = head_end + 4;
    if (buf.len < body_start + content_length) return .incomplete;
    const is_http_1_1 = std.mem.eql(u8, version, "HTTP/1.1");
    const keep_alive = if (connection_close) false else if (connection_keep_alive) true else is_http_1_1;
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;
    return .{ .request = .{
        .method = method,
        .target = target,
        .path = path,
        .version = version,
        .head = head,
        .body = buf[body_start .. body_start + content_length],
        .keep_alive = keep_alive,
        .chunked = chunked,
    } };
}

/// 供 `http.serialize` 使用的响应描述。
pub const Response = struct {
    status: std.http.Status = .ok,
    body: []const u8 = "",
    content_type: []const u8 = "text/plain; charset=utf-8",
    /// 额外响应头，写在固定头部之后。
    headers: []const Header = &.{},
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
        .internal_server_error => "Internal Server Error",
        .not_implemented => "Not Implemented",
        .service_unavailable => "Service Unavailable",
        else => "Unknown",
    };
}

/// 头名/头值里不允许出现 CR/LF：否则不可信输入（如 cookie 值、重定向 URL）
/// 可以注入额外响应头甚至伪造第二个响应（响应拆分 / 缓存投毒）。
fn hasCrlf(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, '\r') != null or
        std.mem.indexOfScalar(u8, s, '\n') != null;
}

/// 把 `resp` 序列化进 `buf`，返回写出的切片。
/// - `error.NoSpaceLeft`：响应放不下缓冲区。
/// - `error.InvalidHeader`：头名或头值含 CR/LF（拒绝注入，不写出任何内容）。
pub fn serialize(resp: Response, keep_alive: bool, buf: []u8) error{ NoSpaceLeft, InvalidHeader }![]const u8 {
    if (hasCrlf(resp.content_type)) return error.InvalidHeader;
    for (resp.headers) |h| {
        if (hasCrlf(h.name) or hasCrlf(h.value)) return error.InvalidHeader;
    }
    var pos: usize = 0;
    const prefix = std.fmt.bufPrint(buf, "HTTP/1.1 {d} {s}\r\ncontent-type: {s}\r\ncontent-length: {d}\r\nconnection: {s}\r\n", .{
        @backingInt(resp.status),
        reason(resp.status),
        resp.content_type,
        resp.body.len,
        if (keep_alive) @as([]const u8, "keep-alive") else @as([]const u8, "close"),
    }) catch return error.NoSpaceLeft;
    pos += prefix.len;
    // 写入额外响应头（已通过上面的 CRLF 校验）
    for (resp.headers) |h| {
        const hdr = std.fmt.bufPrint(buf[pos..], "{s}: {s}\r\n", .{ h.name, h.value }) catch return error.NoSpaceLeft;
        pos += hdr.len;
    }
    // 空行 + body
    if (pos + 2 + resp.body.len > buf.len) return error.NoSpaceLeft;
    buf[pos] = '\r';
    buf[pos + 1] = '\n';
    pos += 2;
    @memcpy(buf[pos .. pos + resp.body.len], resp.body);
    pos += resp.body.len;
    return buf[0..pos];
}

// ---- 测试 ------------------------------------------------------------------
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
    const head = "POST /submit HTTP/1.1\r\nContent-Length: 5\r\n\r\n";
    try std.testing.expect(parse(head ++ "hel") == .incomplete);
    const done = parse(head ++ "hello");
    try std.testing.expect(done == .request);
    try std.testing.expectEqual(std.http.Method.POST, done.request.method);
    try std.testing.expectEqualStrings("hello", done.request.body);
}
test "connection: close disables keep-alive even on HTTP/1.1" {
    const raw = "GET / HTTP/1.1\r\nConnection: close\r\n\r\n";
    try std.testing.expect(!parse(raw).request.keep_alive);
}
test "malformed request lines are rejected" {
    try std.testing.expect(parse("NOTAMETHOD / HTTP/1.1\r\n\r\n") == .malformed);
    try std.testing.expect(parse("GET / SPAM/1.1\r\n\r\n") == .malformed);
    try std.testing.expect(parse("GET /\r\n\r\n") == .malformed);
}
test "serializes a response with headers and body" {
    var buf: [256]u8 = undefined;
    const text = try serialize(.{ .body = "hi" }, true, &buf);
    try std.testing.expect(std.mem.startsWith(u8, text, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "content-length: 2\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "connection: keep-alive\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "\r\n\r\nhi"));
}
test "a not-found response says so" {
    var buf: [256]u8 = undefined;
    const text = try serialize(.{ .status = .not_found, .body = "nope" }, false, &buf);
    try std.testing.expect(std.mem.startsWith(u8, text, "HTTP/1.1 404 Not Found\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "connection: close\r\n") != null);
}
test "chunked transfer-encoding is detected" {
    const raw = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n";
    const result = parse(raw);
    try std.testing.expect(result == .request);
    try std.testing.expect(result.request.chunked);
}
test "duplicate content-length is malformed" {
    const raw = "POST / HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\nhello";
    try std.testing.expect(parse(raw) == .malformed);
}
test "parseWithLimit returns body_too_large when content-length exceeds limit" {
    const raw = "POST /submit HTTP/1.1\r\nContent-Length: 1000\r\n\r\n";
    try std.testing.expect(parseWithLimit(raw, 100) == .body_too_large);
    try std.testing.expect(parseWithLimit(raw, 2000) == .incomplete);
}
test "serialize writes extra response headers" {
    var buf: [512]u8 = undefined;
    const hdrs = [_]Header{
        .{ .name = "x-request-id", .value = "abc" },
        .{ .name = "cache-control", .value = "no-cache" },
    };
    const text = try serialize(.{ .body = "ok", .headers = &hdrs }, false, &buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "x-request-id: abc\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cache-control: no-cache\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "\r\n\r\nok"));
}


// CRLF 注入回归：含 CR/LF 的头名或头值必须被拒绝，绝不能写出注入内容。
// 这条测试的「牙」在于：临时去掉 serialize 里的校验，下面每一条都会变绿
// 且输出里出现 X-Injected —— 即能伪造第二个响应。
test "serialize 拒绝响应头 CRLF 注入（响应拆分防护）" {
    var buf: [512]u8 = undefined;

    const evil = "abc\r\nX-Injected: pwned\r\n\r\nHTTP/1.1 200 OK";
    const cases = [_]Response{
        .{ .body = "ok", .headers = &.{.{ .name = "x-user", .value = evil }} },
        .{ .body = "ok", .headers = &.{.{ .name = "x-user\r\nX-Injected: 1", .value = "v" }} },
        .{ .body = "ok", .headers = &.{.{ .name = "x-user", .value = "a\nb" }} },
        .{ .body = "ok", .content_type = "text/plain\r\nX-Injected: 1" },
    };
    for (cases) |r| {
        try std.testing.expectError(error.InvalidHeader, serialize(r, false, &buf));
    }

    // 正例：body 里含 CRLF 是合法的（不是头），不能被误判。
    const ok_text = try serialize(.{ .body = "line1\r\nline2\n" }, false, &buf);
    try std.testing.expect(std.mem.endsWith(u8, ok_text, "\r\n\r\nline1\r\nline2\n"));
}
