const std = @import("std");
const mox = @import("mox");
const mox_io = @import("mox_io");
const embed = @import("mox_vfs");

fn index(ctx: *mox.Context) anyerror!mox.Response {
    _ = ctx;
    // 顺手验证独立 I/O 模块也能通过包依赖导入。
    _ = mox_io.cap("consumer.probe");
    return .{ .body = "external consumer ok\n" };
}

/// 静态资源路由：路径就是编译期嵌入时的 VFS key。
/// 命中 `loop.memory_fs` 后由 `serveFile` 走内存文件，不碰磁盘。
fn asset(ctx: *mox.Context) anyerror!mox.Response {
    _ = ctx;
    return .{ .file_path = "/assets/a.txt", .content_type = "text/plain" };
}

/// `embed.mount` 是泛型函数（`anytype`），不能直接当函数指针传给
/// `serveWith`，包一层把 `*mox_io.Loop` 具体化即可。
fn mountAll(loop: *mox_io.Loop) anyerror!void {
    return embed.mount(loop);
}

pub fn main() !void {
    try mox.serveWith(.{
        .gpa = std.heap.page_allocator,
        .address = try std.Io.net.IpAddress.parse("127.0.0.1", 18081),
        .routes = &.{
            .{ .method = .GET, .path = "/", .handler = index },
            .{ .method = .GET, .path = "/assets/a.txt", .handler = asset },
        },
    }, mountAll);
}
