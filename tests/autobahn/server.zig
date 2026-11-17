//! Echo fixture with capacity for Autobahn's messages up to 16 MiB.

const std = @import("std");
const mox = @import("mox");

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
        .routes = &.{.{ .method = .GET, .path = "/ws", .handler = websocket }},
        .ws_max_message_size = 16 * 1024 * 1024,
        .ws_max_queue_size = 32 * 1024 * 1024,
    });
}
