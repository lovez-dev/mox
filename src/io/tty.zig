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
pub fn getSize(handle: Handle) !Size {
    if (is_windows) {
        const kernel32 = std.os.windows.kernel32;
        var info: std.os.windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (kernel32.GetConsoleScreenBufferInfo(handle, &info) == 0) {
            return error.GetConsoleFailed;
        }
        const cols = info.srWindow.Right - info.srWindow.Left + 1;
        const rows = info.srWindow.Bottom - info.srWindow.Top + 1;
        return .{
            .rows = @intCast(rows),
            .cols = @intCast(cols),
        };
    } else {
        var ws: std.posix.system.winsize = undefined;
        const rc = std.posix.system.ioctl(handle, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (rc != 0) return error.IoctlFailed;
        return .{ .rows = ws.ws_row, .cols = ws.ws_col };
    }
}

/// 保存当前终端状态（用于后续恢复）。
pub fn save(handle: Handle) !SavedState {
    if (is_windows) {
        const kernel32 = std.os.windows.kernel32;
        var input_mode: std.os.windows.DWORD = 0;
        if (kernel32.GetConsoleMode(handle, &input_mode) == 0) return error.GetConsoleFailed;
        // 输出模式从 stdout 读取（假设 handle 是 stdin，需要另一个 handle）
        // 简化实现：只保存输入模式；输出模式由调用方分别保存 stdout handle。
        return .{ .input_mode = input_mode, .output_mode = 0 };
    } else {
        return try std.posix.tcgetattr(handle);
    }
}

/// 恢复终端状态。
pub fn restore(handle: Handle, state: SavedState) !void {
    if (is_windows) {
        const kernel32 = std.os.windows.kernel32;
        if (kernel32.SetConsoleMode(handle, state.input_mode) == 0) {
            return error.SetConsoleFailed;
        }
    } else {
        try std.posix.tcsetattr(handle, .FLUSH, state);
    }
}

/// 设置终端模式。
pub fn setMode(handle: Handle, mode: Mode) !void {
    if (is_windows) {
        const kernel32 = std.os.windows.kernel32;
        var current_mode: std.os.windows.DWORD = 0;
        if (kernel32.GetConsoleMode(handle, &current_mode) == 0) {
            return error.GetConsoleFailed;
        }
        const new_mode = switch (mode) {
            .cooked => current_mode | 0x0001 | 0x0002 | 0x0004, // ENABLE_ECHO_INPUT | LINE_INPUT | PROCESSED_INPUT
            .raw => current_mode & ~@as(std.os.windows.DWORD, 0x0001 | 0x0002 | 0x0004),
            .cbreak => (current_mode | 0x0001) & ~@as(std.os.windows.DWORD, 0x0002), // 回显、无行缓冲
        };
        if (kernel32.SetConsoleMode(handle, new_mode) == 0) {
            return error.SetConsoleFailed;
        }
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
pub fn isTty(handle: Handle) bool {
    if (is_windows) {
        const kernel32 = std.os.windows.kernel32;
        var mode: std.os.windows.DWORD = 0;
        return kernel32.GetConsoleMode(handle, &mode) != 0;
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
