//! 强制 epoll 的完整 I/O 测试入口；仅用于 Linux 验证。
test {
    @import("mox_io.zig").platform.forced = .epoll;
}
