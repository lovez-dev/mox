//! Validate a buffered upstream response before forwarding any bytes.

const std = @import("std");
const syntax = @import("../http_syntax.zig");

const Error = error{InvalidResponse};

pub fn complete(bytes: []const u8, eof: bool, head_only: bool) Error!bool {
    var offset: usize = 0;
    while (true) {
        const end = std.mem.indexOfPos(u8, bytes, offset, "\r\n\r\n") orelse return if (eof) error.InvalidResponse else false;
        var lines = std.mem.splitSequence(u8, bytes[offset..end], "\r\n");
        const line = lines.next().?;
        if (line.len < 12 or (!std.mem.startsWith(u8, line, "HTTP/1.1 ") and !std.mem.startsWith(u8, line, "HTTP/1.0 ")) or (line.len > 12 and line[12] != ' ')) return error.InvalidResponse;
        for (line[9..12]) |c| if (!std.ascii.isDigit(c)) return error.InvalidResponse;
        for (line[12..]) |c| if ((c < 0x20 and c != '\t') or c == 0x7f) return error.InvalidResponse;
        const status = std.fmt.parseInt(u16, line[9..12], 10) catch return error.InvalidResponse;
        if (status < 100 or status > 599 or status == 101) return error.InvalidResponse;
        var length: ?usize = null;
        var chunked = false;
        while (lines.next()) |header| {
            const field = syntax.field(header) orelse return error.InvalidResponse;
            const name = field.name;
            const value = field.value;
            if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                if (length != null) return error.InvalidResponse;
                length = syntax.decimal(value) orelse return error.InvalidResponse;
            }
            if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
                if (chunked or !std.ascii.eqlIgnoreCase(value, "chunked")) return error.InvalidResponse;
                chunked = true;
            }
        }
        if (chunked and (length != null or std.mem.startsWith(u8, line, "HTTP/1.0 "))) return error.InvalidResponse;
        // Informational and 204 responses cannot carry framing fields.
        if ((status < 200 or status == 204) and (chunked or length != null)) return error.InvalidResponse;
        if (status == 205 and (chunked or (length != null and length.? != 0))) return error.InvalidResponse;
        offset = end + 4;
        if (status < 200) continue;
        if (head_only or status == 204 or status == 205 or status == 304) {
            if (bytes.len != offset) return error.InvalidResponse;
            return true;
        }
        if (chunked) return chunksComplete(bytes[offset..], eof);
        if (length) |n| {
            const actual = bytes.len - offset;
            if (actual > n or (eof and actual != n)) return error.InvalidResponse;
            return actual == n;
        }
        return eof;
    }
}

fn chunksComplete(body: []const u8, eof: bool) Error!bool {
    var pos: usize = 0;
    while (true) {
        const end = std.mem.indexOfPos(u8, body, pos, "\r\n") orelse return if (eof) error.InvalidResponse else false;
        const size = syntax.chunkSize(body[pos..end]) orelse return error.InvalidResponse;
        pos = end + 2;
        if (size == 0) {
            while (true) {
                const trailer_end = std.mem.indexOfPos(u8, body, pos, "\r\n") orelse return if (eof) error.InvalidResponse else false;
                if (trailer_end == pos) {
                    if (trailer_end + 2 != body.len) return error.InvalidResponse;
                    return true;
                }
                const trailer = body[pos..trailer_end];
                const field = syntax.field(trailer) orelse return error.InvalidResponse;
                if (syntax.forbiddenTrailer(field.name, .response)) return error.InvalidResponse;
                pos = trailer_end + 2;
            }
        }
        if (size > body.len - pos) return if (eof) error.InvalidResponse else false;
        pos += size;
        if (body.len - pos < 2) return if (eof) error.InvalidResponse else false;
        if (!std.mem.eql(u8, body[pos..][0..2], "\r\n")) return error.InvalidResponse;
        pos += 2;
    }
}

test "fixed-length responses wait for the declared body and reject truncation" {
    const head = "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n";
    try std.testing.expect(!(try complete(head ++ "ab", false, false)));
    try std.testing.expectError(error.InvalidResponse, complete(head ++ "ab", true, false));
    try std.testing.expect(try complete(head ++ "abc", false, false));
    try std.testing.expectError(error.InvalidResponse, complete(head ++ "abcd", false, false));
}

test "chunked responses require the terminating chunk and trailers" {
    const head = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n";
    try std.testing.expect(!(try complete(head ++ "3\r\nabc\r\n", false, false)));
    try std.testing.expectError(error.InvalidResponse, complete(head ++ "3\r\nabc\r\n", true, false));
    try std.testing.expect(try complete(head ++ "3\r\nabc\r\n0\r\n\r\n", false, false));
    try std.testing.expect(try complete(head ++ "0\r\nX-End: yes\r\n\r\n", false, false));
}

test "interim responses continue to the final response and HEAD has no body" {
    const interim = "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok";
    try std.testing.expect(try complete(interim, false, false));
    try std.testing.expect(try complete("HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\n", false, true));
    try std.testing.expectError(error.InvalidResponse, complete("HTTP/1.1 200 OK\r\n\r\nx", false, true));
    try std.testing.expect(try complete("HTTP/1.1 205 Reset Content\r\n\r\n", false, false));
}

test "response framing rejects conflicting lengths, malformed headers, and extra bytes" {
    try std.testing.expectError(error.InvalidResponse, complete("HTTP/1.1 200 OK\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n", false, false));
    try std.testing.expectError(error.InvalidResponse, complete("HTTP/1.1 200 OK\r\nBadHeader\r\n\r\nx", true, false));
    try std.testing.expectError(error.InvalidResponse, complete("HTTP/1.1 204 No Content\r\n\r\nx", false, false));
    try std.testing.expect(try complete("HTTP/1.1 200 OK\r\n\r\nbody", true, false));
    try std.testing.expectError(error.InvalidResponse, complete("garbage", true, false));
}

test "upstream parser rejects invalid field syntax and bodyless framing" {
    const invalid = [_][]const u8{
        "HTTP/1.1 +20 OK\r\nContent-Length: 0\r\n\r\n",
        "HTTP/1.1 200 OK\x00\r\nContent-Length: 0\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length : 0\r\n\r\n",
        "HTTP/1.1 200 OK\r\nX-Value: a\x00b\r\nContent-Length: 0\r\n\r\n",
        "HTTP/1.1 100 Continue\r\nContent-Length: 0\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
        "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n",
        "HTTP/1.1 205 Reset Content\r\nContent-Length: 9\r\n\r\n",
        "HTTP/1.0 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
    };
    for (invalid) |response| try std.testing.expectError(error.InvalidResponse, complete(response, false, false));
}

test "upstream chunk extensions and trailers are validated before forwarding" {
    const head = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n";
    try std.testing.expect(try complete(head ++ "1;key=\"a;b\"\r\nx\r\n0\r\nX-Digest: yes\r\n\r\n", false, false));
    for ([_][]const u8{
        "0;\r\n\r\n",
        "0;key=\"unterminated\r\n\r\n",
        "0\r\nContent-Length: 0\r\n\r\n",
        "0\r\nBad Name: value\r\n\r\n",
        "0\r\nX-Value: bad\x00value\r\n\r\n",
    }) |body| {
        const response = try std.mem.concat(std.testing.allocator, u8, &.{ head, body });
        defer std.testing.allocator.free(response);
        try std.testing.expectError(error.InvalidResponse, complete(response, false, false));
    }
}
