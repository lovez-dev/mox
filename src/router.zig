//! Method-aware path routing with literal, parameter, and wildcard segments.

const std = @import("std");

const Handler = @import("types.zig").Handler;
const BodyChunkHandler = @import("types.zig").BodyChunkHandler;
const BodyStreamInit = @import("types.zig").BodyStreamInit;
const BodyStreamDeinit = @import("types.zig").BodyStreamDeinit;
const ProxyOptions = @import("types.zig").ProxyOptions;

pub const Params = @import("types.zig").Params;
pub const Route = @import("types.zig").Route;

pub const Entry = struct {
    method: std.http.Method,
    handler: Handler,
    on_body: ?BodyChunkHandler = null,
    body_stream_init: ?BodyStreamInit = null,
    body_stream_deinit: ?BodyStreamDeinit = null,
    proxy: ?ProxyOptions = null,
};

const Node = struct {
    /// Literal segment; empty for the root and parameter nodes.
    segment: []const u8 = "",
    /// Capture exactly one path segment.
    param_name: ?[]const u8 = null,
    /// Capture the remaining path for a trailing `*name` segment.
    wildcard_name: ?[]const u8 = null,
    children: std.ArrayList(*Node) = .empty,
    entries: std.ArrayList(Entry) = .empty,
};

const max_segments = 32;

/// Built once at startup; route strings must remain valid until deinit().
/// Match precedence is literal, parameter, then wildcard. A trailing wildcard
/// includes the leading slash: `/static/*path` captures `/css/app.css`.
pub const Router = struct {
    gpa: std.mem.Allocator,
    root: *Node,

    pub fn init(gpa: std.mem.Allocator, routes: []const Route) !Router {
        const root = try gpa.create(Node);
        root.* = .{};
        errdefer destroy(gpa, root);
        for (routes) |route| try insert(gpa, root, route);
        return .{ .gpa = gpa, .root = root };
    }

    pub fn deinit(self: *Router) void {
        destroy(self.gpa, self.root);
        self.* = undefined;
    }

    pub fn match(
        self: *const Router,
        method: std.http.Method,
        target: []const u8,
        params: *Params,
    ) ?Handler {
        var buffer: [max_segments][]const u8 = undefined;
        return (search(self.root, splitPath(target, &buffer), target, method, params) orelse return null).handler;
    }

    pub fn matchBody(
        self: *const Router,
        method: std.http.Method,
        target: []const u8,
        params: *Params,
    ) ?BodyChunkHandler {
        var buffer: [max_segments][]const u8 = undefined;
        const entry = search(self.root, splitPath(target, &buffer), target, method, params) orelse return null;
        return entry.on_body;
    }

    pub fn matchEntry(self: *const Router, method: std.http.Method, target: []const u8, params: *Params) ?Entry {
        var buffer: [max_segments][]const u8 = undefined;
        return search(self.root, splitPath(target, &buffer), target, method, params);
    }

    /// Collect methods registered for a path. GET also permits HEAD.
    pub fn allowedMethods(self: *const Router, target: []const u8, out: []std.http.Method) usize {
        var buffer: [max_segments][]const u8 = undefined;
        const node = searchPath(self.root, splitPath(target, &buffer), target) orelse return 0;
        var count: usize = 0;
        for (node.entries.items) |entry| {
            appendMethod(out, &count, entry.method);
            if (entry.method == .GET) appendMethod(out, &count, .HEAD);
        }
        return count;
    }
};

fn appendMethod(out: []std.http.Method, count: *usize, method: std.http.Method) void {
    for (out[0..count.*]) |existing| if (existing == method) return;
    if (count.* < out.len) {
        out[count.*] = method;
        count.* += 1;
    }
}

fn searchPath(node: *Node, segments: []const []const u8, target: []const u8) ?*Node {
    if (segments.len == 0) return if (node.entries.items.len > 0) node else null;
    const segment = segments[0];
    for (node.children.items) |child| {
        if (child.param_name != null or child.wildcard_name != null) continue;
        if (std.mem.eql(u8, child.segment, segment)) {
            if (searchPath(child, segments[1..], target)) |found| return found;
        }
    }
    for (node.children.items) |child| {
        if (child.param_name != null) {
            if (searchPath(child, segments[1..], target)) |found| return found;
        }
    }
    for (node.children.items) |child| {
        if (child.wildcard_name != null) {
            const offset = @intFromPtr(segment.ptr) - @intFromPtr(target.ptr);
            if (offset != 0 and child.entries.items.len > 0) return child;
        }
    }
    return null;
}

fn splitPath(path: []const u8, buffer: *[max_segments][]const u8) []const []const u8 {
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (n == buffer.len) break;
        buffer[n] = segment;
        n += 1;
    }
    return buffer[0..n];
}

fn insert(gpa: std.mem.Allocator, root: *Node, route: Route) !void {
    var buffer: [max_segments][]const u8 = undefined;
    var node = root;

    for (splitPath(route.path, &buffer)) |segment| {
        // A wildcard consumes the remainder and must be the final segment.
        if (segment.len > 1 and segment[0] == '*') {
            const child = try gpa.create(Node);
            child.* = .{ .wildcard_name = segment[1..] };
            try node.children.append(gpa, child);
            node = child;
            break;
        }

        const is_param = segment.len > 1 and segment[0] == ':';
        var found: ?*Node = null;

        for (node.children.items) |child| {
            const hit = if (is_param)
                child.param_name != null and std.mem.eql(u8, child.param_name.?, segment[1..])
            else
                child.param_name == null and child.wildcard_name == null and
                    std.mem.eql(u8, child.segment, segment);
            if (hit) {
                found = child;
                break;
            }
        }

        if (found) |existing| {
            node = existing;
            continue;
        }

        const child = try gpa.create(Node);
        child.* = if (is_param) .{ .param_name = segment[1..] } else .{ .segment = segment };
        try node.children.append(gpa, child);
        node = child;
    }

    try node.entries.append(gpa, .{
        .method = route.method,
        .handler = route.handler,
        .on_body = route.on_body,
        .body_stream_init = route.body_stream_init,
        .body_stream_deinit = route.body_stream_deinit,
        .proxy = route.proxy,
    });
}

fn search(
    node: *Node,
    segments: []const []const u8,
    target: []const u8,
    method: std.http.Method,
    params: *Params,
) ?Entry {
    if (segments.len == 0) return entryAt(node, method);

    const segment = segments[0];

    for (node.children.items) |child| {
        if (child.param_name != null or child.wildcard_name != null) continue;
        if (std.mem.eql(u8, child.segment, segment)) {
            if (search(child, segments[1..], target, method, params)) |handler| return handler;
        }
    }

    for (node.children.items) |child| {
        if (child.param_name) |name| {
            const saved = params.len;
            if (params.push(name, segment)) {
                if (search(child, segments[1..], target, method, params)) |handler| {
                    return handler;
                }
            }
            params.len = saved;
        }
    }

    for (node.children.items) |child| {
        if (child.wildcard_name) |name| {
            const offset = @intFromPtr(segment.ptr) - @intFromPtr(target.ptr);
            if (offset == 0) continue;
            const saved = params.len;
            if (params.push(name, target[offset - 1 ..])) {
                if (entryAt(child, method)) |handler| return handler;
            }
            params.len = saved;
        }
    }

    return null;
}

fn entryAt(node: *Node, method: std.http.Method) ?Entry {
    for (node.entries.items) |entry| {
        if (entry.method == method) return entry;
    }
    // Fall back from HEAD to GET; response serialization suppresses the body.
    if (method == .HEAD) {
        for (node.entries.items) |entry| {
            if (entry.method == .GET) return entry;
        }
    }
    return null;
}

fn destroy(gpa: std.mem.Allocator, node: *Node) void {
    for (node.children.items) |child| destroy(gpa, child);
    node.children.deinit(gpa);
    node.entries.deinit(gpa);
    gpa.destroy(node);
}

fn probe(ctx: *@import("types.zig").Context) anyerror!@import("types.zig").Response {
    _ = ctx;
    return .{ .body = "ok\n" };
}

test "literal routes match, wrong method does not" {
    const gpa = std.testing.allocator;
    var router = try Router.init(gpa, &.{
        .{ .method = .GET, .path = "/", .handler = probe },
        .{ .method = .POST, .path = "/things", .handler = probe },
    });
    defer router.deinit();

    var params: Params = .{};
    try std.testing.expectEqual(@as(?Handler, probe), router.match(.GET, "/", &params));
    try std.testing.expectEqual(@as(?Handler, probe), router.match(.POST, "/things", &params));
    try std.testing.expectEqual(@as(?Handler, null), router.match(.GET, "/things", &params));
    try std.testing.expectEqual(@as(?Handler, null), router.match(.GET, "/missing", &params));
    var allowed: [8]std.http.Method = undefined;
    const count = router.allowedMethods("/things", &allowed);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(std.http.Method.POST, allowed[0]);
    try std.testing.expectEqual(@as(usize, 0), router.allowedMethods("/missing", &allowed));
}

test "allowed methods include HEAD for GET parameter routes" {
    var router = try Router.init(std.testing.allocator, &.{
        .{ .method = .GET, .path = "/users/:id", .handler = probe },
        .{ .method = .DELETE, .path = "/users/:id", .handler = probe },
    });
    defer router.deinit();
    var allowed: [8]std.http.Method = undefined;
    const count = router.allowedMethods("/users/42", &allowed);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(std.http.Method.GET, allowed[0]);
    try std.testing.expectEqual(std.http.Method.HEAD, allowed[1]);
    try std.testing.expectEqual(std.http.Method.DELETE, allowed[2]);
}

test "path parameters are captured and restored between attempts" {
    const gpa = std.testing.allocator;
    var router = try Router.init(gpa, &.{
        .{ .method = .GET, .path = "/users/:id/posts/:post", .handler = probe },
        .{ .method = .GET, .path = "/users/me", .handler = probe },
    });
    defer router.deinit();

    var params: Params = .{};
    try std.testing.expectEqual(
        @as(?Handler, probe),
        router.match(.GET, "/users/42/posts/7", &params),
    );
    try std.testing.expectEqualStrings("42", params.get("id").?);
    try std.testing.expectEqualStrings("7", params.get("post").?);

    // Prefer literal siblings and discard captures from failed branches.
    var second: Params = .{};
    try std.testing.expectEqual(@as(?Handler, probe), router.match(.GET, "/users/me", &second));
    try std.testing.expectEqual(@as(usize, 0), second.len);
}

test "catch-all captures the remainder with a leading slash" {
    const gpa = std.testing.allocator;
    var router = try Router.init(gpa, &.{
        .{ .method = .GET, .path = "/static/*filepath", .handler = probe },
        .{ .method = .GET, .path = "/users/me", .handler = probe },
    });
    defer router.deinit();

    var params: Params = .{};
    try std.testing.expectEqual(
        @as(?Handler, probe),
        router.match(.GET, "/static/css/app.css", &params),
    );
    try std.testing.expectEqualStrings("/css/app.css", params.get("filepath").?);

    var bare: Params = .{};
    // A wildcard needs a remaining segment, not just its literal prefix.
    try std.testing.expectEqual(@as(?Handler, null), router.match(.GET, "/static", &bare));

    // Literal siblings retain precedence.
    var sibling: Params = .{};
    try std.testing.expectEqual(@as(?Handler, probe), router.match(.GET, "/users/me", &sibling));
}
