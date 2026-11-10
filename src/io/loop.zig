//! 事件循环引擎：驱动一个 `Io` 的完成 / 回调循环，与具体平台无关。
//!
//! 只通过 `io.vtable.*` 与后端交互；定时器、就绪队列、`Work` 线程池
//! 分别委托给 `timer.zig` / `queue.zig` / `pool.zig`。
const std = @import("std");
const net = std.Io.net;
const root = @import("io.zig");
const completion = @import("completion.zig");
const queue_mod = @import("queue.zig");
const timer_mod = @import("timer.zig");
const pool_mod = @import("pool.zig");

const Io = root.Io;
const Scratch = root.Scratch;
const Ref = root.Ref;
const Handle = root.Handle;
const INVALID_HANDLE = root.INVALID_HANDLE;
const SockOpt = root.SockOpt;
const platform = root.platform;
const Queue = queue_mod.Queue;
const TimerQueue = timer_mod.TimerQueue;
const Pool = pool_mod.Pool;
const Completion = completion.Completion;
const Op = completion.Op;
const Timer = completion.Timer;
const NetRecv = completion.NetRecv;
const NetSend = completion.NetSend;
const NetClose = completion.NetClose;
const NetAccept = completion.NetAccept;
const NetConnect = completion.NetConnect;
const Work = completion.Work;

/// 一次 `waitBatch` 最多收割的完成包数。
pub const batch_size = 64;
/// 延迟回收项：一个被取消的操作 + 它所属对象的释放函数。
pub const Retired = struct {
    scratch: *Scratch,
    context: *anyopaque,
    dispose: *const fn (*anyopaque) void,
};

pub const Loop = struct {
    io: Io,
    allocator: std.mem.Allocator,
    /// 待触发定时器，按截止时间升序。
    timers: TimerQueue = .{},
    /// 等待回调的同步完成，按序。
    ready: Queue = .{},
    running: bool = true,

    /// 跨线程提交队列（MPSC Treiber 栈）。任意线程可 `submit`，
    /// 循环线程在 `drainSubmitted` 里 `swap` 取走后逐个 `add`。
    submitted: std.atomic.Value(?*Completion) = std.atomic.Value(?*Completion).init(null),
    /// 已入队但尚未被循环线程取走的项数，仅用于诊断与测试。
    submitted_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// 延迟回收：被取消的操作所属的外层对象，等最后一个完成包回来再释放。
    /// 由调用方通过 `retire` 注册，键是 `Completion.ov` 的地址。
    retired: std.ArrayListUnmanaged(Retired) = .empty,
    /// `drainRetired` 因超时提前返回的次数。正常关停应当为 0；
    /// 非零说明有完成包没能在预算内回来，context 归属已转交调用方。
    retired_timeouts: usize = 0,

    // 已完成、待在循环线程投递的 `Work`。无锁，且不依赖 std.Io。
    pool: Pool = .{ .allocator = undefined },

    /// 从 `io` 构造循环。线程池用 `allocator` 存放线程句柄；
    /// 后端不提供分配器时可用 `std.heap.page_allocator`。
    pub fn init(io: Io) Loop {
        var self: Loop = .{ .io = io, .allocator = std.heap.page_allocator, .pool = Pool.init(std.heap.page_allocator, pool_mod.default_max_workers) };
        self.timers.initWithAllocator(self.allocator);
        return self;
    }

    pub fn initWithAllocator(io: Io, allocator: std.mem.Allocator) Loop {
        var self: Loop = .{ .io = io, .allocator = allocator, .pool = Pool.init(allocator, pool_mod.default_max_workers) };
        self.timers.initWithAllocator(self.allocator);
        return self;
    }

    /// 先停线程池再释放后端：保证 join 之后没有线程再写本循环的内存。
    pub fn deinit(self: *Loop) void {
        self.pool.shutdown();
        self.retired.deinit(self.allocator);
        self.timers.deinit();
        self.io.vtable.deinit(self.io.userdata);
    }

    /// 从任意线程提交一个操作。节点压入无锁栈后唤醒循环；
    /// 回调一定在循环线程触发。节点的 `next` 在入队期间被本栈占用，
    /// 因此提交期间不得把它挂到别处。
    pub fn submit(self: *Loop, c: *Completion) void {
        var head = self.submitted.load(.acquire);
        while (true) {
            c.next = head;
            head = self.submitted.cmpxchgWeak(head, c, .acq_rel, .acquire) orelse break;
        }
        _ = self.submitted_count.fetchAdd(1, .monotonic);
        self.io.vtable.notify(self.io.userdata);
    }

    /// 循环线程取走跨线程提交项，按入队顺序逐个 `add`。
    fn drainSubmitted(self: *Loop) void {
        var head: ?*Completion = self.submitted.swap(null, .acquire);
        if (head == null) return;
        // Treiber 栈是 LIFO；本地反转成 FIFO，避免后提交的操作饿死。
        var reversed: ?*Completion = null;
        while (head) |c| {
            head = c.next;
            c.next = reversed;
            reversed = c;
        }
        var count: usize = 0;
        while (reversed) |c| {
            reversed = c.next;
            c.next = null;
            self.add(c);
            count += 1;
        }
        _ = self.submitted_count.fetchSub(count, .monotonic);
    }
    /// 提交一个操作。回调可能在本调用内触发（同步完成），也可能稍后由 `run` 触发。
    pub fn add(self: *Loop, c: *Completion) void {
        switch (c.op) {
            .timer => {
                const t: *Timer = @fieldParentPtr("c", c);
                c.deadline_ms = self.io.vtable.now(self.io.userdata) + t.duration_ms;
                self.timerAdd(c);
            },

            .net_recv => {
                const t: *NetRecv = @fieldParentPtr("c", c);
                const r = self.io.vtable.recv(self.io.userdata, t.socket, t.buffer, &c.ov) catch |e| {
                    c.err = e;
                    self.pushReady(c);
                    return;
                };
                if (r) |n| {
                    c.bytes = n;
                    self.pushReady(c);
                }
            },

            .net_send => {
                const t: *NetSend = @fieldParentPtr("c", c);
                const r = self.io.vtable.send(self.io.userdata, t.socket, t.bytes_buffer, &c.ov) catch |e| {
                    c.err = e;
                    self.pushReady(c);
                    return;
                };
                if (r) |n| {
                    c.bytes = n;
                    self.pushReady(c);
                }
            },

            .net_accept => {
                const t: *NetAccept = @fieldParentPtr("c", c);
                const r = self.io.vtable.accept(self.io.userdata, t.listen, t.accept_socket, &t.addr_buf, &c.ov) catch |e| {
                    c.err = e;
                    self.pushReady(c);
                    return;
                };
                if (r) |_| self.pushReady(c); // pending is the normal case
            },

            .net_connect => {
                const t: *NetConnect = @fieldParentPtr("c", c);
                self.io.vtable.connect(self.io.userdata, t.socket, t.address, &c.ov) catch |e| {
                    c.err = e;
                    self.pushReady(c);
                    return;
                };
                // 尚未完成是常态
            },

            .net_close => {
                const t: *NetClose = @fieldParentPtr("c", c);
                self.io.vtable.close(self.io.userdata, t.socket);
                self.pushReady(c);
            },

            .udp_recv, .udp_send => {
                // 这两种操作由 `Udp` 自己向后端提交（它同时持有能力表和节点
                // 布局，不必反过来让 Loop 认识 UDP 节点）。回落到线程池时，
                // op 已被改回 `.work`，因此不会走到这里。
                unreachable;
            },

            .work => {
                const w: *Work = @fieldParentPtr("c", c);
                self.submitWork(w);
            },
        }
    }

    /// 运行到调用 `stop` 为止。
    pub fn run(self: *Loop) !void {
        self.running = true;
        // 一次 syscall 收割多个完成包，摊薄系统调用开销。
        var batch: [batch_size]Ref = undefined;
        while (self.running) {
            self.drainSubmitted();
            self.drainReady();
            self.drainWork();
            if (!self.running) break;

            const timeout = self.nextTimeout();
            const n = try self.io.vtable.waitBatch(self.io.userdata, timeout, &batch);
            self.fireTimers();
            if (!self.running) break;

            var i: usize = 0;
            while (i < n) : (i += 1) {
                self.completeOne(batch[i]);
                if (!self.running) break;
            }
        }
    }

    /// 处理一个完成包：取消项只回收，正常项回填结果并回调。
    fn completeOne(self: *Loop, ref: Ref) void {
        const c: *Completion = @fieldParentPtr("ov", ref.scratch);
        if (c.cancelled) {
            _ = self.reclaim(ref.scratch);
            return;
        }
        c.bytes = ref.bytes;
        // 失败的操作（连接重置、中止）不能伪装成「0 字节正常结束」。
        if (ref.failed) c.err = error.IoFailed;
        if (c.op == .net_accept and c.err == null) {
            const a: *NetAccept = @fieldParentPtr("c", c);
            if (ref.new_handle != INVALID_HANDLE) a.accept_socket = ref.new_handle;
            self.io.vtable.updateAccept(self.io.userdata, a.listen, a.accept_socket);
        }
        if (c.op == .net_connect and c.err == null) {
            const a: *NetConnect = @fieldParentPtr("c", c);
            self.io.vtable.updateConnect(self.io.userdata, a.socket);
        }
        self.invoke(c);
    }

    /// 取消一个操作并释放它所属的对象。
    ///
    /// 统一登记到 `retired` 并标记 `cancelled`：任何路径（就绪队列、定时器、
    /// `Work` 完成、内核完成包）取到该节点时都直接 `dispose`，不回调、不回填。
    /// 有内核在飞操作时再通知后端取消；无内核操作由定时器堆摘除或等下一次
    /// `invoke` 自然回收，因此不会卡在 `drainRetired` 超时上。
    pub fn cancel(self: *Loop, c: *Completion, ctx: *anyopaque, dispose: *const fn (*anyopaque) void) void {
        c.cancelled = true;
        self.retired.append(self.allocator, .{
            .scratch = &c.ov,
            .context = ctx,
            .dispose = dispose,
        }) catch {
            // 登记表分配失败：完成包到达时按普通取消丢弃，不回调。
        };
        // 定时器还在堆里：摘掉后没有别的东西会再引用它，立即回收。
        if (c.op == .timer and self.timers.remove(c)) {
            _ = self.reclaim(&c.ov);
            return;
        }
        // 节点自己携带 fd：`timer` / `work` 是 INVALID_HANDLE，后端据此
        // 判断无需取消任何在飞操作。
        self.io.vtable.cancel(self.io.userdata, c.socket, &c.ov);
    }

    /// 完成包对应一个被取消的操作：只回收对象，不回调。
    fn reclaim(self: *Loop, scratch: *Scratch) bool {
        var i: usize = 0;
        while (i < self.retired.items.len) : (i += 1) {
            if (self.retired.items[i].scratch != scratch) continue;
            const r = self.retired.orderedRemove(i);
            r.dispose(r.context);
            return true;
        }
        return false;
    }
    /// 停机后排空所有已登记的取消项：继续批量取完成包直到登记表为空。
    /// 停机后排空所有已登记的取消项：继续批量取完成包直到登记表为空。
    /// `Server` 的 `NetAccept` 在栈上，必须等它回收完才能让 `serve` 返回。
    ///
    /// **超时行为（明确契约）**：`max_wait_ms` 到点后本函数直接返回，
    /// 不再等待。此时仍留在 `retired` 里的节点**没有**被 `dispose`——
    /// 它们的 `context`（例如栈上的 `NetAccept`）仍然有效，但对象归属
    /// 转交给调用方：调用方必须在自身作用域结束前保证这些 context 不被
    /// 释放，否则就是悬垂指针。`Loop.deinit` 不会替它们收尾，也不报错，
    /// 因为后端可能在进程退出前才投递最后一个完成包。
    ///
    /// 超时是**可观测**的：发生时会自增 `retired_timeouts`，调用方可以
    /// 据此断言"正常关停不该超时"，而不是靠日志猜测。
    pub fn drainRetired(self: *Loop, max_wait_ms: u32) void {
        const start = self.io.vtable.now(self.io.userdata);
        var batch: [batch_size]Ref = undefined;
        while (self.retired.items.len != 0) {
            if (self.io.vtable.now(self.io.userdata) - start >= max_wait_ms) {
                self.retired_timeouts += 1;
                return;
            }
            const n = self.io.vtable.waitBatch(self.io.userdata, 50, &batch) catch return;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const c: *Completion = @fieldParentPtr("ov", batch[i].scratch);
                if (c.cancelled) {
                    _ = self.reclaim(batch[i].scratch);
                } else {
                    // 停机后不应再有非取消项；忽略以免回调到已失效状态。
                }
            }
        }
    }

    pub fn stop(self: *Loop) void {
        self.running = false;
    }

    /// 把套接字的 I/O（以及其上投递的 AcceptEx）路由到本后端。
    /// 监听套接字必须先关联再接受。
    pub fn associate(self: *Loop, socket: Handle, key: usize) !void {
        try self.io.vtable.associate(self.io.userdata, socket, key);
    }

    /// 创建一个与 `address` 同族、可用于重叠 I/O 的 TCP 套接字。
    pub fn createSocket(self: *Loop, address: std.Io.net.IpAddress) !Handle {
        return self.io.vtable.createSocket(self.io.userdata, address);
    }

    /// 监听前设置 `SO_REUSEADDR`。
    pub fn setReuseAddress(self: *Loop, socket: Handle, on: bool) !void {
        try self.io.vtable.setReuseAddress(self.io.userdata, socket, on);
    }

    /// 设置一个套接字选项。后端未提供该能力时返回 `error.Unsupported`。
    pub fn setSockOpt(self: *Loop, socket: Handle, opt: SockOpt, value: u32) !void {
        const f = self.io.vtable.setSockOpt orelse return error.Unsupported;
        try f(self.io.userdata, socket, opt, value);
    }

    /// 半关闭发送方向：对端仍能读完已发出的数据，之后再 `close` 才是优雅收尾。
    pub fn shutdownSend(self: *Loop, socket: Handle) !void {
        const f = self.io.vtable.shutdownSend orelse return error.Unsupported;
        try f(self.io.userdata, socket);
    }

    /// 把套接字绑定到 `address`。
    pub fn bind(self: *Loop, socket: Handle, address: std.Io.net.IpAddress) !void {
        try self.io.vtable.bind(self.io.userdata, socket, address);
    }

    /// 开始监听。
    pub fn listen(self: *Loop, socket: Handle, backlog: c_int) !void {
        try self.io.vtable.listen(self.io.userdata, socket, backlog);
    }

    /// 关闭套接字（与 `NetClose` 走同一个后端入口）。
    pub fn close(self: *Loop, socket: Handle) void {
        self.io.vtable.close(self.io.userdata, socket);
    }

    /// 返回文件字节数，供静态文件响应分配缓冲区。
    pub fn fileSize(self: *Loop, path: []const u8) !u64 {
        return self.io.vtable.fileSize(self.io.userdata, path);
    }

    // ---- 内部实现 ---------------------------------------------------------

    fn invoke(self: *Loop, c: *Completion) void {
        if (c.cancelled) {
            _ = self.reclaim(&c.ov);
            return;
        }
        if (c.callback) |cb| cb(self, c);
    }

    fn pushReady(self: *Loop, c: *Completion) void {
        self.ready.push(c);
    }

    fn drainReady(self: *Loop) void {
        while (self.ready.pop()) |c| {
            self.invoke(c);
            if (!self.running) return;
        }
    }

    fn submitWork(self: *Loop, w: *Work) void {
        self.pool.submit(w, notifyFromPool, @ptrCast(self));
    }

    fn notifyFromPool(ctx: *anyopaque) void {
        const self: *Loop = @ptrCast(@alignCast(ctx));
        self.io.vtable.notify(self.io.userdata);
    }

    fn drainWork(self: *Loop) void {
        var head = self.pool.takeDone();
        while (head) |w| {
            head = w.next;
            self.invoke(&w.c);
            if (!self.running) return;
        }
    }

    fn timerAdd(self: *Loop, c: *Completion) void {
        self.timers.add(c);
    }

    fn fireTimers(self: *Loop) void {
        const now = self.io.vtable.now(self.io.userdata);
        while (self.timers.popDue(now)) |c| {
            self.invoke(c);
            if (!self.running) return;
        }
    }

    fn nextTimeout(self: *Loop) u32 {
        return self.timers.nextTimeout(self.io.vtable.now(self.io.userdata), !self.ready.isEmpty());
    }
};
