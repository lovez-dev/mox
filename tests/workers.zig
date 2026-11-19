//! Worker dispatch, retained request storage, and independent WebSocket admission.
const std = @import("std");
const mox = @import("mox");
const io = @import("mox_io");
const integration = @import("integration.zig");
const support = @import("support.zig");
const Client = integration.Client;
const Server = integration.Server;
const timeout_ns = 5_000_000_000;
const get = "GET /fast HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
const slow_request = "POST /slow HTTP/1.1\r\nHost: localhost\r\nX-Retained: still-valid\r\nContent-Length: 7\r\nConnection: close\r\n\r\npayload";
const handshake = "GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n";
var started: std.atomic.Value(u32) = .init(0);
var released: std.atomic.Value(bool) = .init(false);
var finished: std.atomic.Value(u32) = .init(0);
var queued_calls: std.atomic.Value(u32) = .init(0);
var observed_errors: std.atomic.Value(u32) = .init(0);
var websocket_calls: std.atomic.Value(u32) = .init(0);
var stream_closes: std.atomic.Value(u32) = .init(0);
var stream_cancelled: std.atomic.Value(bool) = .init(false);

fn reset() void {
    started.store(0, .release);
    released.store(false, .release);
    finished.store(0, .release);
    queued_calls.store(0, .release);
    observed_errors.store(0, .release);
    websocket_calls.store(0, .release);
    stream_closes.store(0, .release);
    stream_cancelled.store(false, .release);
}

fn waitFor(counter: *std.atomic.Value(u32), value: u32) !void {
    const deadline = io.os.now() + timeout_ns;
    while (counter.load(.acquire) != value) {
        if (io.os.now() >= deadline) return error.WorkerTestTimeout;
        io.sync.Thread.yield();
    }
}

fn slow(ctx: *mox.Context) !mox.Response {
    _ = started.fetchAdd(1, .acq_rel);
    const deadline = io.os.now() + timeout_ns;
    while (!released.load(.acquire)) {
        if (io.os.now() >= deadline) return error.WorkerGateTimeout;
        io.sync.Thread.yield();
    }
    // Read and allocate after cancellation to catch early arena reclamation.
    if (!std.mem.eql(u8, ctx.body, "payload") or !std.mem.eql(u8, ctx.request.header("x-retained") orelse "", "still-valid")) return error.RequestStorageChanged;
    const response = try ctx.gpa.dupe(u8, ctx.body);
    _ = finished.fetchAdd(1, .release);
    if (ctx.request.header("x-stream") != null) {
        const state = try ctx.gpa.create(u8);
        state.* = 0;
        return .{ .stream = .{ .state = state, .next = CancelledStream.next, .close = CancelledStream.close } };
    }
    return .{ .body = response };
}

const CancelledStream = struct {
    fn next(_: *anyopaque, writer: *mox.StreamWriter) anyerror!void {
        writer.finish();
    }

    fn close(_: *anyopaque, end: mox.Stream.End) void {
        stream_cancelled.store(end == .cancelled, .release);
        _ = stream_closes.fetchAdd(1, .release);
    }
};

fn fast(ctx: *mox.Context) !mox.Response {
    if (ctx.peer.port == 0 or ctx.peer.family != .ipv4) return error.MissingPeer;
    return .{ .body = "fast" };
}

fn queued(_: *mox.Context) !mox.Response {
    _ = queued_calls.fetchAdd(1, .release);
    return .{ .body = "queued" };
}

fn failing(_: *mox.Context) !mox.Response {
    return error.HandlerFailure;
}

fn observe(event: mox.RequestEvent) void {
    if (event.error_name) |name| {
        if (std.mem.eql(u8, name, "HandlerFailure")) _ = observed_errors.fetchAdd(1, .release);
    }
}

fn wsWorker(_: ?*anyopaque, arena: std.mem.Allocator, message: mox.WsMessage) ![]const u8 {
    _ = websocket_calls.fetchAdd(1, .release);
    return arena.dupe(u8, message.data);
}

fn websocket(_: *mox.Context) !mox.Response {
    return mox.Response.upgradeBlocking(null, wsWorker);
}

const routes = [_]mox.Route{
    .{ .method = .GET, .path = "/fast", .handler = fast },
    .{ .method = .POST, .path = "/slow", .handler = slow },
    .{ .method = .GET, .path = "/queued", .handler = queued },
    .{ .method = .GET, .path = "/failure", .handler = failing },
    .{ .method = .GET, .path = "/ws", .handler = websocket },
};

fn readHead(client: *Client, socket: io.types.Handle, buffer: []u8) ![]const u8 {
    var len: usize = 0;
    while (std.mem.indexOf(u8, buffer[0..len], "\r\n\r\n") == null) {
        if (len == buffer.len) return error.ResponseTooLarge;
        _ = try client.loop.recv(socket, buffer[len..], .{ .deadline = client.loop.now() + timeout_ns });
        const completion = try client.one();
        if (completion.status != .ok or completion.bytes == 0) return error.UnexpectedDisconnect;
        len += completion.bytes;
    }
    return buffer[0..len];
}

fn closeSocket(client: *Client, socket: io.types.Handle) !void {
    try client.loop.close(socket, .cancel, 0);
    const completion = try client.one();
    try std.testing.expectEqual(io.types.Kind.close, completion.kind);
}

fn masked(buffer: []u8, opcode: u8, final: bool, data: []const u8) usize {
    std.debug.assert(data.len < 126);
    buffer[0] = opcode | (if (final) @as(u8, 0x80) else 0);
    buffer[1] = @as(u8, @intCast(data.len)) | 0x80;
    @memcpy(buffer[2..6], &[_]u8{ 1, 2, 3, 4 });
    for (data, 0..) |byte, i| buffer[6 + i] = byte ^ buffer[2 + i % 4];
    return data.len + 6;
}

test "blocked handler leaves another request runnable and retains request storage" {
    support.lock();
    defer support.unlock();
    reset();
    var server: Server = .{ .route_table = &routes, .blocking_handlers = true };
    const port = try server.start();
    defer server.stop();
    defer released.store(true, .release);
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    const socket = try client.connect(port);
    try client.send(socket, slow_request);
    try waitFor(&started, 1);
    var buffer: [2048]u8 = undefined;
    const response = try client.exchange(port, get, &buffer);
    try std.testing.expectEqualStrings("fast", try integration.body(response));
    try std.testing.expectEqual(@as(u32, 0), finished.load(.acquire));
    released.store(true, .release);
    const len = try client.receive(socket, &buffer);
    try std.testing.expectEqualStrings("payload", try integration.body(buffer[0..len]));
    try closeSocket(&client, socket);
    try std.testing.expectEqual(@as(u32, 1), finished.load(.acquire));
}

test "worker dispatch preserves method errors and records failures in either execution mode" {
    support.lock();
    defer support.unlock();
    for ([_]bool{ false, true }) |blocking| {
        reset();
        var server: Server = .{ .route_table = &routes, .blocking_handlers = blocking, .on_request_complete = observe };
        const port = try server.start();
        defer server.stop();
        var client: Client = .{};
        try client.init();
        defer client.deinit();
        var buffer: [2048]u8 = undefined;
        const wrong_method = try client.exchange(port, "POST /fast HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", &buffer);
        try std.testing.expect(std.mem.startsWith(u8, wrong_method, "HTTP/1.1 405"));
        try std.testing.expect(std.mem.indexOf(u8, wrong_method, "GET, HEAD") != null);
        const missing = try client.exchange(port, "GET /missing HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", &buffer);
        try std.testing.expect(std.mem.startsWith(u8, missing, "HTTP/1.1 404"));
        const response = try client.exchange(port, "GET /failure HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", &buffer);
        try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 500"));
        try waitFor(&observed_errors, 1);
    }
}

test "request admission bounds worker work and restores capacity after completion" {
    support.lock();
    defer support.unlock();
    reset();
    var server: Server = .{ .route_table = &routes, .blocking_handlers = true, .max_inflight_requests = 1 };
    const port = try server.start();
    defer server.stop();
    defer released.store(true, .release);
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    const socket = try client.connect(port);
    try client.send(socket, slow_request);
    try waitFor(&started, 1);
    var buffer: [2048]u8 = undefined;
    const overload = try client.exchange(port, get, &buffer);
    try std.testing.expect(std.mem.startsWith(u8, overload, "HTTP/1.1 503"));
    released.store(true, .release);
    _ = try client.receive(socket, &buffer);
    try closeSocket(&client, socket);
    const restored = try client.exchange(port, get, &buffer);
    try std.testing.expectEqualStrings("fast", try integration.body(restored));
}

test "shutdown cancels queued callbacks and waits for running callbacks before reclamation" {
    support.lock();
    defer support.unlock();
    reset();
    var server: Server = .{ .route_table = &routes, .blocking_handlers = true, .max_inflight_requests = 3 };
    const port = try server.start();
    var stopped = false;
    defer if (!stopped) server.stop();
    defer released.store(true, .release);
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    for (0..2) |i| {
        const socket = try client.connect(port);
        try client.send(socket, if (i == 0) "POST /slow HTTP/1.1\r\nHost: localhost\r\nX-Retained: still-valid\r\nX-Stream: 1\r\nContent-Length: 7\r\nConnection: close\r\n\r\npayload" else slow_request);
    }
    try waitFor(&started, 2);
    const queued_socket = try client.connect(port);
    try client.send(queued_socket, "GET /queued HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    var buffer: [2048]u8 = undefined;
    const overload = try client.exchange(port, get, &buffer);
    try std.testing.expect(std.mem.startsWith(u8, overload, "HTTP/1.1 503"));
    server.control.close();
    try client.expectDisconnected(queued_socket);
    try std.testing.expect(!server.finished.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), finished.load(.acquire));
    released.store(true, .release);
    server.stop();
    stopped = true;
    try std.testing.expectEqual(@as(u32, 2), finished.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), queued_calls.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), stream_closes.load(.acquire));
    try std.testing.expect(stream_cancelled.load(.acquire));
    try std.testing.expectEqual(null, server.failure);
}

test "worker WebSocket messages retain fragmented payloads and execute in order" {
    support.lock();
    defer support.unlock();
    reset();
    var server: Server = .{ .route_table = &routes, .blocking_handlers = true };
    const port = try server.start();
    defer server.stop();
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    var request: [1024]u8 = undefined;
    @memcpy(request[0..handshake.len], handshake);
    var len = handshake.len;
    len += masked(request[len..], 9, true, "hi");
    len += masked(request[len..], 1, false, "hel");
    len += masked(request[len..], 0, true, "lo");
    len += masked(request[len..], 1, true, "world");
    len += masked(request[len..], 8, true, &.{ 0x03, 0xe8 });
    var buffer: [2048]u8 = undefined;
    const response = try client.exchange(port, request[0..len], &buffer);
    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 101"));
    try std.testing.expectEqualSlices(u8, &.{ 0x8a, 2, 'h', 'i', 0x81, 5, 'h', 'e', 'l', 'l', 'o', 0x81, 5, 'w', 'o', 'r', 'l', 'd', 0x88, 2, 0x03, 0xe8 }, try integration.body(response));
    try std.testing.expectEqual(@as(u32, 2), websocket_calls.load(.acquire));
}

test "WebSocket admission is independent from HTTP and restores after closure" {
    support.lock();
    defer support.unlock();
    reset();
    var server: Server = .{ .route_table = &routes, .max_inflight_requests = 1, .max_websocket_connections = 1 };
    const port = try server.start();
    defer server.stop();
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    const socket = try client.connect(port);
    try client.send(socket, handshake);
    var buffer: [2048]u8 = undefined;
    const first = try readHead(&client, socket, &buffer);
    try std.testing.expect(std.mem.startsWith(u8, first, "HTTP/1.1 101"));
    const overload = try client.exchange(port, handshake, &buffer);
    try std.testing.expect(std.mem.startsWith(u8, overload, "HTTP/1.1 503"));
    const normal = try client.exchange(port, get, &buffer);
    try std.testing.expectEqualStrings("fast", try integration.body(normal));
    var frame: [16]u8 = undefined;
    try client.send(socket, frame[0..masked(&frame, 8, true, &.{ 0x03, 0xe8 })]);
    _ = try client.receive(socket, &buffer);
    try closeSocket(&client, socket);
    var request: [512]u8 = undefined;
    @memcpy(request[0..handshake.len], handshake);
    const len = handshake.len + masked(request[handshake.len..], 8, true, &.{ 0x03, 0xe8 });
    const restored = try client.exchange(port, request[0..len], &buffer);
    try std.testing.expect(std.mem.startsWith(u8, restored, "HTTP/1.1 101"));
}
