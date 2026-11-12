//! 信号订阅：POSIX self-pipe + `Work` 线程阻塞读；Windows 无对应语义。
//!
//! ## 形状
//!
//! 信号不能「异步等」，只能**阻塞等**。因此 `Signal.Wait` 内嵌一个 `Work` 节点，
//! 由池线程阻塞在 self-pipe 的读端上；信号到达时写端被写入一个字节，读端返回，
//! 回调回到循环线程。
//!
//! 为什么用 self-pipe 而不是直接 `sigwait`/`signalfd`：
//! - `sigwait` 要求信号先被 `pthread_sigmask` 屏蔽，而屏蔽必须**在所有线程**上
//!   生效，否则信号可能投递到别的线程，池线程永远等不到。
//! - `signalfd` 是 Linux 专有。
//! - self-pipe 用「异步信号安全的 `write`」把信号转成文件描述符可读事件，
//!   全 POSIX 通用，且能挂多个订阅者。
//!
//! ## 与 `SIGPIPE` 的关系
//!
//! `Loop.init` 已经把 `SIGPIPE` 设为 `SIG_IGN`（见 `loop.zig`）。**不要**再用
//! 本模块订阅 `SIGPIPE`：它已经被忽略，永远不会走到这里的处理器。
//!
//! ## 限制
//!
//! - 同一时刻每种信号只支持一个订阅（`sigaction` 是进程级单值）。
//! - 处理器里只做 `write`，不碰任何堆内存——异步信号安全。
//! - Windows 返回 `error.Unsupported`。

const std = @import("std");
const builtin = @import("builtin");
const Work = @import("completion.zig").Work;

const is_windows = builtin.os.tag == .windows;
const is_linux = builtin.os.tag == .linux;
const lx = if (is_linux) std.os.linux else struct {};
const sysc = if (is_windows) struct {} else std.c;

/// 常用信号编号（跨 POSIX 一致）。
pub const Signals = struct {
    pub const HUP: u8 = 1;
    pub const INT: u8 = 2;
    pub const QUIT: u8 = 3;
    pub const TERM: u8 = 15;
    // USR1/USR2 的编号在 Linux（10/12）与 macOS/BSD（30/31）上不同。
    pub const USR1: u8 = switch (builtin.os.tag) {
        .linux => 10,
        else => 30, // macOS / FreeBSD / NetBSD / OpenBSD / DragonFly
    };
    pub const USR2: u8 = switch (builtin.os.tag) {
        .linux => 12,
        else => 31,
    };
};

/// 每种信号最多一个订阅：`sigaction` 是进程级单值，多订阅会互相覆盖。
const max_signal = 32;
var pipe_write_fd: [max_signal]std.atomic.Value(i32) = blk: {
    var arr: [max_signal]std.atomic.Value(i32) = undefined;
    for (&arr) |*v| v.* = std.atomic.Value(i32).init(-1);
    break :blk arr;
};

/// 信号的异步处理器。**只能**做异步信号安全的事：这里只 `write` 一个字节。
fn handler(sig: if (is_linux) lx.SIG else sysc.SIG) callconv(.c) void {
    const idx: usize = @intCast(@backingInt(sig));
    if (idx >= max_signal) return;
    const fd = pipe_write_fd[idx].load(.acquire);
    if (fd < 0) return;
    const byte: [1]u8 = .{1};
    // 直接调裸 write；忽略返回值（管道满时丢弃，信号本身是边沿语义）。
    if (is_linux) {
        _ = lx.write(@intCast(fd), &byte, 1);
    } else {
        _ = sysc.write(fd, &byte, 1);
    }
}

/// 测试辅助：给自己发一个信号，走真实的 `kill` 路径。
/// 生产代码不需要它——正常用法是外部 `kill` 或内核投递。
pub fn raiseForTest(pid: i32, sig: u8) bool {
    if (is_windows) return false;
    if (is_linux) {
        const rc = lx.kill(pid, @fromBackingInt(@intCast(sig)));
        return @as(isize, @bitCast(rc)) == 0;
    }
    return sysc.kill(pid, @fromBackingInt(@intCast(sig))) == 0;
}

/// 等待某个信号到达。内嵌 `Work`，占一个池线程阻塞在 self-pipe 读端。
pub const Signal = struct {
    work: Work,
    sig: u8,
    /// 读端（本对象持有）；写端在全局表里，供处理器写入。
    read_fd: i32 = -1,
    /// 捕获到的信号编号；`null` 表示还没收到或出错。
    received: ?u8 = null,
    err: ?anyerror = null,

    /// 订阅 `sig`。成功后该信号由本模块接管，进程不会再因它默认终止。
    pub fn init(sig: u8) anyerror!Signal {
        if (is_windows) return error.Unsupported;
        if (sig == 0 or sig >= max_signal) return error.InvalidSignal;

        var fds: [2]i32 = undefined;
        if (is_linux) {
            const rc = lx.pipe2(&fds, .{ .CLOEXEC = true });
            const signed: isize = @bitCast(rc);
            if (signed < 0) return error.PipeFailed;
        } else {
            if (sysc.pipe(&fds) != 0) return error.PipeFailed;
        }

        // 读端非阻塞：`Work` 线程用阻塞读，但 `deinit` 时要能立刻退出。
        pipe_write_fd[sig].store(fds[1], .release);

        // 装处理器。`SA_RESTART` 让被信号打断的其他 syscall 自动重启。
        if (is_linux) {
            const act = lx.Sigaction{
                .handler = .{ .handler = handler },
                .mask = std.mem.zeroes(lx.sigset_t),
                .flags = lx.SA.RESTART,
            };
            _ = lx.sigaction(@fromBackingInt(@intCast(sig)), &act, null);
        } else {
            const act = sysc.Sigaction{
                .handler = .{ .handler = handler },
                .mask = std.mem.zeroes(sysc.sigset_t),
                .flags = @intCast(sysc.SA.RESTART),
            };
            _ = sysc.sigaction(@fromBackingInt(@intCast(sig)), &act, null);
        }

        return .{ .work = Work.init(run), .sig = sig, .read_fd = fds[0] };
    }

    /// 取消订阅并关闭读端。必须在 `Wait` 节点已从循环摘除之后调用。
    pub fn deinit(self: *Signal) void {
        // 先原子置换写端 fd（信号处理器原子读取它，交换后见 -1 直接返回），
        // 再向其写入哨兵字节（0），唤醒可能正阻塞于 read 的 Work 线程；
        // 最后关读端。不论 Work 线程处于何种状态，deinit 后 pool.shutdown()
        // 都能 join 到它，不会永久挂死。
        const w = pipe_write_fd[self.sig].swap(-1, .acq_rel);
        if (w >= 0) {
            const sentinel: [1]u8 = .{0};
            if (is_linux) {
                _ = lx.write(@intCast(w), &sentinel, 1);
                _ = lx.close(@intCast(w));
            } else {
                _ = sysc.write(w, &sentinel, 1);
                _ = sysc.close(w);
            }
        }
        if (self.read_fd >= 0) {
            if (is_linux) {
                _ = lx.close(@intCast(self.read_fd));
            } else {
                _ = sysc.close(self.read_fd);
            }
            self.read_fd = -1;
        }
        // 恢复默认处置，避免处理器指向已释放的全局状态。
        if (is_linux) {
            const act = lx.Sigaction{
                .handler = .{ .handler = lx.SIG.DFL },
                .mask = std.mem.zeroes(lx.sigset_t),
                .flags = 0,
            };
            _ = lx.sigaction(@fromBackingInt(@intCast(self.sig)), &act, null);
        } else {
            const act = sysc.Sigaction{
                .handler = .{ .handler = sysc.SIG.DFL },
                .mask = std.mem.zeroes(sysc.sigset_t),
                .flags = 0,
            };
            _ = sysc.sigaction(@fromBackingInt(@intCast(self.sig)), &act, null);
        }
    }

    fn run(w: *Work) void {
        const self: *Signal = @fieldParentPtr("work", w);
        var byte: [1]u8 = undefined;
        const n = if (is_linux)
            @as(isize, @bitCast(lx.read(@intCast(self.read_fd), &byte, 1)))
        else
            sysc.read(self.read_fd, &byte, 1);
        if (n <= 0) {
            self.err = error.ReadFailed;
            return;
        }
        // 哨兵字节（0 由 deinit 写入）：主动中止，非真实信号到达。
        if (byte[0] == 0) { self.err = error.Aborted; return; }
        self.received = self.sig;
    }

    /// 收到的信号编号；未收到或失败时返回错误。
    pub fn getResult(self: *const Signal) anyerror!u8 {
        if (self.err) |e| return e;
        return self.received orelse error.NotReceived;
    }
};
