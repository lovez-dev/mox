//! errno → 具名错误映射的**POSIX 收口**。
//!
//! 纪律：POSIX 平台（Linux / macOS / FreeBSD）上**通用**的 errno 翻译一律
//! 走这里，不允许各自写 `switch (errno)` —— 否则同一个 `EACCES` 在不同
//! 后端会变成不同的名字，调用方没法写跨平台的 `switch`。
//! 现状：`uring` / `epoll` 的 `cvt()`、`kqueue` 的 bind/removeDir/rename/
//! symlink/stat/delete 路径、`process.zig` 的等待/信号路径都已路由到本
//! 模块 —— POSIX 后端不再有私有的「错误名」`switch (errno)`（仅剩
//! `INPROGRESS` / `EXIST` 这类**控制流**判断，不产出错误名）。
//! `windows` 用的是 WSA/Win32 错误码（不是 errno），映射集中在
//! `backends/windows.zig` 的 `wsaError()` / `winError()` 两个函数，
//! 产出的名字同样必须落在 `errors.zig` 的 `Error` 集合内。
//!
//! 为什么值得单独一个文件：
//!
//! - **errno 细节不能丢**。早期版本用 `fn cvt(rc) !usize` 把所有失败塌缩成
//!   `error.SyscallFailed`，`EAGAIN` / `ECONNRESET` / `EPIPE` / `ENOSPC`
//!   全都变成同一个错误，调用方无法区分「对端重置」和「磁盘满」。
//! - **映射表只有一份**。四个后端的 errno 语义基本一致（POSIX 三家 +
//!   Winsock），一份表就能覆盖，避免「Linux 叫 `ConnectionReset`、
//!   macOS 叫 `SocketFailed`」这种分裂。
//!
//! 范式对齐 `std.Io.Threaded` 与 `std.posix`：**具名集合 + 兜底保留原始
//! errno**。未识别的 errno 落到 `errors.UnexpectedErrno`（见 `errors.zig`），保证
//! 也能原样冒泡，而不是被塞进某个语义不对的桶。

const std = @import("std");
const builtin = @import("builtin");

const errors = @import("errors.zig");

/// POSIX errno 的数值类型。Linux 用 `linux.E`，BSD/Darwin 用 `std.c.E`。
const E = switch (builtin.os.tag) {
    .linux => std.os.linux.E,
    else => std.c.E,
};

/// 把一个 errno 值映射成语义化错误。
///
/// `errno` 传 `E` 的成员（不是裸整数）。未识别的 errno **原样返回**
/// `error.UnexpectedErrno` —— 它携带原始码，调用方仍能判断细节。
pub fn fromErrno(err: E) errors.Error {
    return switch (err) {
        .ACCES => error.AccessDenied,
        .ADDRINUSE => error.AddressInUse,
        .AGAIN => error.WouldBlock,
        .CHILD => error.NoChildProcess,
        .INTR => error.Interrupted,
        .NOSYS => error.Unsupported,
        .BADF => error.NotOpen,
        .BUSY => error.Busy,
        .CONNABORTED => error.ConnectionAborted,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionReset,
        .DESTADDRREQ => error.AddressRequired,
        .EXIST => error.PathAlreadyExists,
        .FAULT => error.BadAddress,
        .INVAL => error.InvalidArgument,
        .IO => error.IoFailed,
        .ISCONN => error.AlreadyConnected,
        .ISDIR => error.IsDirectory,
        .LOOP => error.SymLinkLoop,
        .MFILE => error.ProcessFdQuotaExceeded,
        .MSGSIZE => error.MessageTooLarge,
        .NAMETOOLONG => error.NameTooLong,
        .NETDOWN => error.NetworkDown,
        .NETRESET => error.NetworkReset,
        .NETUNREACH => error.NetworkUnreachable,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOBUFS => error.NoBufferSpace,
        .NODEV => error.NoDevice,
        .NOENT => error.FileNotFound,
        .NOMEM => error.OutOfMemory,
        .NOSPC => error.NoSpaceLeft,
        .NOTCONN => error.NotConnected,
        .NOTDIR => error.NotDirectory,
        .NOTEMPTY => error.DirNotEmpty,
        .NOTSOCK => error.NotSocket,
        .NXIO => error.NoDevice,
        .PERM => error.AccessDenied,
        .PIPE => error.BrokenPipe,
        .PROTO => error.ProtocolError,
        .PROTONOSUPPORT => error.ProtocolNotSupported,
        .RANGE => error.ValueOutOfRange,
        .ROFS => error.ReadOnlyFileSystem,
        .SPIPE => error.SocketError,
        .TIMEDOUT => error.TimedOut,
        .XDEV => error.CrossDevice,
        else => error.UnexpectedErrno,
    };
}

/// 从系统调用返回值构造错误。
///
/// POSIX 约定：失败时返回 `-1` 并设置 `errno`。`rc` 是原始返回值
/// （`usize`），负值部分即 errno。
pub fn fromSyscall(rc: isize) errors.Error {
    if (rc >= 0) return error.UnexpectedErrno;
    const e: E = @fromBackingInt(@intCast(@as(u16, @intCast(-rc))));
    return fromErrno(e);
}

/// 读当前线程的 `errno` 并返回原始枚举（不映射），供需要自行特判的
/// 路径使用（如 `unlink` 的 `NOENT` 幂等分支）。
pub fn lastErrnoValue() E {
    const raw = switch (builtin.os.tag) {
        .linux => std.os.linux.errno(),
        else => std.c._errno().*,
    };
    return @fromBackingInt(@intCast(@as(u16, @intCast(raw))));
}

/// 读当前线程的 `errno` 并映射。
pub fn lastErrno() errors.Error {
    return fromErrno(lastErrnoValue());
}

/// 映射 errno，但把「成功」也当作一种情况处理（某些路径 errno 是陈旧的）。
pub fn fromErrnoOr(rc: isize) errors.Error {
    if (rc < 0) return fromSyscall(rc);
    return lastErrno();
}
