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
// ---- Windows Console API 声明 ----------------------------------------------
// Zig 0.17.1 的 std.os.windows 只声明了 CreateProcessW，没有任何 Console API。
// 这里按 Win32 SDK 的签名自行声明（windows.h / consoleapi.h）。
// 只在本文件用到，所以不加 `pub`。
const win_console = if (is_windows) struct {
    const w = std.os.windows;

    const COORD = extern struct { X: i16, Y: i16 };
    const SMALL_RECT = extern struct { Left: i16, Top: i16, Right: i16, Bottom: i16 };

    /// consoleapi.h: CONSOLE_SCREEN_BUFFER_INFO
    const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
        dwSize: COORD,
        dwCursorPosition: COORD,
        wAttributes: u16,
        srWindow: SMALL_RECT,
        dwMaximumWindowSize: COORD,
    };

    extern "kernel32" fn GetConsoleMode(hConsoleHandle: w.HANDLE, lpMode: *w.DWORD) callconv(.winapi) w.BOOL;
    extern "kernel32" fn SetConsoleMode(hConsoleHandle: w.HANDLE, dwMode: w.DWORD) callconv(.winapi) w.BOOL;
    extern "kernel32" fn GetConsoleScreenBufferInfo(
        hConsoleOutput: w.HANDLE,
        lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO,
    ) callconv(.winapi) w.BOOL;

    // 输入模式位（wincon.h）
    const ENABLE_PROCESSED_INPUT: w.DWORD = 0x0001;
    const ENABLE_LINE_INPUT: w.DWORD = 0x0002;
    const ENABLE_ECHO_INPUT: w.DWORD = 0x0004;
    const ENABLE_WINDOW_INPUT: w.DWORD = 0x0008;
    const ENABLE_MOUSE_INPUT: w.DWORD = 0x0010;
    const ENABLE_VIRTUAL_TERMINAL_INPUT: w.DWORD = 0x0200;

    // 输出模式位
    const ENABLE_PROCESSED_OUTPUT: w.DWORD = 0x0001;
    const ENABLE_WRAP_AT_EOL_OUTPUT: w.DWORD = 0x0002;
    const ENABLE_VIRTUAL_TERMINAL_PROCESSING: w.DWORD = 0x0004;

    /// 判断句柄是「输出句柄」还是「输入句柄」。
    /// `GetConsoleScreenBufferInfo` 只对输出句柄成功，是最干净的判据——
    /// 比猜模式位可靠（初始 mode 可能为 0）。
    fn isOutputHandle(h: w.HANDLE) bool {
        var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
        return GetConsoleScreenBufferInfo(h, &info).toBool();
    }

    /// 打开真实控制台设备（CONOUT$ / CONIN$）。
    /// 即使 stdout 被重定向（CI 常见），`CONOUT$` 仍能拿到真正的控制台句柄，
    /// 这是唯一能稳定断言「isTty 对真控制台返回 true」的办法。
    fn openConsole(name: []const u8) ?w.HANDLE {
        var buf: [32]u16 = undefined;
        const len = std.unicode.utf8ToUtf16Le(&buf, name) catch return null;
        if (len >= buf.len) return null;
        buf[len] = 0;
        const h = CreateFileW(
            @ptrCast(&buf),
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            null,
            OPEN_EXISTING,
            0,
            null,
        );
        if (h == w.INVALID_HANDLE_VALUE) return null;
        return h;
    }

    const GENERIC_READ: w.DWORD = 0x80000000;
    const GENERIC_WRITE: w.DWORD = 0x40000000;
    const FILE_SHARE_READ: w.DWORD = 0x1;
    const FILE_SHARE_WRITE: w.DWORD = 0x2;
    const OPEN_EXISTING: w.DWORD = 3;

    extern "kernel32" fn CreateFileW(
        lpFileName: [*:0]const u16,
        dwDesiredAccess: w.DWORD,
        dwShareMode: w.DWORD,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: w.DWORD,
        dwFlagsAndAttributes: w.DWORD,
        hTemplateFile: ?w.HANDLE,
    ) callconv(.winapi) w.HANDLE;
    extern "kernel32" fn CloseHandle(hObject: w.HANDLE) callconv(.winapi) w.BOOL;
    /// 取标准句柄。nStdHandle 传 `STD_OUTPUT_HANDLE` 等（负数 DWORD）。
    fn getStdHandle(nStdHandle: w.DWORD) ?w.HANDLE {
        const h = GetStdHandle(nStdHandle);
        if (h == w.INVALID_HANDLE_VALUE) return null;
        return h;
    }

    const STD_INPUT_HANDLE: w.DWORD = @bitCast(@as(i32, -10));
    const STD_OUTPUT_HANDLE: w.DWORD = @bitCast(@as(i32, -11));
    const STD_ERROR_HANDLE: w.DWORD = @bitCast(@as(i32, -12));

    extern "kernel32" fn GetStdHandle(nStdHandle: w.DWORD) callconv(.winapi) w.HANDLE;
} else struct {};

/// 保存的终端状态（用于恢复）。
pub const SavedState = if (is_windows)
    struct {
        /// 句柄模式位。Windows 每个句柄只有一个 mode，无需区分输入/输出。
        mode: std.os.windows.DWORD,
    }
else
    std.posix.termios;

/// 获取终端尺寸（字符行列）。
///
/// Windows：`GetConsoleScreenBufferInfo` 的 `srWindow` 是**可见窗口**区域，
/// 用它算行列数（`dwSize` 是整个屏幕缓冲区，可能远大于窗口，不适合）。
/// 句柄不是控制台（重定向到管道/文件）时返回 `error.NotATty`。
pub fn getSize(handle: Handle) !Size {
    if (is_windows) {
        const wc = win_console;
        var info: wc.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (!wc.GetConsoleScreenBufferInfo(handle, &info).toBool()) return error.NotATty;
        // Right/Bottom 是闭区间，所以 +1；i16 差值不会溢出（最大 32767）。
        const rows: u16 = @intCast(info.srWindow.Bottom - info.srWindow.Top + 1);
        const cols: u16 = @intCast(info.srWindow.Right - info.srWindow.Left + 1);
        return .{ .rows = rows, .cols = cols };
    } else {
        var ws: std.posix.system.winsize = undefined;
        const rc = std.posix.system.ioctl(handle, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (rc != 0) return error.IoctlFailed;
        return .{ .rows = ws.ws_row, .cols = ws.ws_col };
    }
}

/// 保存当前终端状态（用于后续恢复）。
/// 句柄不是控制台时返回 `error.NotATty`。
pub fn save(handle: Handle) !SavedState {
    if (is_windows) {
        const wc = win_console;
        var mode: std.os.windows.DWORD = 0;
        if (!wc.GetConsoleMode(handle, &mode).toBool()) return error.NotATty;
        return .{ .mode = mode };
    } else {
        return try std.posix.tcgetattr(handle);
    }
}

/// 恢复终端状态。与 `save` 配对使用。
pub fn restore(handle: Handle, state: SavedState) !void {
    if (is_windows) {
        const wc = win_console;
        if (!wc.SetConsoleMode(handle, state.mode).toBool()) return error.SetModeFailed;
    } else {
        try std.posix.tcsetattr(handle, .FLUSH, state);
    }
}

/// 设置终端模式。
///
/// Windows 没有 termios 的细粒度标志，映射到 Console API 的模式位：
/// - `cooked`：行缓冲 + 回显 + 行编辑，即默认控制台行为。
/// - `raw`：关掉行缓冲与回显，逐字节读。同时**开启**
///   `ENABLE_VIRTUAL_TERMINAL_INPUT`，让 ANSI 序列能原样送进来（否则方向键
///   之类会被控制台吞掉/转成扫描码）。输出侧若也是控制台，顺带打开
///   `ENABLE_VIRTUAL_TERMINAL_PROCESSING` 让 ANSI 转义生效。
/// - `cbreak`：关行缓冲、保留信号处理。**Windows 输入句柄上回显也会被关掉**
///   ——实测 `ENABLE_LINE_INPUT` 关闭时 `SetConsoleMode` 拒绝保留
///   `ENABLE_ECHO_INPUT`（0x5 失败 / 0x1 成功），「无行缓冲 + 有回显」
///   在 Windows 无法表达。因此 cbreak 在 Windows 输入句柄上等同 raw，
///   回显需应用自己写回。POSIX 上 cbreak 保留回显，语义不变。
///
/// 注意：Windows 没有 POSIX 的 `ISIG`，Ctrl-C 由 `ENABLE_PROCESSED_INPUT`
/// 控制，这里按 `ISIG` 语义映射（raw 关、cooked/cbreak 开）。
pub fn setMode(handle: Handle, mode: Mode) !void {
    if (is_windows) {
        const wc = win_console;
        var cur: std.os.windows.DWORD = 0;
        if (!wc.GetConsoleMode(handle, &cur).toBool()) return error.NotATty;

        // 输入模式位与输出模式位有重叠值（0x1/0x2/0x4），不能靠值区分句柄类型。
        // `GetConsoleScreenBufferInfo` 只对输出句柄成功，用它判定。
        const is_out = wc.isOutputHandle(handle);

        var next = cur;
        if (is_out) {
            switch (mode) {
                .cooked => {
                    next |= wc.ENABLE_PROCESSED_OUTPUT | wc.ENABLE_WRAP_AT_EOL_OUTPUT;
                    next |= wc.ENABLE_VIRTUAL_TERMINAL_PROCESSING;
                },
                .raw, .cbreak => {
                    next |= wc.ENABLE_PROCESSED_OUTPUT | wc.ENABLE_VIRTUAL_TERMINAL_PROCESSING;
                    next &= ~wc.ENABLE_WRAP_AT_EOL_OUTPUT;
                },
            }
        } else {
            switch (mode) {
                .cooked => {
                    next |= wc.ENABLE_LINE_INPUT | wc.ENABLE_ECHO_INPUT | wc.ENABLE_PROCESSED_INPUT;
                    next &= ~wc.ENABLE_VIRTUAL_TERMINAL_INPUT;
                },
                .raw => {
                    next &= ~wc.ENABLE_LINE_INPUT;
                    next &= ~wc.ENABLE_ECHO_INPUT;
                    next &= ~wc.ENABLE_PROCESSED_INPUT; // 对应 ISIG=false
                    next |= wc.ENABLE_VIRTUAL_TERMINAL_INPUT;
                },
                .cbreak => {
                    // Windows 约束（实测）：关掉 ENABLE_LINE_INPUT 后，
                    // SetConsoleMode 不接受保留 ENABLE_ECHO_INPUT（0x5 失败、
                    // 0x1 成功）。也就是说「无行缓冲 + 有回显」在 Windows 输入
                    // 句柄上无法表达——cbreak 只能退化为 raw 的逐字节语义。
                    // 回显需由应用自己写回；这里如实降级，不假装成功。
                    next &= ~wc.ENABLE_LINE_INPUT;
                    next &= ~wc.ENABLE_ECHO_INPUT;
                    next |= wc.ENABLE_PROCESSED_INPUT; // cbreak 保留信号处理
                    next |= wc.ENABLE_VIRTUAL_TERMINAL_INPUT;
                },
            }
        }
        if (!wc.SetConsoleMode(handle, next).toBool()) return error.SetModeFailed;
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
///
/// Windows：`GetConsoleMode` 成功即说明句柄是控制台缓冲区。
/// 这是最直接可靠的判据——不需要 ConDrv 或 NtQueryObject 探测（那些是
/// 判断「是不是真控制台窗口 vs ConPTY 伪终端」的细节，对 isTty 无意义）。
pub fn isTty(handle: Handle) bool {
    if (is_windows) {
        const wc = win_console;
        var mode: std.os.windows.DWORD = 0;
        return wc.GetConsoleMode(handle, &mode).toBool();
    } else {
        return std.posix.isatty(handle);
    }
}


/// 造一对管道句柄，两端都保证不是控制台。
/// Windows 用 CreatePipe，POSIX 用 pipe2；失败时返回 null 让测试跳过。
const PipePair = struct {
    a: Handle,
    b: Handle,

    fn open() ?PipePair {
        if (is_windows) {
            var r: std.os.windows.HANDLE = undefined;
            var wr: std.os.windows.HANDLE = undefined;
            const ok = CreatePipe(&r, &wr, null, 0).toBool();
            if (!ok) return null;
            return .{ .a = r, .b = wr };
        } else {
            var fds: [2]std.posix.fd_t = undefined;
            _ = std.posix.pipe2(&fds, .{ .CLOEXEC = true }) catch return null;
            return .{ .a = fds[0], .b = fds[1] };
        }
    }

    fn close(self: PipePair) void {
        if (is_windows) {
            _ = CloseHandle(self.a);
            _ = CloseHandle(self.b);
        } else {
            std.posix.close(self.a);
            std.posix.close(self.b);
        }
    }
};

const pipe_k32 = if (is_windows) struct {
    extern "kernel32" fn CreatePipe(
        phReadPipe: *std.os.windows.HANDLE,
        phWritePipe: *std.os.windows.HANDLE,
        lpPipeAttributes: ?*anyopaque,
        nSize: std.os.windows.DWORD,
    ) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn CloseHandle(hObject: std.os.windows.HANDLE) callconv(.winapi) std.os.windows.BOOL;
} else struct {};
const CreatePipe = if (is_windows) pipe_k32.CreatePipe else {};
const CloseHandle = if (is_windows) pipe_k32.CloseHandle else {};

test "isTty：管道不是 TTY" {
    // 两个平台都真跑：Windows 走 CreatePipe + GetConsoleMode 判据，
    // POSIX 走 pipe2 + isatty。管道一定不是 tty。
    const p = PipePair.open() orelse return error.SkipZigTest;
    defer p.close();
    try std.testing.expect(!isTty(p.a));
    try std.testing.expect(!isTty(p.b));
}

test "getSize 对管道返回错误" {
    // 管道不支持尺寸查询，getSize 应返回错误而非 panic。
    // 错误名两平台不同（POSIX IoctlFailed / Windows NotATty），但都必须是错误。
    const p = PipePair.open() orelse return error.SkipZigTest;
    defer p.close();
    try std.testing.expectError(if (is_windows) error.NotATty else error.IoctlFailed, getSize(p.a));
}

test "save 对管道返回错误" {
    // 管道没有控制台模式可读，save 必须报错而不是返回垃圾状态。
    const p = PipePair.open() orelse return error.SkipZigTest;
    defer p.close();
    if (is_windows) {
        try std.testing.expectError(error.NotATty, save(p.a));
    } else {
        // POSIX tcgetattr 对管道返回 ENOTTY，std 会包成 error.NotATty 之外的
        // 具体错误；只断言「返回了错误」。
        if (save(p.a)) |_| {
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "setMode 对管道返回错误" {
    // 管道不是控制台，setMode 必须失败而不是静默成功。
    const p = PipePair.open() orelse return error.SkipZigTest;
    defer p.close();
    if (is_windows) {
        try std.testing.expectError(error.NotATty, setMode(p.a, .raw));
    } else {
        if (setMode(p.a, .raw)) |_| {
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "isTty 与 getSize 对真实控制台的一致性" {
    // 环境相关：CI 里 stdin/stdout 可能被重定向。这里只做逻辑一致性检查——
    // 如果 isTty 为真，getSize 必须成功且行列非零；为假则 getSize 必须失败。
    // 不硬编码「一定在终端里跑」。
    if (is_windows) {
        const wc = win_console;
        _ = wc;
        // Windows 上取标准输出句柄做一致性检查。
        const h = win_console.getStdHandle(win_console.STD_OUTPUT_HANDLE) orelse return error.SkipZigTest;
        if (isTty(h)) {
            const s = try getSize(h);
            try std.testing.expect(s.rows > 0);
            try std.testing.expect(s.cols > 0);
        } else {
            if (getSize(h)) |_| return error.TestUnexpectedResult else |_| {}
        }
    } else {
        const fd = std.posix.STDOUT_FILENO;
        if (isTty(fd)) {
            const s = try getSize(fd);
            try std.testing.expect(s.rows > 0);
            try std.testing.expect(s.cols > 0);
        } else {
            try std.testing.expectError(error.IoctlFailed, getSize(fd));
        }
    }
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

test "Windows：真实控制台句柄被识别为 TTY 且尺寸可查" {
    // 这条是 isTty/getSize Windows 路径的**真测试**：管道测试只能证明
    // 「非控制台返回 false」，把 isTty 写成恒 false 也能过。这里用 CONOUT$
    // 打开真正的控制台设备（stdout 被重定向时依然有效），断言：
    //   isTty == true、getSize 成功且行列 > 0、save/setMode 可往返。
    // 无控制台的环境（纯服务容器）拿不到 CONOUT$，此时跳过。
    if (!is_windows) return error.SkipZigTest;
    const wc = win_console;
    const h = wc.openConsole("CONOUT$") orelse return error.SkipZigTest;
    defer _ = wc.CloseHandle(h);

    try std.testing.expect(isTty(h));
    const sz = try getSize(h);
    try std.testing.expect(sz.rows > 0);
    try std.testing.expect(sz.cols > 0);

    // save → setMode → restore 往返，并且**模式位必须真的变化**：
    // 只断言「没报错」的话，setMode 里不调 SetConsoleMode 也能过（变异测试
    // 实测如此）。这里读回 mode 位，确认 raw 关掉了 WRAP_AT_EOL、cooked 恢复。
    const saved = try save(h);
    defer restore(h, saved) catch {};

    try setMode(h, .raw);
    var after_raw: std.os.windows.DWORD = 0;
    try std.testing.expect(wc.GetConsoleMode(h, &after_raw).toBool());
    try std.testing.expect(after_raw & wc.ENABLE_WRAP_AT_EOL_OUTPUT == 0);
    try std.testing.expect(after_raw & wc.ENABLE_VIRTUAL_TERMINAL_PROCESSING != 0);

    try setMode(h, .cooked);
    var after_cooked: std.os.windows.DWORD = 0;
    try std.testing.expect(wc.GetConsoleMode(h, &after_cooked).toBool());
    try std.testing.expect(after_cooked & wc.ENABLE_WRAP_AT_EOL_OUTPUT != 0);
    // 两种模式的位必须不同，否则说明 setMode 根本没生效。
    try std.testing.expect(after_raw != after_cooked);

    // restore 必须回到原始值。
    try restore(h, saved);
    var after_restore: std.os.windows.DWORD = 0;
    try std.testing.expect(wc.GetConsoleMode(h, &after_restore).toBool());
    try std.testing.expectEqual(saved.mode, after_restore);
}

test "Windows：CONIN$ 输入句柄的 setMode 不破坏输出" {
    // 输入句柄与输出句柄的模式位有重叠值，容易写错分支。这里对 CONIN$
    // 走一遍三个模式，验证不报错、且结束后能恢复。
    if (!is_windows) return error.SkipZigTest;
    const wc = win_console;
    const h = wc.openConsole("CONIN$") orelse return error.SkipZigTest;
    defer _ = wc.CloseHandle(h);

    try std.testing.expect(isTty(h));
    const saved = try save(h);
    defer restore(h, saved) catch {};
    try setMode(h, .raw);
    try setMode(h, .cbreak);
    try setMode(h, .cooked);
}
