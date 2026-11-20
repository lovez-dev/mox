//! Native HTTP exchanges and shutdown behavior through independent I/O loops.

const std = @import("std");
const mox = @import("mox");
const mox_io = @import("mox_io");
const test_options = @import("test_options");
const support = @import("support.zig");

const t = mox_io.types;
const timeout_ns = 5_000_000_000;
var ready_port: std.atomic.Value(u16) = .init(0);
var stream_closes: std.atomic.Value(u32) = .init(0);
var upload_bytes: std.atomic.Value(usize) = .init(0);
var upload_deinits: std.atomic.Value(u32) = .init(0);
var sse_steps: std.atomic.Value(u32) = .init(0);
var disconnect_closes: std.atomic.Value(u32) = .init(0);
var disconnect_completed: std.atomic.Value(bool) = .init(false);
var quiet_sse_calls: std.atomic.Value(u32) = .init(0);
var quiet_sse_completed: std.atomic.Value(u32) = .init(0);

fn quietSseNext(writer: mox.SseWriter) bool {
    _ = quiet_sse_calls.fetchAdd(1, .release);
    writer.setTick(0);
    return true;
}

fn quietSse(_: *mox.Context) anyerror!mox.Response {
    return mox.Response.sse(quietSseNext);
}

fn observe(event: mox.RequestEvent) void {
    if (std.mem.eql(u8, event.path, "/quiet-sse")) _ = quiet_sse_completed.fetchAdd(1, .release);
}

fn wsEcho(conn: mox.WsConn, message: mox.WsMessage) void {
    if (message.opcode == .text) {
        if (std.mem.eql(u8, message.data, "close")) conn.close() else conn.sendText(message.data) catch conn.close();
    }
}

fn websocket(_: *mox.Context) anyerror!mox.Response {
    return mox.Response.upgrade(wsEcho);
}

fn sseNext(writer: mox.SseWriter) bool {
    switch (sse_steps.fetchAdd(1, .acq_rel)) {
        0 => {
            writer.setTick(10);
            return true;
        },
        1 => {
            writer.send("update", "one\ntwo");
            return true;
        },
        else => {
            writer.close();
            return false;
        },
    }
}

fn sse(_: *mox.Context) anyerror!mox.Response {
    return mox.Response.sse(sseNext);
}

fn embeddedFile(_: *mox.Context) anyerror!mox.Response {
    return .{ .file_path = "/asset.txt" };
}

fn diskFile(_: *mox.Context) anyerror!mox.Response {
    return .{ .file_path = "out/integration/disk.txt" };
}

const EndlessStream = struct {
    fn next(_: *anyopaque, writer: *mox.StreamWriter) anyerror!void {
        try writer.writeAll(&@as([16384]u8, @splat('x')));
    }

    fn close(_: *anyopaque, end: mox.Stream.End) void {
        disconnect_completed.store(end == .complete, .release);
        _ = disconnect_closes.fetchAdd(1, .release);
    }
};

fn endless(ctx: *mox.Context) anyerror!mox.Response {
    const state = try ctx.gpa.create(u8);
    state.* = 0;
    return .{ .stream = .{ .state = state, .next = EndlessStream.next, .close = EndlessStream.close } };
}

fn uploadInit(_: *mox.Context) anyerror!?*anyopaque {
    return null;
}

fn uploadChunk(ctx: *mox.Context, _: ?*anyopaque, chunk: []const u8, _: bool) anyerror!void {
    if (!std.mem.eql(u8, ctx.request.header("x-upload") orelse "", "stable-head")) return error.RequestHeadChanged;
    _ = upload_bytes.fetchAdd(chunk.len, .release);
}

fn uploadDeinit(_: *mox.Context, _: ?*anyopaque) void {
    _ = upload_deinits.fetchAdd(1, .release);
}

fn ready(address: t.Address) void {
    ready_port.store(address.port, .release);
}

fn hello(_: *mox.Context) anyerror!mox.Response {
    return .{ .body = "hello" };
}

fn templatePage(ctx: *mox.Context) anyerror!mox.Response {
    const Page = mox.Template("<p>{{ text }}</p>", struct { text: []const u8 });
    return .{ .body = try Page.renderAlloc(ctx.gpa, .{ .text = "<visitor>" }, .{}), .content_type = "text/html; charset=utf-8" };
}

fn templateFailure(ctx: *mox.Context) anyerror!mox.Response {
    const Page = mox.Template("<p>{{ text }}</p>", struct { text: []const u8 });
    return .{ .body = try Page.renderAlloc(ctx.gpa, .{ .text = "\xff" }, .{}), .content_type = "text/html; charset=utf-8" };
}

fn echo(ctx: *mox.Context) anyerror!mox.Response {
    return .{ .body = ctx.body };
}

const StreamState = struct {
    step: u8 = 0,

    fn next(raw: *anyopaque, writer: *mox.StreamWriter) anyerror!void {
        const self: *StreamState = @ptrCast(@alignCast(raw));
        switch (self.step) {
            0 => try writer.writeAll("alpha"),
            1 => try writer.writeAll("beta"),
            else => writer.finish(),
        }
        self.step += 1;
    }

    fn close(_: *anyopaque, _: mox.Stream.End) void {
        _ = stream_closes.fetchAdd(1, .release);
    }
};

fn streaming(ctx: *mox.Context) anyerror!mox.Response {
    const state = try ctx.gpa.create(StreamState);
    state.* = .{};
    return .{ .stream = .{ .state = state, .next = StreamState.next, .close = StreamState.close } };
}

const routes = [_]mox.Route{
    .{ .method = .GET, .path = "/template", .handler = templatePage },
    .{ .method = .GET, .path = "/template-failure", .handler = templateFailure },
    .{ .method = .GET, .path = "/", .handler = hello },
    .{ .method = .POST, .path = "/echo", .handler = echo },
    .{ .method = .GET, .path = "/stream", .handler = streaming },
    .{ .method = .POST, .path = "/upload", .handler = hello, .body_stream_init = uploadInit, .on_body = uploadChunk, .body_stream_deinit = uploadDeinit },
    .{ .method = .GET, .path = "/ws", .handler = websocket },
    .{ .method = .GET, .path = "/sse", .handler = sse },
    .{ .method = .GET, .path = "/embedded", .handler = embeddedFile },
    .{ .method = .GET, .path = "/disk", .handler = diskFile },
    .{ .method = .GET, .path = "/endless", .handler = endless },
    .{ .method = .GET, .path = "/quiet-sse", .handler = quietSse },
};

pub const Server = struct {
    thread: mox_io.sync.Thread = .{},
    control: mox.ServerControl = .{},
    control_override: ?*mox.ServerControl = null,
    finished: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    assets: ?*const mox_io.fs.EmbeddedFs = null,
    idle_timeout_ms: u32 = 2000,
    request_timeout_ms: u32 = 1000,
    route_table: []const mox.Route = &routes,
    blocking_handlers: bool = false,
    max_inflight_requests: usize = 0,
    max_websocket_connections: usize = 256,
    request_arena_retain_bytes: usize = 8 * 1024,
    max_memory_bytes: usize = 256 * 1024 * 1024,
    on_request_complete: ?*const fn (mox.RequestEvent) void = observe,

    fn run(raw: *anyopaque) void {
        const self: *Server = @ptrCast(@alignCast(raw));
        mox.serve(.{
            .gpa = std.testing.allocator,
            .address = t.Address.loopback(0),
            .backend = std.meta.stringToEnum(@FieldType(mox.Config, "backend"), test_options.backend) orelse .default,
            .routes = self.route_table,
            .blocking_handlers = self.blocking_handlers,
            .max_inflight_requests = self.max_inflight_requests,
            .max_websocket_connections = self.max_websocket_connections,
            .request_arena_retain_bytes = self.request_arena_retain_bytes,
            .max_memory_bytes = self.max_memory_bytes,
            .control = self.control_override orelse &self.control,
            .ready = ready,
            .on_request_complete = self.on_request_complete,
            .max_connections = 8,
            .max_body_size = 32,
            .assets = self.assets,
            .idle_timeout_ms = self.idle_timeout_ms,
            .shutdown_timeout_ms = 100,
            .request_timeout_ms = self.request_timeout_ms,
        }) catch |err| {
            self.failure = err;
        };
        self.finished.store(true, .release);
    }

    pub fn start(self: *Server) !u16 {
        ready_port.store(0, .release);
        try self.thread.start(run, self);
        const deadline = mox_io.os.now() + timeout_ns;
        while (ready_port.load(.acquire) == 0) {
            if (self.finished.load(.acquire)) {
                self.thread.join();
                return self.failure orelse error.ServerExited;
            }
            if (mox_io.os.now() >= deadline) {
                self.stop();
                return error.ServerStartTimeout;
            }
            mox_io.sync.Thread.yield();
        }
        return ready_port.load(.acquire);
    }

    // All exits join the worker before its control and allocator leave scope.
    pub fn stop(self: *Server) void {
        self.control.close();
        const deadline = mox_io.os.now() + timeout_ns;
        while (!self.finished.load(.acquire)) {
            if (mox_io.os.now() >= deadline) @panic("server did not stop before the integration deadline");
            mox_io.sync.Thread.yield();
        }
        self.thread.join();
    }
};

pub const Client = struct {
    loop: mox_io.DefaultLoop = undefined,

    pub fn init(self: *Client) !void {
        try self.loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 16, .resources = 8, .file_threads = 0 });
    }

    pub fn deinit(self: *Client) void {
        self.loop.shutdown() catch @panic("client shutdown failed");
        const deadline = self.loop.now() + timeout_ns;
        var output: [16]t.Completion = undefined;
        while (self.loop.stats().active_operations != 0 or self.loop.stats().active_resources != 0) {
            if (self.loop.now() >= deadline) @panic("client cleanup exceeded its deadline");
            _ = self.loop.poll(&output, .{ .until = deadline }) catch @panic("client cleanup failed");
        }
        self.loop.deinit() catch @panic("client deinit failed");
    }

    pub fn one(self: *Client) !t.Completion {
        const deadline = self.loop.now() + timeout_ns;
        var output: [1]t.Completion = undefined;
        while (true) {
            if (self.loop.now() >= deadline) return error.ClientTimeout;
            if (try self.loop.poll(&output, .{ .until = deadline }) != 0) return output[0];
        }
    }

    pub fn connect(self: *Client, port: u16) !t.Handle {
        const socket = try self.loop.openTcp(.ipv4);
        _ = try self.loop.connect(socket, t.Address.loopback(port), .{ .deadline = self.loop.now() + timeout_ns });
        const completion = try self.one();
        if (completion.status != .ok) return error.ConnectFailed;
        return socket;
    }

    pub fn send(self: *Client, socket: t.Handle, request: []const u8) !void {
        _ = try self.loop.sendAll(socket, request, .{ .deadline = self.loop.now() + timeout_ns });
        if ((try self.one()).status != .ok) return error.SendFailed;
    }

    pub fn receive(self: *Client, socket: t.Handle, buffer: []u8) !usize {
        var len: usize = 0;
        while (len < buffer.len) {
            _ = try self.loop.recv(socket, buffer[len..], .{ .deadline = self.loop.now() + timeout_ns });
            const completion = try self.one();
            if (completion.status == .eof or (completion.status == .ok and completion.bytes == 0)) return len;
            if (completion.status != .ok) return error.ReceiveFailed;
            len += completion.bytes;
        }
        return error.ResponseTooLarge;
    }

    pub fn expectDisconnected(self: *Client, socket: t.Handle) !void {
        var buffer: [256]u8 = undefined;
        _ = try self.loop.recv(socket, &buffer, .{ .deadline = self.loop.now() + timeout_ns });
        const completion = try self.one();
        if (completion.status == .eof or (completion.status == .ok and completion.bytes == 0)) return;
        // Closing with unread request bytes can reset TCP instead of sending FIN.
        if (completion.status == .failed and
            (completion.native_error == 104 or completion.native_error == 54 or completion.native_error == 10054 or completion.native_error == 64)) return;
        return error.ExpectedDisconnect;
    }

    pub fn exchange(self: *Client, port: u16, request: []const u8, buffer: []u8) ![]const u8 {
        const socket = try self.connect(port);
        try self.send(socket, request);
        const len = try self.receive(socket, buffer);
        try self.loop.close(socket, .cancel, 0);
        const closed = try self.one();
        if (closed.kind != .close or closed.status != .ok) return error.CloseFailed;
        return buffer[0..len];
    }
};

pub fn body(response: []const u8) ![]const u8 {
    const end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return error.InvalidResponse;
    return response[end + 4 ..];
}

fn expectHeader(response: []const u8, name: []const u8, value: []const u8) !void {
    var lines = std.mem.splitSequence(u8, response, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidResponse;
        if (std.ascii.eqlIgnoreCase(line[0..colon], name)) {
            try std.testing.expectEqualStrings(value, std.mem.trim(u8, line[colon + 1 ..], " \t"));
            return;
        }
    }
    return error.HeaderMissing;
}

test "native HTTP pipeline, HEAD, routing, body limits, and chunked requests" {
    support.lock();
    defer support.unlock();
    var server: Server = .{};
    const port = try server.start();
    defer server.stop();
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    var buffer: [4096]u8 = undefined;

    const pipeline = try client.exchange(port, "GET / HTTP/1.1\r\nHost: localhost\r\n\r\nGET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", &buffer);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, pipeline, "HTTP/1.1 200"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, pipeline, "\r\n\r\nhello"));

    const head = try client.exchange(port, "HEAD / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", &buffer);
    try std.testing.expect(std.mem.startsWith(u8, head, "HTTP/1.1 200"));
    try expectHeader(head, "content-length", "5");
    try std.testing.expectEqual(@as(usize, 0), (try body(head)).len);

    const method = try client.exchange(port, "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", &buffer);
    try std.testing.expect(std.mem.startsWith(u8, method, "HTTP/1.1 405"));
    try expectHeader(method, "allow", "GET, HEAD");

    const oversized = try client.exchange(port, "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 33\r\nConnection: close\r\n\r\n", &buffer);
    try std.testing.expect(std.mem.startsWith(u8, oversized, "HTTP/1.1 413"));

    const chunked = try client.exchange(port, "POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n", &buffer);
    try std.testing.expect(std.mem.startsWith(u8, chunked, "HTTP/1.1 200"));
    try std.testing.expectEqualStrings("hello world", try body(chunked));
}

fn retainedResponse(ctx: *mox.Context) !mox.Response {
    const marker = (ctx.param("marker") orelse return error.MissingMarker)[0];
    const size = try std.fmt.parseInt(usize, ctx.query("size") orelse "0", 10);
    if (size > 32 * 1024) return error.ResponseTooLarge;
    const data = try ctx.gpa.alloc(u8, size);
    @memset(data, marker);
    return .{ .body = data };
}

test "arena-backed pipelined responses survive shrink and keep-alive reuse in both handler modes" {
    support.lock();
    defer support.unlock();
    const table = [_]mox.Route{.{ .method = .GET, .path = "/retained/:marker", .handler = retainedResponse }};
    for ([_]bool{ false, true }) |blocking| {
        for ([_]usize{ 0, 128, 8 * 1024 }) |limit| {
            var server: Server = .{ .route_table = &table, .blocking_handlers = blocking, .request_arena_retain_bytes = limit };
            const port = try server.start();
            defer server.stop();
            var client: Client = .{};
            try client.init();
            defer client.deinit();
            var buffer: [32 * 1024]u8 = undefined;
            const response = try client.exchange(port, "GET /retained/A?size=16384 HTTP/1.1\r\nHost: localhost\r\n\r\n" ++
                "GET /retained/B?size=5 HTTP/1.1\r\nHost: localhost\r\n\r\n" ++
                "GET /retained/C?size=2048 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", &buffer);
            var offset: usize = 0;
            const expected = [_]struct { size: usize, marker: u8 }{ .{ .size = 16384, .marker = 'A' }, .{ .size = 5, .marker = 'B' }, .{ .size = 2048, .marker = 'C' } };
            for (expected) |item| {
                const start = offset;
                const end = (std.mem.indexOfPos(u8, response, start, "\r\n\r\n") orelse return error.MissingResponseHead) + 4;
                try std.testing.expect(std.mem.startsWith(u8, response[start..end], "HTTP/1.1 200"));
                var length: [16]u8 = undefined;
                try expectHeader(response[start..end], "content-length", try std.fmt.bufPrint(&length, "{d}", .{item.size}));
                try std.testing.expect(response.len - end >= item.size);
                for (response[end..][0..item.size]) |byte| try std.testing.expectEqual(item.marker, byte);
                offset = end + item.size;
            }
            try std.testing.expectEqual(response.len, offset);
            try std.testing.expectEqual(null, server.failure);
        }
    }
}

test "template arena output survives transmission and failures precede headers" {
    support.lock();
    defer support.unlock();
    var server: Server = .{};
    const port = try server.start();
    defer server.stop();
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    var buffer: [4096]u8 = undefined;
    const response = try client.exchange(port, "GET /template HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", &buffer);
    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200"));
    try expectHeader(response, "content-type", "text/html; charset=utf-8");
    try std.testing.expectEqualStrings("<p>&lt;visitor&gt;</p>", try body(response));
    const head = try client.exchange(port, "HEAD /template HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", &buffer);
    try expectHeader(head, "content-length", "22");
    try std.testing.expectEqual(@as(usize, 0), (try body(head)).len);
    const failed = try client.exchange(port, "GET /template-failure HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", &buffer);
    try std.testing.expect(std.mem.startsWith(u8, failed, "HTTP/1.1 500"));
    try std.testing.expect(std.mem.indexOf(u8, try body(failed), "<p>") == null);
}

test "stream producer sends framed chunks and closes exactly once" {
    support.lock();
    defer support.unlock();
    stream_closes.store(0, .release);
    var server: Server = .{};
    const port = try server.start();
    defer server.stop();
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    var buffer: [4096]u8 = undefined;
    const response = try client.exchange(port, "GET /stream HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", &buffer);
    try expectHeader(response, "transfer-encoding", "chunked");
    try std.testing.expectEqualStrings("5\r\nalpha\r\n4\r\nbeta\r\n0\r\n\r\n", try body(response));
    try std.testing.expectEqual(@as(u32, 1), stream_closes.load(.acquire));
}

test "shutdown cancels an incomplete client and reaches stopped" {
    support.lock();
    defer support.unlock();
    var server: Server = .{};
    const port = try server.start();
    defer server.stop();
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    const socket = try client.connect(port);
    try client.send(socket, "GET / HTTP/1.1\r\nHost: localhost\r\n");
    server.control.shutdown();
    try client.expectDisconnected(socket);
    const deadline = mox_io.os.now() + timeout_ns;
    while (!server.finished.load(.acquire)) {
        if (mox_io.os.now() >= deadline) return error.ServerShutdownTimeout;
        mox_io.sync.Thread.yield();
    }
    try std.testing.expectEqual(mox.ServerControl.State.stopped, server.control.getState());
    try std.testing.expect(server.failure == null);
}

test "streaming request body keeps its headers stable across receives" {
    support.lock();
    defer support.unlock();
    upload_bytes.store(0, .release);
    upload_deinits.store(0, .release);
    var server: Server = .{};
    const port = try server.start();
    defer server.stop();
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    const socket = try client.connect(port);
    try client.send(socket, "POST /upload HTTP/1.1\r\nHost: localhost\r\nX-Upload: stable-head\r\nContent-Length: 6\r\nConnection: close\r\n\r\nabc");
    const deadline = mox_io.os.now() + timeout_ns;
    while (upload_bytes.load(.acquire) != 3) {
        if (mox_io.os.now() >= deadline) return error.BodyConsumerTimeout;
        mox_io.sync.Thread.yield();
    }
    try client.send(socket, "def");
    var buffer: [1024]u8 = undefined;
    const len = try client.receive(socket, &buffer);
    try std.testing.expect(std.mem.startsWith(u8, buffer[0..len], "HTTP/1.1 200"));
    try std.testing.expectEqual(@as(usize, 6), upload_bytes.load(.acquire));
    // Completion also releases the body consumer exactly once.
    const finish_deadline = mox_io.os.now() + timeout_ns;
    while (upload_deinits.load(.acquire) == 0) {
        if (mox_io.os.now() >= finish_deadline) return error.BodyCleanupTimeout;
        mox_io.sync.Thread.yield();
    }
    try std.testing.expectEqual(@as(u32, 1), upload_deinits.load(.acquire));
}

fn appendMasked(buffer: []u8, opcode: u8, final: bool, payload: []const u8) usize {
    std.debug.assert(payload.len <= 125 and buffer.len >= payload.len + 6);
    const mask = [4]u8{ 0x12, 0x34, 0x56, 0x78 };
    buffer[0] = opcode | (if (final) @as(u8, 0x80) else 0);
    buffer[1] = 0x80 | @as(u8, @intCast(payload.len));
    @memcpy(buffer[2..6], &mask);
    for (payload, 0..) |byte, i| buffer[6 + i] = byte ^ mask[i % 4];
    return payload.len + 6;
}

test "WebSocket upgrade handles masked ping and fragmented text" {
    support.lock();
    defer support.unlock();
    var server: Server = .{};
    const port = try server.start();
    defer server.stop();
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    var request: [1024]u8 = undefined;
    const handshake = "GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n";
    @memcpy(request[0..handshake.len], handshake);
    var len = handshake.len;
    len += appendMasked(request[len..], 0x9, true, "hi");
    len += appendMasked(request[len..], 0x1, false, "hel");
    len += appendMasked(request[len..], 0x0, true, "lo");
    len += appendMasked(request[len..], 0x8, true, &.{ 0x03, 0xe8 });
    var buffer: [4096]u8 = undefined;
    const response = try client.exchange(port, request[0..len], &buffer);
    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 101"));
    try expectHeader(response, "sec-websocket-accept", "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
    try std.testing.expectEqualSlices(u8, &.{ 0x8a, 2, 'h', 'i', 0x81, 5, 'h', 'e', 'l', 'l', 'o', 0x88, 2, 0x03, 0xe8 }, try body(response));
}

test "server WebSocket close waits for the peer acknowledgement" {
    support.lock();
    defer support.unlock();
    var server: Server = .{};
    const port = try server.start();
    defer server.stop();
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    const socket = try client.connect(port);
    try client.send(socket, "GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n");
    var response: [1024]u8 = undefined;
    var len: usize = 0;
    while (std.mem.indexOf(u8, response[0..len], "\r\n\r\n") == null) {
        _ = try client.loop.recv(socket, response[len..], .{ .deadline = client.loop.now() + timeout_ns });
        const result = try client.one();
        try std.testing.expectEqual(t.Status.ok, result.status);
        len += result.bytes;
    }
    try std.testing.expect(std.mem.startsWith(u8, response[0..len], "HTTP/1.1 101"));
    var frame: [128]u8 = undefined;
    const count = appendMasked(&frame, 0x1, true, "close");
    try client.send(socket, frame[0..count]);
    var close_frame: [4]u8 = undefined;
    _ = try client.loop.recvExact(socket, &close_frame, .{ .deadline = client.loop.now() + timeout_ns });
    const close_result = try client.one();
    try std.testing.expectEqual(t.Status.ok, close_result.status);
    try std.testing.expectEqualSlices(u8, &.{ 0x88, 2, 0x03, 0xe8 }, &close_frame);
    // Leave a read pending: the server must retain the transport until the peer replies.
    var tail: [64]u8 = undefined;
    _ = try client.loop.recv(socket, &tail, .{ .deadline = client.loop.now() + timeout_ns, .tag = 100 });
    var completions: [1]t.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try client.loop.poll(&completions, .{ .until = client.loop.now() + 30_000_000 }));
    const ack = appendMasked(&frame, 0x8, true, &.{ 0x03, 0xe8 });
    _ = try client.loop.sendAll(socket, frame[0..ack], .{ .deadline = client.loop.now() + timeout_ns, .tag = 101 });
    var sent = false;
    var ended = false;
    while (!sent or !ended) {
        const completion = try client.one();
        if (completion.tag == 101) {
            try std.testing.expectEqual(t.Status.ok, completion.status);
            sent = true;
        } else {
            // A second close frame would produce data here instead of EOF.
            try std.testing.expect(completion.status == .eof or (completion.status == .ok and completion.bytes == 0));
            ended = true;
        }
    }
}

test "SSE timer emits a multiline event and terminates chunks" {
    support.lock();
    defer support.unlock();
    sse_steps.store(0, .release);
    var server: Server = .{};
    const port = try server.start();
    defer server.stop();
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    var buffer: [4096]u8 = undefined;
    const response = try client.exchange(port, "GET /sse HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", &buffer);
    try expectHeader(response, "content-type", "text/event-stream");
    try expectHeader(response, "transfer-encoding", "chunked");
    const framed = try body(response);
    try std.testing.expect(std.mem.indexOf(u8, framed, "event: update\r\ndata: one\r\ndata: two\r\n\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, framed, "0\r\n\r\n"));
    try std.testing.expectEqual(@as(u32, 3), sse_steps.load(.acquire));
}

fn imageWithFile(comptime name: []const u8, comptime data: []const u8) [80 + name.len + data.len]u8 {
    const image = mox_io.fs.image;
    var bytes: [80 + name.len + data.len]u8 = @splat(0);
    @memcpy(bytes[0..8], image.magic);
    image.write(u32, bytes[8..12], image.version);
    image.write(u32, bytes[12..16], image.entry_size);
    image.write(u64, bytes[16..24], 1);
    image.write(u64, bytes[24..32], name.len);
    image.write(u64, bytes[32..40], data.len);
    image.write(u32, bytes[48..52], name.len);
    image.write(u64, bytes[64..72], data.len);
    image.write(u64, bytes[72..80], image.root_parent);
    @memcpy(bytes[80..][0..name.len], name);
    @memcpy(bytes[80 + name.len ..], data);
    return bytes;
}

test "file responses read embedded assets and fall back to disk" {
    support.lock();
    defer support.unlock();
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(std.testing.io, "out/integration");
    defer cwd.deleteDir(std.testing.io, "out/integration") catch {};
    try cwd.writeFile(std.testing.io, .{ .sub_path = "out/integration/disk.txt", .data = "disk content" });
    defer cwd.deleteFile(std.testing.io, "out/integration/disk.txt") catch {};
    const image = comptime imageWithFile("asset.txt", "embedded content");
    const assets = try mox_io.fs.EmbeddedFs.init(&image);
    var server: Server = .{ .assets = &assets };
    const port = try server.start();
    defer server.stop();
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    var buffer: [4096]u8 = undefined;
    const embedded = try client.exchange(port, "GET /embedded HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", &buffer);
    try std.testing.expectEqualStrings("embedded content", try body(embedded));
    const disk = try client.exchange(port, "GET /disk HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", &buffer);
    try std.testing.expectEqualStrings("disk content", try body(disk));
    const head = try client.exchange(port, "HEAD /disk HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", &buffer);
    try expectHeader(head, "content-length", "12");
    try std.testing.expectEqual(@as(usize, 0), (try body(head)).len);
}

test "idle and request deadlines close stalled clients" {
    support.lock();
    defer support.unlock();
    var server: Server = .{ .idle_timeout_ms = 50, .request_timeout_ms = 50 };
    const port = try server.start();
    defer server.stop();
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    var buffer: [1024]u8 = undefined;
    const idle = try client.connect(port);
    try std.testing.expectEqual(@as(usize, 0), try client.receive(idle, &buffer));
    const incomplete = try client.connect(port);
    try client.send(incomplete, "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\na");
    try client.expectDisconnected(incomplete);
}

test "disconnecting a response stream releases its state exactly once" {
    support.lock();
    defer support.unlock();
    disconnect_closes.store(0, .release);
    disconnect_completed.store(false, .release);
    var server: Server = .{};
    const port = try server.start();
    defer server.stop();
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    const socket = try client.connect(port);
    try client.send(socket, "GET /endless HTTP/1.1\r\nHost: localhost\r\n\r\n");
    var buffer: [256]u8 = undefined;
    _ = try client.loop.recv(socket, &buffer, .{ .deadline = client.loop.now() + timeout_ns });
    try std.testing.expectEqual(t.Status.ok, (try client.one()).status);
    try client.loop.close(socket, .cancel, 0);
    try std.testing.expectEqual(t.Kind.close, (try client.one()).kind);
    const deadline = mox_io.os.now() + timeout_ns;
    while (disconnect_closes.load(.acquire) == 0) {
        if (mox_io.os.now() >= deadline) return error.StreamCleanupTimeout;
        mox_io.sync.Thread.yield();
    }
    try std.testing.expectEqual(@as(u32, 1), disconnect_closes.load(.acquire));
    try std.testing.expect(!disconnect_completed.load(.acquire));
}

test "idle SSE notices peer disconnect without an output timer" {
    support.lock();
    defer support.unlock();
    quiet_sse_calls.store(0, .release);
    quiet_sse_completed.store(0, .release);
    var server: Server = .{};
    const port = try server.start();
    defer server.stop();
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    const socket = try client.connect(port);
    try client.send(socket, "GET /quiet-sse HTTP/1.1\r\nHost: localhost\r\n\r\n");
    var buffer: [1024]u8 = undefined;
    _ = try client.loop.recv(socket, &buffer, .{ .deadline = client.loop.now() + timeout_ns });
    try std.testing.expectEqual(t.Status.ok, (try client.one()).status);
    const begin = mox_io.os.now() + timeout_ns;
    while (quiet_sse_calls.load(.acquire) == 0) {
        if (mox_io.os.now() >= begin) return error.SseStartTimeout;
        mox_io.sync.Thread.yield();
    }
    try client.loop.close(socket, .cancel, 0);
    try std.testing.expectEqual(t.Kind.close, (try client.one()).kind);
    const deadline = mox_io.os.now() + timeout_ns;
    while (quiet_sse_completed.load(.acquire) == 0) {
        if (mox_io.os.now() >= deadline) return error.SseDisconnectTimeout;
        mox_io.sync.Thread.yield();
    }
    try std.testing.expectEqual(@as(u32, 1), quiet_sse_calls.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), quiet_sse_completed.load(.acquire));
}

test "server control rejects a concurrent serve loop" {
    support.lock();
    defer support.unlock();
    var first: Server = .{};
    _ = try first.start();
    defer first.stop();
    var second = Server{ .control_override = &first.control };
    try std.testing.expectError(error.ControlAlreadyUsed, second.start());
    try std.testing.expectEqual(mox.ServerControl.State.running, first.control.getState());
    try std.testing.expect(second.finished.load(.acquire));
}

test "request deadline is absolute while the client trickles header bytes" {
    support.lock();
    defer support.unlock();
    var server: Server = .{ .request_timeout_ms = 300 };
    const port = try server.start();
    defer server.stop();
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    const socket = try client.connect(port);
    try client.send(socket, "GET / HTTP/1.1\r\nHost: localhost\r\nX-Slow: ");
    const started = mox_io.os.now();
    while (mox_io.os.now() - started < 200_000_000) {
        var output: [1]t.Completion = undefined;
        if (try client.loop.poll(&output, .{ .until = @min(client.loop.now() + 2_000_000, started + 200_000_000) }) != 0) return error.RequestExpiredTooSoon;
    }
    try client.send(socket, "still-open\r\n");
    try client.expectDisconnected(socket);
    // Resetting the deadline on the second receive would extend this to 500ms.
    try std.testing.expect(mox_io.os.now() - started < 450_000_000);
}

test {
    _ = @import("proxy.zig");
    _ = @import("workers.zig");
}
