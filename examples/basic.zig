//! Small HTTP server with parameter routing and WebSocket echo.

const std = @import("std");
const mox = @import("mox");

fn index(_: *mox.Context) !mox.Response {
    return .{ .body = "hello from mox\n" };
}

fn hello(ctx: *mox.Context) !mox.Response {
    const name = ctx.param("name") orelse "world";
    return .{ .body = try std.fmt.allocPrint(ctx.gpa, "hello {s}\n", .{name}) };
}

fn echo(conn: mox.WsConn, message: mox.WsMessage) void {
    switch (message.opcode) {
        .text => conn.sendText(message.data) catch conn.close(),
        .binary => conn.sendBinary(message.data) catch conn.close(),
        else => {},
    }
}

fn websocket(_: *mox.Context) !mox.Response {
    return mox.Response.upgrade(echo);
}

pub fn main() !void {
    try mox.serve(.{
        .gpa = std.heap.page_allocator,
        .address = mox.io.types.Address.loopback(8080),
        .routes = &.{
            .{ .method = .GET, .path = "/", .handler = index },
            .{ .method = .GET, .path = "/hello/:name", .handler = hello },
            .{ .method = .GET, .path = "/ws", .handler = websocket },
        },
    });
}
