//! Buffered HTML responses keep the request arena alive until transmission ends.
const std = @import("std");
const mox = @import("mox");
const views = @import("views");
const models = @import("view_models");

fn home(ctx: *mox.Context) !mox.Response {
    const items = [_]models.Item{.{ .title = "Documentation", .url = try mox.template.Url.init("https://github.com/lovez-dev/mox") }};
    const body = try views.get("home.html").renderAlloc(ctx.gpa, .{ .title = "Home", .items = &items }, .{ .max_output_bytes = 64 * 1024 });
    return .{ .body = body, .content_type = "text/html; charset=utf-8" };
}

pub fn main() !void {
    try mox.serve(.{
        .gpa = std.heap.page_allocator,
        .address = mox.io.types.Address.loopback(8080),
        .routes = &.{.{ .method = .GET, .path = "/", .handler = home }},
    });
}
