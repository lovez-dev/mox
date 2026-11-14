//! 强制 epoll 的完整 Web 测试入口；仅用于 Linux 验证。
test {
    @import("mox_io").platform.forced = .epoll;
    _ = @import("root.zig");
}
