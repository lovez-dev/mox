//! Wire encoding for upgraded connections and demand-driven HTTP streams.

const std = @import("std");
const http = @import("../http.zig");
const types = @import("../types.zig");
const websocket = @import("../websocket/protocol.zig");

const websocket_magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

fn hasToken(value: []const u8, wanted: []const u8) bool {
    var tokens = std.mem.splitScalar(u8, value, ',');
    while (tokens.next()) |token| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, token, " \t"), wanted)) return true;
    }
    return false;
}

// Singleton headers cannot be selected arbitrarily when peers supply duplicates.
fn unique(request: *const http.Request, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, request.head, "\r\n");
    _ = lines.next();
    var result: ?[]const u8 = null;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], name)) continue;
        if (result != null) return null;
        result = std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return result;
}

pub fn validHandshake(request: *const http.Request) bool {
    if (request.method != .GET or !std.mem.eql(u8, request.version, "HTTP/1.1") or
        request.chunked or request.body.len != 0 or request.body_expected != 0) return false;
    const key = unique(request, "sec-websocket-key") orelse return false;
    const version = unique(request, "sec-websocket-version") orelse return false;
    const upgrade = unique(request, "upgrade") orelse return false;
    if (!std.mem.eql(u8, version, "13") or !std.ascii.eqlIgnoreCase(upgrade, "websocket")) return false;

    var lines = std.mem.splitSequence(u8, request.head, "\r\n");
    var connection_upgrade = false;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], "connection")) continue;
        const value = line[colon + 1 ..];
        if (hasToken(value, "close")) return false;
        connection_upgrade = connection_upgrade or hasToken(value, "upgrade");
    }
    if (!connection_upgrade or key.len != 24) return false;
    var decoded: [16]u8 = undefined;
    if ((std.base64.standard.Decoder.calcSizeForSlice(key) catch return false) != decoded.len) return false;
    std.base64.standard.Decoder.decode(&decoded, key) catch return false;
    var canonical: [24]u8 = undefined;
    return std.mem.eql(u8, key, std.base64.standard.Encoder.encode(&canonical, &decoded));
}

/// The returned slice uses out; validate the request before generating an upgrade.
pub fn websocketAccept(key: []const u8, out: *[28]u8) []const u8 {
    var hash = std.crypto.hash.Sha1.init(.{});
    hash.update(key);
    hash.update(websocket_magic);
    var digest: [20]u8 = undefined;
    hash.final(&digest);
    return std.base64.standard.Encoder.encode(out, &digest);
}

/// The caller frees the response after its send completion has been delivered.
pub fn websocketUpgrade(gpa: std.mem.Allocator, request: *const http.Request) ![]u8 {
    if (!validHandshake(request)) return error.InvalidHandshake;
    var buffer: [28]u8 = undefined;
    const accept = websocketAccept(request.header("sec-websocket-key").?, &buffer);
    return std.fmt.allocPrint(gpa, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept});
}

/// Queue a complete unmasked server frame. Failure preserves the previous queue.
pub fn appendFrame(gpa: std.mem.Allocator, output: *std.ArrayList(u8), opcode: types.WsOpcode, data: []const u8, max_queue: usize) types.WsSendError!void {
    switch (opcode) {
        .text => if (!std.unicode.utf8ValidateSlice(data)) return error.InvalidUtf8,
        .close, .ping, .pong => if (data.len > 125) return error.MessageTooLarge,
        .binary, .continuation => {},
        else => return error.MessageTooLarge,
    }
    var buffer: [10]u8 = undefined;
    const header = websocket.header(&buffer, opcode, data.len);
    const size = std.math.add(usize, header.len, data.len) catch return error.QueueFull;
    if (output.items.len > max_queue or size > max_queue - output.items.len) return error.QueueFull;
    try output.ensureUnusedCapacity(gpa, size);
    output.appendSliceAssumeCapacity(header);
    output.appendSliceAssumeCapacity(data);
}

pub const SseEvent = struct {
    event: []const u8 = "",
    data: []const u8,
    id: ?[]const u8 = null,
    retry_ms: ?u32 = null,
};

fn singleLine(value: []const u8) bool {
    return std.mem.indexOfAny(u8, value, "\r\n") == null;
}

// Treat CRLF as one separator and preserve an empty final data line.
const Lines = struct {
    remaining: ?[]const u8,

    fn next(self: *Lines) ?[]const u8 {
        const value = self.remaining orelse return null;
        if (std.mem.indexOfAny(u8, value, "\r\n")) |end| {
            const skip: usize = if (value[end] == '\r' and end + 1 < value.len and value[end + 1] == '\n') 2 else 1;
            self.remaining = value[end + skip ..];
            return value[0..end];
        }
        self.remaining = null;
        return value;
    }
};

fn lineSize(prefix: []const u8, value: []const u8) error{OutOfMemory}!usize {
    var total: usize = 0;
    var lines: Lines = .{ .remaining = value };
    while (lines.next()) |line| {
        total = std.math.add(usize, total, prefix.len) catch return error.OutOfMemory;
        total = std.math.add(usize, total, line.len) catch return error.OutOfMemory;
        total = std.math.add(usize, total, 2) catch return error.OutOfMemory;
    }
    return total;
}

fn appendLines(output: *std.ArrayList(u8), prefix: []const u8, value: []const u8) void {
    var lines: Lines = .{ .remaining = value };
    while (lines.next()) |line| {
        output.appendSliceAssumeCapacity(prefix);
        output.appendSliceAssumeCapacity(line);
        output.appendSliceAssumeCapacity("\r\n");
    }
}

pub fn appendSse(gpa: std.mem.Allocator, output: *std.ArrayList(u8), event: []const u8, data: []const u8) !void {
    return appendSseEvent(gpa, output, .{ .event = event, .data = data });
}

/// Copies each field into output; CR/LF in data cannot inject event metadata.
pub fn appendSseEvent(gpa: std.mem.Allocator, output: *std.ArrayList(u8), event: SseEvent) !void {
    if (!singleLine(event.event)) return error.InvalidField;
    if (event.id) |id| {
        if (!singleLine(id) or std.mem.indexOfScalar(u8, id, 0) != null) return error.InvalidField;
    }
    var retry_buffer: [10]u8 = undefined;
    const retry = if (event.retry_ms) |ms| try std.fmt.bufPrint(&retry_buffer, "{d}", .{ms}) else "";
    var size = try lineSize("data: ", event.data);
    if (event.event.len != 0) size = std.math.add(usize, size, try lineSize("event: ", event.event)) catch return error.OutOfMemory;
    if (event.id) |id| size = std.math.add(usize, size, try lineSize("id: ", id)) catch return error.OutOfMemory;
    if (event.retry_ms != null) size = std.math.add(usize, size, try lineSize("retry: ", retry)) catch return error.OutOfMemory;
    size = std.math.add(usize, size, 2) catch return error.OutOfMemory;
    try output.ensureUnusedCapacity(gpa, size);
    if (event.event.len != 0) appendLines(output, "event: ", event.event);
    if (event.id) |id| appendLines(output, "id: ", id);
    if (event.retry_ms != null) appendLines(output, "retry: ", retry);
    appendLines(output, "data: ", event.data);
    output.appendSliceAssumeCapacity("\r\n");
}

pub fn appendSseComment(gpa: std.mem.Allocator, output: *std.ArrayList(u8), text: []const u8) !void {
    const size = std.math.add(usize, try lineSize(": ", text), 2) catch return error.OutOfMemory;
    try output.ensureUnusedCapacity(gpa, size);
    appendLines(output, ": ", text);
    output.appendSliceAssumeCapacity("\r\n");
}

/// Empty producer output is not a terminator; only finishChunks ends the body.
pub fn appendChunk(gpa: std.mem.Allocator, output: *std.ArrayList(u8), data: []const u8) !void {
    if (data.len == 0) return;
    var buffer: [2 * @sizeOf(usize) + 2]u8 = undefined;
    const header = try std.fmt.bufPrint(&buffer, "{x}\r\n", .{data.len});
    const size = std.math.add(usize, data.len, header.len + 2) catch return error.OutOfMemory;
    try output.ensureUnusedCapacity(gpa, size);
    output.appendSliceAssumeCapacity(header);
    output.appendSliceAssumeCapacity(data);
    output.appendSliceAssumeCapacity("\r\n");
}

pub fn finishChunks(gpa: std.mem.Allocator, output: *std.ArrayList(u8)) !void {
    try output.appendSlice(gpa, "0\r\n\r\n");
}

test "WebSocket handshake validates canonical key and singleton headers" {
    const wire = "GET /ws HTTP/1.1\r\nHost: example.com\r\nConnection: keep-alive, Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n";
    const request = http.parse(wire).request;
    try std.testing.expect(validHandshake(&request));
    var buffer: [28]u8 = undefined;
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", websocketAccept("dGhlIHNhbXBsZSBub25jZQ==", &buffer));
    const upgrade = try websocketUpgrade(std.testing.allocator, &request);
    defer std.testing.allocator.free(upgrade);
    try std.testing.expect(std.mem.indexOf(u8, upgrade, "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n") != null);

    const duplicated = http.parse(wire[0 .. wire.len - 2] ++ "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n").request;
    try std.testing.expect(!validHandshake(&duplicated));
    var body_request = request;
    body_request.body_expected = 1;
    try std.testing.expect(!validHandshake(&body_request));
    const closing = http.parse("GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: upgrade\r\nConnection: close\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n").request;
    try std.testing.expect(!validHandshake(&closing));
}

test "SSE splits every data newline and rejects field injection atomically" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendSseEvent(std.testing.allocator, &output, .{ .event = "update", .id = "42", .retry_ms = 1000, .data = "one\r\ntwo\rthree\n" });
    const expected = "event: update\r\nid: 42\r\nretry: 1000\r\ndata: one\r\ndata: two\r\ndata: three\r\ndata: \r\n\r\n";
    try std.testing.expectEqualStrings(expected, output.items);
    try std.testing.expectError(error.InvalidField, appendSse(std.testing.allocator, &output, "ok\nid: bad", "data"));
    try std.testing.expectError(error.InvalidField, appendSseEvent(std.testing.allocator, &output, .{ .id = "bad\x00id", .data = "x" }));
    try std.testing.expectEqualStrings(expected, output.items);
}

test "server frames obey queue bounds and preserve output on rejection" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendFrame(std.testing.allocator, &output, .text, "hi", 4);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 2, 'h', 'i' }, output.items);
    try std.testing.expectError(error.QueueFull, appendFrame(std.testing.allocator, &output, .pong, "", 5));
    try std.testing.expectError(error.InvalidUtf8, appendFrame(std.testing.allocator, &output, .text, "\xff", 100));
    try std.testing.expectEqual(@as(usize, 4), output.items.len);
}

test "HTTP chunks terminate only on explicit completion" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendChunk(std.testing.allocator, &output, "");
    try appendChunk(std.testing.allocator, &output, "hello");
    try appendChunk(std.testing.allocator, &output, "world");
    try finishChunks(std.testing.allocator, &output);
    try std.testing.expectEqualStrings("5\r\nhello\r\n5\r\nworld\r\n0\r\n\r\n", output.items);
}
