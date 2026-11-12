//! 完成节点类型族：调用方持有、内嵌在各操作结构体里的零分配节点。
//!
//! `Callback` 的签名带 `*Loop`，因此本文件与 `loop.zig` 互相 import；
//! 两边都只持有指针，Zig 的惰性分析下完全合法。

const std = @import("std");
const root = @import("mox_io.zig");
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
    watch_fd,
    file_read,
    file_write,
    work,
    /// 跨线程投递：别的线程把回调塞进循环，循环线程上执行。
    async,
    /// 分散聚合发送（`sendmsg`）。
    net_sendmsg,
    /// 分散聚合接收（`recvmsg`）。
    net_recvmsg,
    /// 全方向关闭（`shutdown`）。
    net_shutdown,
    /// 等 socket 可读/可写（`NetPoll`）。
    net_poll,
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

    /// 通过 `Loop.watchdog` 挂上的截止时间定时器（`op == .timer`）。
    /// 非空时：本操作正常完成会撤销它；它先到点则取消本操作。
    /// 双向链接（配合 `Timer.target`）让撤销是 O(1)、无需额外分配。
    timeout: ?*Completion = null,

    /// 在 `TimerQueue` 堆中的下标。仅当节点在定时器堆里时有效；
    /// 由 `TimerQueue` 在每次堆调整时维护，使 `remove` 从 O(n) 线性扫描
    /// 降为 O(log n)。不在堆中时值为 `std.math.maxInt(usize)`，避免
    /// 误用；同步完成 / 就绪队列路径不触碰它。
    heap_index: usize = std.math.maxInt(usize),

    /// 所属 `Group`（批量等待）。非空时 `Group.childCallback` 会在本操作
    /// 完成时递减计数。不影响操作本身的语义，纯粹是回调路由信息。
    group_ctx: ?*anyopaque = null,
};

/// 就绪方向。`watchFd` 用它在回调里告诉调用方「哪个方向就绪了」。
///
/// 用位标志而不是枚举，是因为同一个 fd 可能同时可读可写；调用方一次就能
/// 拿到全部信息，不必猜。
pub const Ready = packed struct(u8) {
    read: bool = false,
    write: bool = false,
    /// 对端已关闭 / 出错。多数平台会与 read 同时置位，调用方读一次拿到 EOF。
    /// 不叫 `error`：那是 Zig 关键字，字段名不能用它。
    failed: bool = false,
    hangup: bool = false,
    _pad: u4 = 0,

    pub fn bits(self: Ready) u8 {
        return @bitCast(self);
    }

    pub fn fromBits(v: u8) Ready {
        return @bitCast(v);
    }

    /// 任意方向就绪（`error` / `hangup` 也算，否则调用方会永远等下去）。
    pub fn any(self: Ready) bool {
        return self.read or self.write or self.failed or self.hangup;
    }
};

/// 把任意 fd（管道、串口、stdin）挂进事件循环等就绪。
///
/// 与 `NetRecv` / `NetSend` 的区别：那两个**替你收发**并回填字节数，本节点
/// 只**通知就绪**，数据仍由调用方自己 `read` / `write`。适合 mox 不认识其
/// 语义的 fd。
///
/// 一次性语义：回调触发后这次 watch 就失效，要再等必须重新 `loop.add`。
/// 这与后端普遍使用的 ONESHOT / EV_ONESHOT 一致，也避免同一个 fd 被重复
/// 通知淹没循环。
pub const WatchFd = struct {
    c: Completion = .{ .op = .watch_fd },
    fd: Handle,
    /// 想等哪个方向。
    want: Ready,
    /// 回填：实际就绪的方向。回调里读。
    ready: Ready = .{},

    pub fn init(fd: Handle, want: Ready) WatchFd {
        return .{ .fd = fd, .want = want };
    }
};

/// 等 socket 变成可读或可写。zio 里对应 `NetPoll`。
///
/// 与 `WatchFd` 的区别是**独立节点**而不是包装：Windows 上两者走完全不同的
/// 实现（`WatchFd` 对管道/控制台无解，socket 却有零字节重叠 I/O 的解法），
/// 包装会让那个差异无处安放。Linux/BSD 上后端把两者都映射到同一套就绪
/// 机制，调用方看不出区别。
///
/// 注意：**一次性**通知。回调触发后若要继续等，必须重新 `init` + `add`。
pub const NetPoll = struct {
    c: Completion = .{ .op = .net_poll },
    socket: Handle,
    /// 想等哪个方向。
    want: Ready,
    /// 回填：实际就绪的方向。回调里读。
    readiness: Ready = .{},

    pub const Event = enum { recv, send };

    pub fn init(socket: Handle, event: Event) NetPoll {
        return .{
            .socket = socket,
            .want = switch (event) {
                .recv => .{ .read = true },
                .send => .{ .write = true },
            },
        };
    }

    /// 拿到可提交的完成体。
    pub fn completion(self: *NetPoll) *Completion {
        return &self.c;
    }

    /// 回调里读：是否真的就绪了。
    pub fn ready(self: *const NetPoll) Ready {
        return self.readiness;
    }

    pub fn getResult(self: *const NetPoll) !void {
        if (self.c.err) |e| return e;
    }
};

/// io_uring 原生异步文件读。**只在 io_uring 后端可用**（其它后端
/// `vtable.readFileAsync` 为 `null`，调用方应回落 `ReadFile` 的 `Work` 版本）。
///
/// 内部把 openat → read → close 三条 SQE 链起来（`IOSQE_IO_LINK`），一次
/// 提交、一次完成。中间 fd 由内核在链内传递，不经过用户态。
pub const ReadFileAsync = struct {
    c: Completion = .{ .op = .file_read },
    path: []const u8,
    buf: []u8,
    /// 起始偏移；0 表示从头读。
    offset: u64 = 0,
    /// 回填：实际读到的字节数。
    len: usize = 0,

    /// `path` 必须 NUL 结尾（`openat` 的 SQE 直接读这块内存），且活到
    /// 回调触发为止。用 `initZ` 从普通切片复制到节点自带的缓冲更省心。
    pub fn init(path: [:0]const u8, buf: []u8) ReadFileAsync {
        return .{ .path = path, .buf = buf };
    }

    pub fn initAt(path: [:0]const u8, offset: u64, buf: []u8) ReadFileAsync {
        return .{ .path = path, .buf = buf, .offset = offset };
    }

    pub fn getResult(self: *const ReadFileAsync) ![]const u8 {
        if (self.c.err) |e| return e;
        return self.buf[0..self.len];
    }
};

/// io_uring 原生异步文件写（覆盖既有内容）。同 `ReadFileAsync`，仅 io_uring。
pub const WriteFileAsync = struct {
    c: Completion = .{ .op = .file_write },
    path: []const u8,
    bytes: []const u8,
    offset: u64 = 0,
    written: usize = 0,

    pub fn init(path: [:0]const u8, bytes: []const u8) WriteFileAsync {
        return .{ .path = path, .bytes = bytes };
    }

    pub fn getResult(self: *const WriteFileAsync) !usize {
        if (self.c.err) |e| return e;
        return self.written;
    }
};

pub const Timer = struct {
    c: Completion = .{ .op = .timer },
    duration_ms: u64,

    /// 由 `Loop.watchdog` 设置：本定时器到点时要取消的操作。
    /// 手动构造的普通定时器保持 `null`。
    target: ?*Completion = null,

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

/// 跨线程投递一个回调到循环线程执行。
///
/// 用途：任意线程（工作线程、信号处理旁路、别的服务线程）想把「某件事
/// 该在循环线程做了」告诉循环。没有它就只能靠 `Work` 池绕一圈——那要多
/// 一次线程切换，而且语义上是「去池里干活」而不是「回循环线程」。
///
/// 与 `Work` 的区别：`Work.func` 在**池线程**跑；`Async.func` 在**循环
/// 线程**跑。前者用于阻塞 I/O，后者用于「必须串行在循环线程上」的动作。
///
/// 线程安全：`Loop.postAsync` 可从任意线程调用；节点必须在回调触发前
/// 一直有效（通常是调用方的栈变量或成员）。
pub const Async = struct {
    c: Completion = .{ .op = .async },
    /// 在循环线程执行。参数是 `Loop` 与自身完成体。
    func: *const fn (?*anyopaque, *Async) void,
    /// 传给 `func` 的用户上下文。
    ctx: ?*anyopaque = null,
    /// 侵入式链接，串起跨线程投递栈。
    next: ?*Async = null,

    pub fn init(func: *const fn (?*anyopaque, *Async) void, ctx: ?*anyopaque) Async {
        return .{ .func = func, .ctx = ctx };
    }
};

/// 批量等待：把 N 个操作当成一个整体，全部完成时触发一次回调。
///
/// 用途：并发发起多个 I/O 后只想被通知一次（「全部好了告诉我」），而不是
/// 自己维护计数器、自己判断最后一个是谁。
///
/// 用法：
/// ```zig
/// var group = mox_io.Group.init(&onAllDone, ctx, 2);
/// recv1.c.callback = &Group.childCallback; recv1.c.group_ctx = &group;
/// recv2.c.callback = &Group.childCallback; recv2.c.group_ctx = &group;
/// loop.add(&recv1.c);
/// loop.add(&recv2.c);
/// ```
///
/// **语义要点**：
/// - 每个子操作完成时计数器递减；减到 0 时调用 `func`。
/// - 子操作的错误**不会**让 group 提前结束——即使某个子操作失败，也等其他
///   子操作都结束才回调。调用方要在回调里自己检查各子操作的结果。
/// - `pending` 只由循环线程访问（子操作回调都在循环线程），所以不需要原子。
pub const Group = struct {
    /// 还剩几个子操作未完成。
    pending: usize,
    /// 全部完成时调用。`ctx` 是构造时传进来的用户上下文。
    func: *const fn (?*anyopaque, *Group) void,
    ctx: ?*anyopaque = null,

    pub fn init(func: *const fn (?*anyopaque, *Group) void, ctx: ?*anyopaque, count: usize) Group {
        return .{ .pending = count, .func = func, .ctx = ctx };
    }

    /// 子操作的完成回调：递减计数，减到 0 时触发 group 回调。
    ///
    /// 直接把它赋给每个子操作的 `c.callback`，并设置 `c.group_ctx`。
    pub fn childCallback(loop: *@import("loop.zig").Loop, c: *Completion) void {
        _ = loop;
        const g: *Group = @ptrCast(@alignCast(c.group_ctx orelse return));
        if (g.pending > 0) g.pending -= 1;
        if (g.pending == 0) g.func(g.ctx, g);
    }

    /// 是否全部完成。
    pub fn done(self: *const Group) bool {
        return self.pending == 0;
    }
};

// ---- 分散聚合 I/O 与全方向关闭（阶段 E）----------------------------------

/// 后端私有暂存区大小（以 `usize` 计）。
///
/// 原生 `sendmsg`/`recvmsg` 要把 `msghdr` + `iovec` 数组放在**活到完成包
/// 被收割**的地方，不能是栈上临时变量。96 个字 = 768 字节：
/// `linux.msghdr_const` 56B + 32 个 `iovec_const`（16B each）512B = 568B，
/// 留有余量。**这个数字是被 comptime 断言逼出来的**——第一版写 64 个字
/// （512B）在 Linux 上直接编译失败，断言替我们算对了账。
pub const MSG_HDR_WORDS = 96;

/// 分散聚合发送：一次系统调用把多个缓冲发出去。
///
/// 用途：HTTP/2 帧头 + 载荷、WebSocket 帧头 + 载荷这类「必须连续但分属不同
/// 缓冲」的场景。分两次 `send` 也能work，但会有两个问题：两次系统调用之间
/// 可能被其他写入插入（多路复用时破坏帧边界），以及多一次内核态切换。
///
/// 后端不支持原生 `sendMsg` 时，节点层回落成「依次 `send`」——语义等价，
/// 只是没有原子性。
pub const NetSendMsg = struct {
    c: Completion = .{ .op = .net_sendmsg },
    socket: Handle = INVALID_HANDLE,
    /// 待发送的缓冲。**必须活到回调触发**。
    bufs: []const []const u8 = &.{},
    /// 后端私有暂存区（`msghdr` + `iovec`）。同样必须活到回调触发。
    hdr: [MSG_HDR_WORDS]usize = std.mem.zeroes([MSG_HDR_WORDS]usize),
    /// 回填：实际发出的总字节数。
    sent: usize = 0,

    pub fn init(socket: Handle, bufs: []const []const u8) NetSendMsg {
        return .{ .socket = socket, .bufs = bufs };
    }

    pub fn getResult(self: *const NetSendMsg) !usize {
        if (self.c.err) |e| return e;
        return self.sent;
    }
};

/// 分散聚合接收：一次系统调用把数据摊到多个缓冲。
///
/// 相比「先 `recv` 到一个大缓冲再手动切分」，省掉一次内存拷贝。典型场景是
/// 协议头与载荷分处两个缓冲、或想把固定长度的帧头单独解析。
pub const NetRecvMsg = struct {
    c: Completion = .{ .op = .net_recvmsg },
    socket: Handle = INVALID_HANDLE,
    /// 接收缓冲。**必须活到回调触发**。
    bufs: []const []u8 = &.{},
    /// 后端私有暂存区。
    hdr: [MSG_HDR_WORDS]usize = std.mem.zeroes([MSG_HDR_WORDS]usize),
    /// 回填：实际收到的总字节数。
    received: usize = 0,

    pub fn init(socket: Handle, bufs: []const []u8) NetRecvMsg {
        return .{ .socket = socket, .bufs = bufs };
    }

    pub fn getResult(self: *const NetRecvMsg) !usize {
        if (self.c.err) |e| return e;
        return self.received;
    }
};

/// 全方向关闭。
///
/// 与 `NetClose` 的区别：`shutdown` 只改连接状态、不释放句柄，之后仍可以
/// `recv` 探测对端是否已关（读到 0 字节），也可以正常 `close`。
pub const NetShutdown = struct {
    c: Completion = .{ .op = .net_shutdown },
    socket: Handle = INVALID_HANDLE,
    how: root.ShutdownHow,

    pub fn init(socket: Handle, how: root.ShutdownHow) NetShutdown {
        return .{ .socket = socket, .how = how };
    }

    pub fn getResult(self: *const NetShutdown) !void {
        if (self.c.err) |e| return e;
    }
};
