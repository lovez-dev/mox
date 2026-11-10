const std = @import("std");
const mox = @import("mox");
const mox_io = @import("mox_io");

fn index(ctx: *mox.Context) anyerror!mox.Response {
    _ = ctx;
    // 顺手验证独立 I/O 模块也能通过包依赖导入。
    _ = mox_io.cap("consumer.probe");
    return .{ .body = "external consumer ok\n" };
}

pub fn main() !void {
    try mox.serve(.{
        .gpa = std.heap.page_allocator,
        .address = try std.Io.net.IpAddress.parse("127.0.0.1", 18081),
        .routes = &.{
            .{ .method = .GET, .path = "/", .handler = index },
        },
    });
}
