//! Verify embedded content and the library's public handler API.

const std = @import("std");
const mox = @import("mox");

fn index(_: *mox.Context) !mox.Response {
    return .{ .body = "consumer ok" };
}

pub fn main() !void {
    var output: [128]u8 = undefined;
    const html = try @import("views").get("page.html").renderInto(&output, .{ .title = "<Consumer>", .show = true }, .{});
    if (!std.mem.eql(u8, std.mem.trim(u8, html, "\r\n"), "<h1>&lt;Consumer&gt;</h1><p>Visible</p>")) return error.InvalidTemplateOutput;
    const filesystem = try mox.io.fs.EmbeddedFs.init(@import("assets").image);
    const content = try filesystem.readFile("a.txt");
    if (!std.mem.eql(u8, std.mem.trim(u8, content, "\r\n"), "hello-from-vfs")) return error.InvalidAsset;
    if (!std.mem.eql(u8, std.mem.trim(u8, try filesystem.readFile("sub/index.html"), "\r\n"), "<h1>index</h1>")) return error.InvalidNestedAsset;
    var router = try mox.Router.init(std.heap.page_allocator, &.{
        .{ .method = .GET, .path = "/", .handler = index },
    });
    defer router.deinit();
    var params: mox.Params = .{};
    if (router.match(.GET, "/", &params) == null) return error.RouteNotFound;
}
