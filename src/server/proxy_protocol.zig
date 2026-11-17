//! Canonical upstream requests with a single body boundary and no hop headers.

const std = @import("std");
const http = @import("../http.zig");
const syntax = @import("../http_syntax.zig");

/// The caller frees the result. Chunked input must already have a decoded body.
pub fn buildRequest(allocator: std.mem.Allocator, req: http.Request) ![]const u8 {
    if (!req.body_complete) return error.IncompleteRequest;
    if (req.target.len == 0 or req.target[0] != '/') return error.InvalidRequest;
    for (req.target) |c| if (c <= 0x20 or c >= 0x7f or c == '#') return error.InvalidRequest;

    var lines = std.mem.splitSequence(u8, req.head, "\r\n");
    _ = lines.next() orelse return error.InvalidRequest;
    var host: ?[]const u8 = null;
    var length: ?usize = null;
    var chunked = false;
    while (lines.next()) |line| {
        const field = try parseField(line);
        if (std.ascii.eqlIgnoreCase(field.name, "host")) {
            if (host != null or !syntax.validHost(field.value)) return error.InvalidRequest;
            host = field.value;
        } else if (std.ascii.eqlIgnoreCase(field.name, "content-length")) {
            if (length != null) return error.InvalidRequest;
            length = syntax.decimal(field.value) orelse return error.InvalidRequest;
        } else if (std.ascii.eqlIgnoreCase(field.name, "transfer-encoding")) {
            if (chunked or !std.ascii.eqlIgnoreCase(field.value, "chunked")) return error.InvalidRequest;
            chunked = true;
        } else if (std.ascii.eqlIgnoreCase(field.name, "connection")) {
            var tokens = std.mem.splitScalar(u8, field.value, ',');
            while (tokens.next()) |raw| {
                const token = std.mem.trim(u8, raw, " \t");
                if (!syntax.isToken(token)) return error.InvalidRequest;
                // Never let hop-header removal erase the authority or body boundary.
                for ([_][]const u8{ "host", "content-length", "transfer-encoding" }) |reserved| {
                    if (std.ascii.eqlIgnoreCase(token, reserved)) return error.InvalidRequest;
                }
            }
        }
    }
    if (host == null or (chunked and length != null)) return error.InvalidRequest;
    if (length) |n| {
        if (n != req.body.len) return error.InvalidRequest;
    } else if (!chunked and req.body.len != 0) return error.InvalidRequest;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const start = try std.fmt.allocPrint(allocator, "{s} {s} HTTP/1.1\r\nHost: {s}\r\nContent-Length: {d}\r\n", .{ @tagName(req.method), req.target, host.?, req.body.len });
    defer allocator.free(start);
    try out.appendSlice(allocator, start);
    lines.reset();
    _ = lines.next();
    while (lines.next()) |line| {
        const field = try parseField(line);
        if (std.ascii.eqlIgnoreCase(field.name, "host") or std.ascii.eqlIgnoreCase(field.name, "content-length") or hopHeader(field.name, req.head)) continue;
        try out.appendSlice(allocator, line);
        try out.appendSlice(allocator, "\r\n");
    }
    try out.appendSlice(allocator, "Connection: close\r\n\r\n");
    try out.appendSlice(allocator, req.body);
    return out.toOwnedSlice(allocator);
}

/// Call only after proxy_framing.complete accepts the full response. The caller frees the result.
pub fn forwardResponse(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var offset: usize = 0;
    while (true) {
        const end = std.mem.indexOfPos(u8, bytes, offset, "\r\n\r\n") orelse return error.InvalidResponse;
        const head = bytes[offset..end];
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        const status_line = lines.next() orelse return error.InvalidResponse;
        if (status_line.len < 12) return error.InvalidResponse;
        const status = syntax.decimal(status_line[9..12]) orelse return error.InvalidResponse;
        while (lines.next()) |line| {
            const field = syntax.field(line) orelse return error.InvalidResponse;
            if (std.ascii.eqlIgnoreCase(field.name, "connection")) {
                var tokens = std.mem.splitScalar(u8, field.value, ',');
                while (tokens.next()) |raw| {
                    const token = std.mem.trim(u8, raw, " \t");
                    if (!syntax.isToken(token)) return error.InvalidResponse;
                    // The already-validated body must retain the same framing at the next hop.
                    if (framingHeader(token)) return error.InvalidResponse;
                }
            }
        }
        try out.appendSlice(allocator, status_line);
        try out.appendSlice(allocator, "\r\n");
        lines.reset();
        _ = lines.next();
        while (lines.next()) |line| {
            const field = syntax.field(line) orelse return error.InvalidResponse;
            if (!framingHeader(field.name) and hopHeader(field.name, head)) continue;
            try out.appendSlice(allocator, line);
            try out.appendSlice(allocator, "\r\n");
        }
        offset = end + 4;
        if (status >= 200) {
            try out.appendSlice(allocator, "Connection: close\r\n\r\n");
            try out.appendSlice(allocator, bytes[offset..]);
            return out.toOwnedSlice(allocator);
        }
        try out.appendSlice(allocator, "\r\n");
    }
}

fn framingHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "content-length") or std.ascii.eqlIgnoreCase(name, "transfer-encoding");
}

fn parseField(line: []const u8) error{InvalidRequest}!http.Header {
    return syntax.field(line) orelse error.InvalidRequest;
}

fn hopHeader(name: []const u8, head: []const u8) bool {
    for ([_][]const u8{ "connection", "keep-alive", "proxy-connection", "proxy-authorization", "proxy-authenticate", "te", "trailer", "transfer-encoding", "upgrade" }) |hop| {
        if (std.ascii.eqlIgnoreCase(name, hop)) return true;
    }
    // Repeated Connection fields form one token list; inspecting only the first leaks headers.
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const field = parseField(line) catch return true;
        if (!std.ascii.eqlIgnoreCase(field.name, "connection")) continue;
        var tokens = std.mem.splitScalar(u8, field.value, ',');
        while (tokens.next()) |token| {
            if (std.ascii.eqlIgnoreCase(name, std.mem.trim(u8, token, " \t"))) return true;
        }
    }
    return false;
}

test "proxy canonicalizes framing and removes all connection-nominated fields" {
    const req = http.parse("POST /upload?q=1 HTTP/1.1\r\nHost: example.com\r\nContent-Length: 3\r\nConnection: X-First\r\nConnection: x-second\r\nX-First: secret\r\nX-Second: secret\r\nKeep-Alive: timeout=5\r\nX-End: visible\r\n\r\nabc").request;
    const bytes = try buildRequest(std.testing.allocator, req);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("POST /upload?q=1 HTTP/1.1\r\nHost: example.com\r\nContent-Length: 3\r\nX-End: visible\r\nConnection: close\r\n\r\nabc", bytes);
}

test "proxy replaces decoded chunked framing with the actual content length" {
    var req = http.parse("POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\nTrailer: X-Digest\r\n\r\n").request;
    req.body = "decoded body";
    const bytes = try buildRequest(std.testing.allocator, req);
    defer std.testing.allocator.free(bytes);
    const parsed = http.parse(bytes).request;
    try std.testing.expectEqualStrings("decoded body", parsed.body);
    try std.testing.expectEqualStrings("12", parsed.header("content-length").?);
    try std.testing.expect(parsed.header("transfer-encoding") == null);
    try std.testing.expect(parsed.header("trailer") == null);
}

test "proxy rejects lost authority, ambiguous lengths, and incomplete bodies" {
    const forbidden = [_][]const u8{
        "Host: example.com\r\nConnection: Host",
        "Host: example.com\r\nConnection: Content-Length",
        "Host: example.com\r\nConnection: Transfer-Encoding",
        "Host: example.com\r\nContent-Length: 0\r\nTransfer-Encoding: chunked",
        "Host: example.com\r\nContent-Length: 0\r\nContent-Length: 0",
        "Host: example.com\r\nConnection: X,,Y",
        "Host : example.com",
        "Host: first\r\nHost: second",
    };
    for (forbidden) |fields| {
        const head = try std.fmt.allocPrint(std.testing.allocator, "GET / HTTP/1.1\r\n{s}", .{fields});
        defer std.testing.allocator.free(head);
        const req: http.Request = .{ .method = .GET, .target = "/", .path = "/", .version = "HTTP/1.1", .head = head, .body = "", .keep_alive = false };
        try std.testing.expectError(error.InvalidRequest, buildRequest(std.testing.allocator, req));
    }
    var req = http.parse("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n").request;
    req.body_complete = false;
    try std.testing.expectError(error.IncompleteRequest, buildRequest(std.testing.allocator, req));
    req.body_complete = true;
    req.body = "unexpected";
    try std.testing.expectError(error.InvalidRequest, buildRequest(std.testing.allocator, req));
}

test "proxy response strips repeated hop nominations and preserves informational heads" {
    const input = "HTTP/1.1 103 Early Hints\r\nLink: </style.css>; rel=preload\r\nConnection: X-Hint\r\nX-Hint: secret\r\n\r\n" ++
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive, X-First\r\nConnection: X-Second\r\nX-First: secret\r\nX-Second: private\r\nKeep-Alive: timeout=5\r\nProxy-Authenticate: Basic\r\nX-End: yes\r\n\r\nok";
    const output = try forwardResponse(std.testing.allocator, input);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("HTTP/1.1 103 Early Hints\r\nLink: </style.css>; rel=preload\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\nX-End: yes\r\nConnection: close\r\n\r\nok", output);
}

test "proxy response retains exact chunk wire framing after header sanitization" {
    const head = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\nTrailer: X-Digest\r\n\r\n";
    const body = "3;type=\"raw\"\r\nabc\r\n0\r\nX-Digest: abc\r\n\r\n";
    const output = try forwardResponse(std.testing.allocator, head ++ body);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" ++ body, output);
}

test "proxy response rejects connection nominations that change body framing" {
    for ([_][]const u8{ "Content-Length", "transfer-encoding", "X,,Y" }) |token| {
        const input = try std.fmt.allocPrint(std.testing.allocator, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: {s}\r\n\r\n", .{token});
        defer std.testing.allocator.free(input);
        try std.testing.expectError(error.InvalidResponse, forwardResponse(std.testing.allocator, input));
    }
}
