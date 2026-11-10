//! 完成节点类型族：调用方持有、内嵌在各操作结构体里的零分配节点。
//!
//! `Callback` 的签名带 `*Loop`，因此本文件与 `loop.zig` 互相 import；
//! 两边都只持有指针，Zig 的惰性分析下完全合法。

const std = @import("std");
const root = @import("io.zig");
const Loop = @import("loop.zig").Loop;

const Handle = root.Handle;
const INVALID_HANDLE = root.INVALID_HANDLE;
const Scratch = root.Scratch;

pub const Callback = *const fn (loop: *Loop, c: *Completion) void;

/// 完成节点对应的操作类型，`Loop.add` 按此分派。
pub const Op = enum {
    timer,
    net_recv,
    net_send,
    net_close,
    net_accept,
    net_connect,
    udp_recv,
    udp_send,
    work,
};

/// 所有操作的基类。具体完成体把它作为第一个字段 `c` 内嵌，
/// 因此 `*Completion` 可用 `@fieldParentPtr` 反查回去。
pub const Completion = struct {
    /// 不透明内核暂存区。放在首位，交给后端的地址与它交回的地址一致，
    /// 可直接映射回本节点。
    ov: Scratch = std.mem.zeroes(Scratch),

    op: Op,
    callback: ?Callback = null,

    /// 操作完成时回填。
    err: ?anyerror = null,
    bytes: usize = 0,

    /// 关联的套接字。`timer` / `work` 为 `INVALID_HANDLE`。
    /// 有了它，`Loop.cancel` 不必认识每种节点类型就能找到要取消的 fd，
    /// 新增异步能力时也不必回来改 `socketOf` 的分支。
    socket: Handle = INVALID_HANDLE,

    /// 已被 `Loop.cancel` 标记：完成包到达时只回收、不回调。
    /// 只在循环线程读写，无需原子。
    cancelled: bool = false,

    /// 侵入式链表：等待期间挂在定时器队列，同步完成时挂在就绪队列。
    next: ?*Completion = null,
    deadline_ms: u64 = 0,
};

pub const Timer = struct {
    c: Completion = .{ .op = .timer },
    duration_ms: u64,

    pub fn init(duration_ms: u64) Timer {
        return .{ .duration_ms = duration_ms };
    }

    pub fn getResult(self: *const Timer) !void {
        if (self.c.err) |e| return e;
    }
};

pub const NetRecv = struct {
    c: Completion = .{ .op = .net_recv },
    socket: Handle = INVALID_HANDLE,
    buffer: []u8 = &.{},

    pub fn init(socket: Handle, buffer: []u8) NetRecv {
        return .{ .c = .{ .op = .net_recv, .socket = socket }, .socket = socket, .buffer = buffer };
    }

    /// 收到的字节数；0 表示对端正常关闭。
    pub fn getResult(self: *const NetRecv) !usize {
        if (self.c.err) |e| return e;
        return self.c.bytes;
    }
};

pub const NetSend = struct {
    c: Completion = .{ .op = .net_send },
    socket: Handle = INVALID_HANDLE,
    bytes_buffer: []const u8 = &.{},

    pub fn init(socket: Handle, bytes_buffer: []const u8) NetSend {
        return .{ .c = .{ .op = .net_send, .socket = socket }, .socket = socket, .bytes_buffer = bytes_buffer };
    }

    pub fn getResult(self: *const NetSend) !usize {
        if (self.c.err) |e| return e;
        return self.c.bytes;
    }
};

pub const NetClose = struct {
    c: Completion = .{ .op = .net_close },
    socket: Handle = INVALID_HANDLE,

    pub fn init(socket: Handle) NetClose {
        return .{ .c = .{ .op = .net_close, .socket = socket }, .socket = socket };
    }
};

pub const NetAccept = struct {
    c: Completion = .{ .op = .net_accept },
    listen: Handle = INVALID_HANDLE,
    /// 与监听套接字同族、新建未绑定的 socket；完成后即为已接受连接。
    accept_socket: Handle = INVALID_HANDLE,
    /// AcceptEx 把本端与对端地址写到这里。
    addr_buf: [128]u8 = undefined,

    pub fn init(listen: Handle, accept_socket: Handle) NetAccept {
        return .{ .c = .{ .op = .net_accept, .socket = listen }, .listen = listen, .accept_socket = accept_socket };
    }

    pub fn getResult(self: *const NetAccept) !Handle {
        if (self.c.err) |e| return e;
        return self.accept_socket;
    }
};

pub const NetConnect = struct {
    c: Completion = .{ .op = .net_connect },
    socket: Handle = INVALID_HANDLE,
    address: std.Io.net.IpAddress,

    pub fn init(socket: Handle, address: std.Io.net.IpAddress) NetConnect {
        return .{ .c = .{ .op = .net_connect, .socket = socket }, .socket = socket, .address = address };
    }

    pub fn getResult(self: *const NetConnect) !void {
        if (self.c.err) |e| return e;
    }
};

/// 在池线程执行阻塞调用，再把完成投递回循环线程。通用逃生口：文件、DNS、
/// 一切没有原生异步形式的操作都走这里，避免阻塞循环。
pub const Work = struct {
    c: Completion = .{ .op = .work },
    /// 在循环线程之外执行。在此做阻塞工作、把结果存到外层结构体
    /// （用 `@fieldParentPtr("work", w)` 反查）。
    func: *const fn (*Work) void,
    /// 侵入式链接，串起线程池的待办 / 已完成队列。
    next: ?*Work = null,

    pub fn init(func: *const fn (*Work) void) Work {
        return .{ .func = func };
    }
};

