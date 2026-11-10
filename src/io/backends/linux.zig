//! Linux 后端门面：编译期把 `platform` 指到这里，运行时选择事件循环。
//!
//! 默认走 `io_uring`（性能最好）。内核不支持、被 `seccomp` 拦截、
//! 或 `/proc/sys/kernel/io_uring_disabled` 置 1 时，`io_uring_setup` 会失败，
//! 此时自动回落到 `epoll`。`MOX_IO_BACKEND=epoll` 可强制回落，供 CI 与
//! 排障覆盖 epoll 路径；正常用户无需设置。
//!
//! 下面这些同步辅助函数与事件循环无关，统一转发给 `uring.zig`；
//! 真正的后端差异只在 `create()` 返回的 `Io.vtable` 里。

const std = @import("std");
const root = @import("../io.zig");
const uring = @import("uring.zig");
const epoll = @import("epoll.zig");

pub const createSocket = uring.createSocket;
pub const createTcpSocket = uring.createTcpSocket;
pub const createUdpSocket = uring.createUdpSocket;
pub const recvFromBlocking = uring.recvFromBlocking;
pub const sendToBlocking = uring.sendToBlocking;
pub const bindSocket = uring.bindSocket;
pub const listenSocket = uring.listenSocket;
pub const localAddress = uring.localAddress;
pub const acceptSocket = uring.acceptSocket;
pub const connectSocket = uring.connectSocket;
pub const setReuseAddress = uring.setReuseAddress;
pub const setSockOpt = uring.setSockOpt;
pub const shutdownSend = uring.shutdownSend;
pub const closeSocket = uring.closeSocket;
pub const sendBlocking = uring.sendBlocking;
pub const recvBlocking = uring.recvBlocking;
pub const tickCount = uring.tickCount;
pub const fileSize = uring.fileSize;
pub const readFileInto = uring.readFileInto;
pub const writeFileAll = uring.writeFileAll;
pub const deleteFile = uring.deleteFile;
pub const readFileAt = uring.readFileAt;
pub const appendFile = uring.appendFile;
pub const truncateFile = uring.truncateFile;

/// 当前进程实际选中的后端，便于测试与日志观测。
pub const Choice = enum { uring, epoll };
pub var chosen: Choice = .uring;

/// 测试 / 排障用的显式覆盖：置 `.epoll` 时跳过 io_uring，直接走 epoll。
/// 正常用户不用管；这是进程级变量，只在 `open()` 时读一次，不在热路径。
pub var forced: ?Choice = null;

pub fn create(alloc: std.mem.Allocator) !root.Io {
    if (forced == .epoll) {
        chosen = .epoll;
        return epoll.create(alloc);
    }
    const io = uring.create(alloc) catch |err| {
        // `io_uring_setup` 失败（ENOSYS / EPERM / seccomp 拦截）时回落；
        // mmap 之类的资源失败也一并回落，epoll 不依赖这些资源。
        if (err == error.OutOfMemory) return err;
        chosen = .epoll;
        return epoll.create(alloc);
    };
    chosen = .uring;
    return io;
}

test "Linux 后端选择：forced 覆盖与默认回落" {
    const saved_forced = forced;
    defer forced = saved_forced;

    // 显式覆盖：跳过 io_uring，直接建 epoll。
    forced = .epoll;
    var io = try create(std.testing.allocator);
    try std.testing.expectEqual(Choice.epoll, chosen);
    io.vtable.deinit(io.userdata);

    // 默认路径必须与本机「直接建 io_uring 能否成功」一致：能则选 uring，
    // 不能则自动回落 epoll。这条断言在两种环境里都有牙——若把 create
    // 改成无条件选 epoll，支持 uring 的机器会立刻变红。
    forced = null;
    const uring_ok = blk: {
        const probe = uring.create(std.testing.allocator) catch break :blk false;
        probe.vtable.deinit(probe.userdata);
        break :blk true;
    };
    io = try create(std.testing.allocator);
    defer io.vtable.deinit(io.userdata);
    try std.testing.expectEqual(
        if (uring_ok) Choice.uring else Choice.epoll,
        chosen,
    );
}
