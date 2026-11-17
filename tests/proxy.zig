//! Real upstream connections exercise proxy framing, limits and failure responses.

const std = @import("std");
const mox = @import("mox");
const io = @import("mox_io");
const options = @import("test_options");
const support = @import("support.zig");
const timeout_ns = 5_000_000_000;
var ports: [4][2]std.atomic.Value(u16) = .{
    .{ .init(0), .init(0) },
    .{ .init(0), .init(0) },
    .{ .init(0), .init(0) },
    .{ .init(0), .init(0) },
};

const Client = struct {
    loop: io.DefaultLoop = undefined,

    fn init(self: *Client) !void {
        try self.loop.init(io.mem.PageAllocator.allocator(), .{ .operations = 16, .resources = 8, .file_threads = 0 });
    }

    fn deinit(self: *Client) void {
        self.loop.shutdown() catch @panic("proxy client shutdown failed");
        const deadline = self.loop.now() + timeout_ns;
        var output: [16]io.types.Completion = undefined;
        while (self.loop.stats().active_operations != 0 or self.loop.stats().active_resources != 0) {
            if (self.loop.now() >= deadline) @panic("proxy client cleanup exceeded its deadline");
            _ = self.loop.poll(&output, .{ .until = deadline }) catch @panic("proxy client cleanup failed");
        }
        self.loop.deinit() catch @panic("proxy client deinit failed");
    }

    fn one(self: *Client) !io.types.Completion {
        const deadline = self.loop.now() + timeout_ns;
        var output: [1]io.types.Completion = undefined;
        while (true) {
            if (self.loop.now() >= deadline) return error.ClientTimeout;
            if (try self.loop.poll(&output, .{ .until = deadline }) != 0) return output[0];
        }
    }

    fn exchange(self: *Client, port: u16, request: []const u8, buffer: []u8) ![]const u8 {
        const socket = try self.loop.openTcp(.ipv4);
        _ = try self.loop.connect(socket, io.types.Address.loopback(port), .{ .deadline = self.loop.now() + timeout_ns });
        if ((try self.one()).status != .ok) return error.ConnectFailed;
        _ = try self.loop.sendAll(socket, request, .{ .deadline = self.loop.now() + timeout_ns });
        if ((try self.one()).status != .ok) return error.SendFailed;
        var length: usize = 0;
        while (length < buffer.len) {
            _ = try self.loop.recv(socket, buffer[length..], .{ .deadline = self.loop.now() + timeout_ns });
            const result = try self.one();
            if (result.status == .eof or (result.status == .ok and result.bytes == 0)) break;
            if (result.status != .ok) return error.ReceiveFailed;
            length += result.bytes;
        }
        if (length == buffer.len) return error.ResponseTooLarge;
        try self.loop.close(socket, .cancel, 0);
        const closed = try self.one();
        if (closed.kind != .close or closed.status != .ok) return error.CloseFailed;
        return buffer[0..length];
    }
};

fn responseBody(response: []const u8) ![]const u8 {
    const end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return error.InvalidResponse;
    return response[end + 4 ..];
}

fn Server(comptime test_id: usize, comptime upstream: bool) type {
    return struct {
        const Self = @This();

        thread: io.sync.Thread = .{},
        control: mox.ServerControl = .{},
        finished: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,
        routes: []const mox.Route,

        fn ready(address: io.types.Address) void {
            ports[test_id][@intFromBool(upstream)].store(address.port, .release);
        }

        fn run(raw: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(raw));
            mox.serve(.{
                .gpa = std.testing.allocator,
                .address = io.types.Address.loopback(0),
                .backend = std.meta.stringToEnum(@FieldType(mox.Config, "backend"), options.backend) orelse .default,
                .routes = self.routes,
                .control = &self.control,
                .ready = ready,
                .max_connections = 4,
                .shutdown_timeout_ms = 50,
                .request_timeout_ms = 10_000,
            }) catch |err| {
                self.failure = err;
            };
            self.finished.store(true, .release);
        }

        fn start(self: *Self) !u16 {
            const port = &ports[test_id][@intFromBool(upstream)];
            port.store(0, .release);
            try self.thread.start(run, self);
            errdefer self.stop();
            const deadline = io.os.now() + timeout_ns;
            while (port.load(.acquire) == 0) {
                if (self.finished.load(.acquire)) return self.failure orelse error.ServerExited;
                if (io.os.now() >= deadline) return error.ServerStartTimeout;
                io.sync.Thread.yield();
            }
            return port.load(.acquire);
        }

        fn stop(self: *Self) void {
            self.control.close();
            const deadline = io.os.now() + timeout_ns;
            while (!self.finished.load(.acquire)) {
                if (io.os.now() >= deadline) @panic("proxy test server did not stop");
                io.sync.Thread.yield();
            }
            self.thread.join();
        }
    };
}

fn echo(ctx: *mox.Context) !mox.Response {
    if (ctx.request.header("x-hop") != null or ctx.request.header("transfer-encoding") != null) return error.HopHeaderLeaked;
    if (!std.mem.eql(u8, ctx.request.header("host") orelse "", "example.com")) return error.HostChanged;
    const length = try std.fmt.parseInt(usize, ctx.request.header("content-length") orelse return error.LengthMissing, 10);
    if (length != ctx.body.len) return error.WrongLength;
    return .{ .body = ctx.body };
}

fn large(_: *mox.Context) !mox.Response {
    return .{ .body = &@as([1024]u8, @splat('x')) };
}

fn wait(writer: mox.SseWriter) bool {
    writer.setTick(10);
    return true;
}

fn stalled(_: *mox.Context) !mox.Response {
    // Headers arrive, but the terminating chunk never does before the proxy deadline.
    return mox.Response.sse(wait);
}

test "proxy forwards fixed-length and decoded chunked uploads without hop fields" {
    support.lock();
    defer support.unlock();
    const routes = [_]mox.Route{.{ .method = .POST, .path = "/upload", .handler = echo }};
    var upstream: Server(0, true) = .{ .routes = &routes };
    const upstream_address = io.types.Address.loopback(try upstream.start());
    defer upstream.stop();
    const proxy_routes = [_]mox.Route{mox.proxyRoute(.POST, "/upload", .{ .address = upstream_address })};
    var frontend: Server(0, false) = .{ .routes = &proxy_routes };
    const port = try frontend.start();
    defer frontend.stop();
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    var buffer: [4096]u8 = undefined;

    const fixed = try client.exchange(port, "POST /upload HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\nConnection: close, X-Hop\r\nX-Hop: private\r\n\r\nhello", &buffer);
    try std.testing.expect(std.mem.startsWith(u8, fixed, "HTTP/1.1 200"));
    try std.testing.expectEqualStrings("hello", try responseBody(fixed));

    const chunked = try client.exchange(port, "POST /upload HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\nConnection: close, X-Hop\r\nX-Hop: private\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n", &buffer);
    try std.testing.expect(std.mem.startsWith(u8, chunked, "HTTP/1.1 200"));
    try std.testing.expectEqualStrings("hello world", try responseBody(chunked));
}

test "proxy maps an unavailable upstream to 502" {
    support.lock();
    defer support.unlock();
    var reserved: Server(1, true) = .{ .routes = &.{} };
    const address = io.types.Address.loopback(try reserved.start());
    const routes = [_]mox.Route{mox.proxyRoute(.GET, "/", .{ .address = address, .timeout_ms = 4000 })};
    var frontend: Server(1, false) = .{ .routes = &routes };
    const port = try frontend.start();
    reserved.stop();
    defer frontend.stop();
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    var buffer: [4096]u8 = undefined;
    const response = try client.exchange(port, "GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n", &buffer);
    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 502"));
}

test "proxy rejects an upstream response beyond its byte limit" {
    support.lock();
    defer support.unlock();
    const routes = [_]mox.Route{.{ .method = .GET, .path = "/", .handler = large }};
    var upstream: Server(2, true) = .{ .routes = &routes };
    const address = io.types.Address.loopback(try upstream.start());
    defer upstream.stop();
    const proxy_routes = [_]mox.Route{mox.proxyRoute(.GET, "/", .{ .address = address, .max_response_bytes = 256 })};
    var frontend: Server(2, false) = .{ .routes = &proxy_routes };
    const port = try frontend.start();
    defer frontend.stop();
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    var buffer: [4096]u8 = undefined;
    const response = try client.exchange(port, "GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n", &buffer);
    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 502"));
    try std.testing.expect(std.mem.indexOf(u8, response, "HTTP/1.1 200") == null);
}

test "proxy applies its deadline while an upstream body remains incomplete" {
    support.lock();
    defer support.unlock();
    const routes = [_]mox.Route{.{ .method = .GET, .path = "/", .handler = stalled }};
    var upstream: Server(3, true) = .{ .routes = &routes };
    const address = io.types.Address.loopback(try upstream.start());
    defer upstream.stop();
    const proxy_routes = [_]mox.Route{mox.proxyRoute(.GET, "/", .{ .address = address, .timeout_ms = 50 })};
    var frontend: Server(3, false) = .{ .routes = &proxy_routes };
    const port = try frontend.start();
    defer frontend.stop();
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    var buffer: [4096]u8 = undefined;
    const response = try client.exchange(port, "GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n", &buffer);
    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 504"));
}
