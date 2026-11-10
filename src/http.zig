//! 一个精简的 HTTP/1.1 编解码器。
//!
//! `std.http.Server` 围绕 `std.Io` reader/writer 构建，
//! 与完成循环不合：没有可以阻塞 `read` 的位置，且请求
//! 是按 `recv` 分块到达而非字节流。因此 mox 直接
//! 从接收缓冲里解析请求。
//!
//! 当前范围：每次解析一个请求、仅 `Content-Length` 请求体，
//! 不支持分块传输编码与 trailer。足以覆盖常规请求/响应，
//! 升级路径（WebSocket、分块上传）留待以后。

const std = @import("std");

/// 请求头（请求行 + 头部）的上限。客户端若在未结束头部前
/// 超出此长度，一律视为格式错误，而不是
/// 让缓冲区无限增长。
pub const max_head = 64 * 1024;

pub const ParseResult = union(enum) {
    /// 字节还不够；继续读取后重试。
    incomplete,
    /// 一个完整请求。各切片指向传给 `parse` 的缓冲区。
    request: Request,
    /// 这些字节不可能是 HTTP/1.x 请求。
    malformed,
};

pub const Request = struct {
    method: std.http.Method,
    /// 原样保留的请求目标，含查询串。
    target: []const u8,
    /// 仅目标里的路径部分，已去掉查询串；路由用的就是它。
    path: []const u8,
    version: []const u8,
    /// 原始头部块，不含结尾空行；`header()`
    /// 从这里读取。
    head: []const u8,
    body: []const u8,
    keep_alive: bool,

    /// 大小写不敏感的头部查找，返回值已去掉
    /// 首尾空白。
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

/// 尝试从 `buf` 读出一个请求。绝不分配；返回的切片
/// 都指向 `buf` 本身。
pub fn parse(buf: []const u8) ParseResult {
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
    var connection_close = false;
    var connection_keep_alive = false;

    const rest = head[request_line.len..];
    var hit = std.mem.splitSequence(u8, rest, "\r\n");
    _ = hit.next(); // empty first element
    while (hit.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return .malformed;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch return .malformed;
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            if (std.ascii.eqlIgnoreCase(value, "close")) connection_close = true;
            if (std.ascii.eqlIgnoreCase(value, "keep-alive")) connection_keep_alive = true;
        }
    }

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
    } };
}

pub const Response = struct {
    status: std.http.Status = .ok,
    body: []const u8 = "",
    content_type: []const u8 = "text/plain; charset=utf-8",
};

fn reason(status: std.http.Status) []const u8 {
    return switch (status) {
        .ok => "OK",
        .created => "Created",
        .no_content => "No Content",
        .bad_request => "Bad Request",
        .not_found => "Not Found",
        .method_not_allowed => "Method Not Allowed",
        .internal_server_error => "Internal Server Error",
        else => "Unknown",
    };
}

/// 把 `resp` 序列化进 `buf`，返回写出的切片。若整个响应放不下，
/// 返回 `error.NoSpaceLeft`——调用方应按头部加上
/// 本次 body 的尺寸来准备 `buf`。
pub fn serialize(resp: Response, keep_alive: bool, buf: []u8) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(buf, "HTTP/1.1 {d} {s}\r\ncontent-type: {s}\r\ncontent-length: {d}\r\nconnection: {s}\r\n\r\n{s}", .{
        @intFromEnum(resp.status),
        reason(resp.status),
        resp.content_type,
        resp.body.len,
        if (keep_alive) @as([]const u8, "keep-alive") else @as([]const u8, "close"),
        resp.body,
    });
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
