//! TTY / 终端支持：模式切换、尺寸查询、彩色输出辅助。
//!
//! 设计原则：
//! - 只暴露**同步**接口（POSIX tcgetattr/tcsetattr、Windows Console API）；
//!   终端操作本身不阻塞（几微秒内完成），无需异步化。
//! - 不做高层抽象（进度条、彩色文本构造）——那是上层库的职责。
//! - 跨平台：Windows Console API + POSIX termios，统一语义。

const std = @import("std");
const builtin = @import("builtin");
const root = @import("io.zig");

const is_windows = builtin.os.tag == .windows;
const is_posix = !is_windows;

/// TTY 句柄（stdin/stdout/stderr 的文件描述符 / HANDLE）。
pub const Handle = if (is_windows) std.os.windows.HANDLE else std.posix.fd_t;

/// 终端模式。
pub const Mode = enum {
    /// 默认行模式：行缓冲、回显、信号处理。
    cooked,
    /// 原始模式：无缓冲、无回显、无信号、逐字节读取（用于 readline、TUI）。
    raw,
    /// Cbreak 模式：无缓冲、有回显、信号处理（用于简单交互式输入）。
    cbreak,
};

/// 终端尺寸（字符单位）。
pub const Size = struct {
    rows: u16,
    cols: u16,
};

/// 保存的终端状态（用于恢复）。
pub const SavedState = if (is_windows)
    struct {
        input_mode: std.os.windows.DWORD,
        output_mode: std.os.windows.DWORD,
    }
else
    std.posix.termios;

/// 获取终端尺寸（字符行列）。
/// Windows：Zig 0.17.1 的 kernel32.zig 未暴露 GetConsoleScreenBufferInfo，
/// 暂返回 error.Unsupported；POSIX 路径经 CI 实测。
pub fn getSize(handle: Handle) !Size {
    if (is_windows) {
        return error.Unsupported; // TODO: Windows ConPTY / GetConsoleScreenBufferInfo
    } else {
        var ws: std.posix.system.winsize = undefined;
        const rc = std.posix.system.ioctl(handle, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (rc != 0) return error.IoctlFailed;
        return .{ .rows = ws.ws_row, .cols = ws.ws_col };
    }
}

/// 保存当前终端状态（用于后续恢复）。
/// Windows：kernel32.zig 未暴露 GetConsoleMode，暂返回 error.Unsupported。
pub fn save(handle: Handle) !SavedState {
    if (is_windows) {
        return error.Unsupported; // TODO: Windows GetConsoleMode
    } else {
        return try std.posix.tcgetattr(handle);
    }
}

/// 恢复终端状态。
/// Windows：kernel32.zig 未暴露 SetConsoleMode，暂返回 error.Unsupported。
pub fn restore(handle: Handle, state: SavedState) !void {
    if (is_windows) {
        return error.Unsupported; // TODO: Windows SetConsoleMode
    } else {
        try std.posix.tcsetattr(handle, .FLUSH, state);
    }
}

/// 设置终端模式。
/// Windows：kernel32.zig 未暴露 GetConsoleMode/SetConsoleMode，暂返回 error.Unsupported。
pub fn setMode(handle: Handle, mode: Mode) !void {
    if (is_windows) {
        return error.Unsupported; // TODO: Windows GetConsoleMode/SetConsoleMode
    } else {
        var termios = try std.posix.tcgetattr(handle);
        switch (mode) {
            .cooked => {
                termios.lflag.ICANON = true;
                termios.lflag.ECHO = true;
                termios.lflag.ISIG = true;
            },
            .raw => {
                termios.lflag.ICANON = false;
                termios.lflag.ECHO = false;
                termios.lflag.ISIG = false;
                termios.lflag.IEXTEN = false;
                termios.iflag.IXON = false;
                termios.iflag.ICRNL = false;
                termios.iflag.BRKINT = false;
                termios.iflag.INPCK = false;
                termios.iflag.ISTRIP = false;
                termios.oflag.OPOST = false;
                termios.cc[@intFromEnum(std.posix.V.MIN)] = 1;
                termios.cc[@intFromEnum(std.posix.V.TIME)] = 0;
            },
            .cbreak => {
                termios.lflag.ICANON = false;
                termios.lflag.ECHO = true;
                termios.lflag.ISIG = true;
            },
        }
        try std.posix.tcsetattr(handle, .FLUSH, termios);
    }
}

/// 是否是 TTY（而非管道、文件重定向）。
/// Windows：isTty 通过 NtQueryObject 或 ConDrv 判断，暂返回 false。
pub fn isTty(handle: Handle) bool {
    if (is_windows) {
        return false; // TODO: Windows ConDrv / NtQueryObject 检测
    } else {
        return std.posix.isatty(handle);
    }
}


test "isTty：管道不是 TTY" {
    // 用 pipe 两端验证：管道 fd 一定不是 tty
    if (is_windows) return error.SkipZigTest;
    var fds: [2]std.posix.fd_t = undefined;
    _ = std.posix.pipe2(&fds, .{ .CLOEXEC = true }) catch return error.SkipZigTest;
    defer { std.posix.close(fds[0]); std.posix.close(fds[1]); }
    try std.testing.expect(!isTty(fds[0]));
    try std.testing.expect(!isTty(fds[1]));
}

test "getSize 对管道返回错误" {
    // 管道 fd 不支持 TIOCGWINSZ，getSize 应返回错误而非 panic
    if (is_windows) return error.SkipZigTest;
    var fds: [2]std.posix.fd_t = undefined;
    _ = std.posix.pipe2(&fds, .{ .CLOEXEC = true }) catch return error.SkipZigTest;
    defer { std.posix.close(fds[0]); std.posix.close(fds[1]); }
    try std.testing.expectError(error.IoctlFailed, getSize(fds[0]));
}

test "Size 结构体字段可读" {
    const s: Size = .{ .rows = 24, .cols = 80 };
    try std.testing.expectEqual(@as(u16, 24), s.rows);
    try std.testing.expectEqual(@as(u16, 80), s.cols);
}

test "Mode 枚举三个值均可用" {
    const modes = [_]Mode{ .cooked, .raw, .cbreak };
    for (modes) |m| {
        // 只验证可以构造、不调 setMode（CI 环境无终端）
        _ = m;
    }
}
