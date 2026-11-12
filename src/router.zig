const std = @import("std");

const Handler = @import("types.zig").Handler;

pub const Params = @import("types.zig").Params;
pub const Route = @import("types.zig").Route;

const Entry = struct { method: std.http.Method, handler: Handler };

const Node = struct {
    /// 字面量段；根节点与参数节点为空。
    segment: []const u8 = "",
    /// 非 null 时表示本节点吞掉任意单个段并绑定它。
    param_name: ?[]const u8 = null,
    /// 非 null 时表示本节点吞掉路径剩余部分（`*name`）。
    wildcard_name: ?[]const u8 = null,
    children: std.ArrayList(*Node) = .empty,
    entries: std.ArrayList(Entry) = .empty,
};

const max_segments = 32;

/// 按路径段组织的前缀树，思路同 gin 的路由器。
///
/// `/users/:id` 恰好捕获一个段；`/static/*filepath`（必须是
/// 路由的最后一段）捕获剩余全部，包括
/// 开头的斜杠，故 `/static/css/app.css` 得到 `/css/app.css`。
///
/// 匹配优先级：字面量段 > 单段参数 > 通配符。
/// 建树只在启动时做一次；路由表里的字符串是借用的，
/// 因此路由表必须比路由器活得更久。
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
        return search(self.root, splitPath(target, &buffer), target, method, params);
    }
};

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
        // 通配符会吞掉其后全部内容，后面不能再有段。
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

    try node.entries.append(gpa, .{ .method = route.method, .handler = route.handler });
}

fn search(
    node: *Node,
    segments: []const []const u8,
    target: []const u8,
    method: std.http.Method,
    params: *Params,
) ?Handler {
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

fn entryAt(node: *Node, method: std.http.Method) ?Handler {
    for (node.entries.items) |entry| {
        if (entry.method == method) return entry.handler;
    }
    // HEAD 语义（RFC 9110 §9.3.2）：服务器收到 HEAD 时应该返回与 GET
    // 相同的响应头、但不带响应体。这里在路由层回退到 GET handler，
    // 响应体的抑制由 server 的 respond() 负责，避免每个 handler 都写一遍。
    if (method == .HEAD) {
        for (node.entries.items) |entry| {
            if (entry.method == .GET) return entry.handler;
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

    // 字面量兄弟节点仍须优先于参数节点，且
    // 失败分支留下的部分捕获不能泄漏出去。
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
    // 光有前缀不算匹配：通配符需要有一个段可吞。
    try std.testing.expectEqual(@as(?Handler, null), router.match(.GET, "/static", &bare));

    // 在适用的地方，字面量兄弟节点仍然优先。
    var sibling: Params = .{};
    try std.testing.expectEqual(@as(?Handler, probe), router.match(.GET, "/users/me", &sibling));
}
