//! Local task board. State is bounded, process-local, and reset on restart.
const std = @import("std");
const mox = @import("mox");
const board = @import("app.zig");
var app: board.App = undefined;

fn action(comptime endpoint: board.Endpoint) mox.Handler {
    return struct {
        fn handle(ctx: *mox.Context) !mox.Response {
            const result = try app.handle(ctx.gpa, endpoint, ctx.param("id"), ctx.body, ctx.request.header("content-type"));
            return .{ .status = result.status, .body = result.body, .content_type = result.content_type };
        }
    }.handle;
}

fn failure(_: *mox.Context, _: anyerror) mox.Response {
    return .{ .status = .internal_server_error, .content_type = "application/json", .body = "{\"error\":\"Internal server error\"}" };
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 2) return error.InvalidArguments;
    const port = if (args.len == 2) try std.fmt.parseInt(u16, args[1], 10) else 8080;
    if (port == 0) return error.InvalidPort;
    app = board.App.init();
    try mox.serve(.{
        .gpa = std.heap.page_allocator,
        .address = mox.io.types.Address.loopback(port),
        .max_body_size = 2048,
        .max_inflight_requests = 256,
        .max_memory_bytes = 128 * 1024 * 1024,
        .error_handler = failure,
        .routes = &.{
            .{ .method = .GET, .path = "/", .handler = action(.home) },
            .{ .method = .GET, .path = "/board.js", .handler = action(.script) },
            .{ .method = .GET, .path = "/board.css", .handler = action(.stylesheet) },
            .{ .method = .GET, .path = "/health", .handler = action(.health) },
            .{ .method = .GET, .path = "/api/tasks", .handler = action(.list) },
            .{ .method = .GET, .path = "/api/tasks/:id", .handler = action(.detail) },
            .{ .method = .POST, .path = "/api/tasks", .handler = action(.create) },
            .{ .method = .PATCH, .path = "/api/tasks/:id", .handler = action(.update) },
            .{ .method = .DELETE, .path = "/api/tasks/:id", .handler = action(.delete) },
        },
    });
}
