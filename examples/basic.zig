const std = @import("std");
const mox = @import("mox");

fn index(ctx: *mox.Context) anyerror!mox.Response {
    _ = ctx;
    return .{ .body = "hello from mox\n" };
}

fn ctypeFor(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".js")) return "text/javascript; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json";
    if (std.mem.endsWith(u8, path, ".txt")) return "text/plain; charset=utf-8";
    return "application/octet-stream";
}

/// 把 ./public 下的内容作为静态文件提供（在 Work 池中读取）。
fn staticFile(ctx: *mox.Context) anyerror!mox.Response {
    const sub = ctx.param("path") orelse
        return .{ .status = .not_found, .body = "not found\n" };
    const path = try std.fmt.allocPrint(ctx.gpa, "public{s}", .{sub});
    return .{ .file_path = path, .file_path_owned = true, .content_type = ctypeFor(sub) };
}

fn hello(ctx: *mox.Context) anyerror!mox.Response {
    const name = ctx.param("name") orelse "world";
    const body = try std.fmt.allocPrint(ctx.gpa, "hello {s}\n", .{name});
    return .{ .body = body };
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 18080);
    std.debug.print("listening on {s}:{d}\n", .{ "127.0.0.1", 18080 });
    try mox.serve(.{
        .gpa = gpa,
        .address = addr,
        .routes = &.{
            .{ .method = .GET, .path = "/", .handler = index },
            .{ .method = .GET, .path = "/hello/:name", .handler = hello },
            .{ .method = .GET, .path = "/static/*path", .handler = staticFile },
        },
    });
}
