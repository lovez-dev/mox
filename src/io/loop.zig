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

/// 全局忽略 `SIGPIPE`。
///
/// 后端已经在每处发送上加了 `MSG_NOSIGNAL`（Linux）与 `SO_NOSIGPIPE`（BSD），
/// 这里是**第二道防线**：任何漏掉的写路径（标准库内部、第三方代码、写已关闭的
/// 管道）都只会得到 `EPIPE` 错误，而不是让整个进程被信号杀掉。
///
/// 只在第一次 `Loop` 初始化时设置；`SIG_IGN` 是进程级设置，重复设无害。
fn ignoreSigpipeOnce() void {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return;
    const S = struct {
        var done = std.atomic.Value(bool).init(false);
    };
    if (S.done.swap(true, .acq_rel)) return;

    if (builtin.os.tag == .linux) {
        // Linux 走裸 syscall，与 process.zig 同样的理由：不把 libc 拖进来。
        const lx = std.os.linux;
        const act = lx.Sigaction{
            .handler = .{ .handler = lx.SIG.IGN },
            .mask = std.mem.zeroes(lx.sigset_t),
            .flags = 0,
        };
        _ = lx.sigaction(lx.SIG.PIPE, &act, null);
        return;
    }
    // darwin / BSD 始终链 libSystem，直接用 libc 的 sigaction。
    const c = std.c;
    const act = c.Sigaction{
        .handler = .{ .handler = c.SIG.IGN },
        .mask = std.mem.zeroes(c.sigset_t),
        .flags = 0,
    };
    _ = c.sigaction(c.SIG.PIPE, &act, null);
}
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
const Async = completion.Async;

/// 一次 `waitBatch` 最多收割的完成包数。
pub const batch_size = 256;
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
    /// 在飞操作数（已下发给后端、完成包还没回来）。
    ///
    /// **这是硬性背压，不是调优参数。** io_uring 的 CQ 环容量有限，后端只能
    /// 缓存这么多完成包；一次 `add` 上万个操作时 CQ 必满，内核随即**丢弃**
    /// 后续完成包（实测 add 5000 个读操作，`sq_head` 推进到 5000 表示全部
    /// 消费，却只有 2048 个 CQE 回来，其余回调永不触发）。
    ///
    /// `add` 是同步 API，用户在两次调用之间没有机会收割，所以必须在这里
    /// 设窗口：满了就压进 `submitted`，由 `run` 每轮搬一部分进来。
    inflight: usize = 0,
    /// 在飞窗口大小。留足 CQ 余量，也保证「提交多少、收割多少」的节奏。
    inflight_max: usize = 1024,
    /// 延迟回收：被取消的操作所属的外层对象，等最后一个完成包回来再释放。
    /// 由调用方通过 `retire` 注册，键是 `Completion.ov` 的地址。
    retired: std.AutoHashMapUnmanaged(*Scratch, Retired) = .{},
    /// `drainRetired` 因超时提前返回的次数。正常关停应当为 0；
    /// 非零说明有完成包没能在预算内回来，context 归属已转交调用方。
    retired_timeouts: usize = 0,
    /// 进程内内存文件表，供静态路由挂载编译期资源 / 测试替身。
    /// 数组在堆上，`Loop` 按值拷贝不会让它悬空。
    memory_fs: @import("file.zig").MemoryFs = undefined,

    // 已完成、待在循环线程投递的 `Work`。无锁，且不依赖 std.Io。
    pool: Pool = .{ .allocator = undefined },

    /// 从 `io` 构造循环。线程池用 `allocator` 存放线程句柄；
    /// 后端不提供分配器时可用 `std.heap.page_allocator`。
    pub fn init(io: Io) Loop {
        return initWithAllocator(io, std.heap.page_allocator);
    }

    pub fn initWithAllocator(io: Io, allocator: std.mem.Allocator) Loop {
        return initWithOptions(io, allocator, .{});
    }

    /// 按 `Options` 构造循环。
    ///
    /// `inflight_max` 的推导是**硬性正确性约束**而不是调优：后端 CQ 环容量
    /// 是 `queue_size × 8`，窗口取它的一半（即 `queue_size × 4`），保证大批量
    /// 提交时完成包一定有地方放。用户显式给的值会被钳制到这个上限——
    /// 放开它只会让内核丢完成包、回调永不触发。
    pub fn initWithOptions(io: Io, allocator: std.mem.Allocator, opts: root.Options) Loop {
        ignoreSigpipeOnce();
        const workers = if (opts.max_workers == 0) pool_mod.default_max_workers else opts.max_workers;
        const cq_capacity: usize = @as(usize, opts.queue_size) * 8;
        const derived: usize = cq_capacity / 2;
        const inflight_cap: usize = if (opts.inflight_max) |v| @min(v, derived) else derived;

        var self: Loop = .{
            .io = io,
            .allocator = allocator,
            .pool = Pool.init(allocator, workers),
            .memory_fs = @import("file.zig").MemoryFs.init(allocator),
            .inflight_max = inflight_cap,
        };
        self.timers.initWithAllocator(self.allocator);
        return self;
    }

    /// 先停线程池再释放后端：保证 join 之后没有线程再写本循环的内存。
    pub fn deinit(self: *Loop) void {
        self.pool.shutdown();
        self.retired.deinit(self.allocator);
        self.timers.deinit();
        self.memory_fs.deinit();
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

    /// 从**任意线程**把一个回调投递到循环线程执行。
    ///
    /// 内部就是 `submit` + `notify`：压进 MPSC 栈，然后唤醒可能正在
    /// `waitBatch` 里阻塞的循环。`node` 必须在回调触发前一直有效
    /// （通常是调用方的成员变量；栈上的临时值只在其作用域内有效）。
    ///
    /// 回调里拿到的是 `Loop` 与 `*Async` 本身，可以继续 `add` 别的操作。
    pub fn postAsync(self: *Loop, node: *Async) void {
        self.submit(&node.c);
    }

    /// 循环线程取走跨线程提交项，按入队顺序逐个 `add`。
    /// 把一个操作压进跨线程待提交栈（`add` 超窗口时用）。
    fn enqueueSubmitted(self: *Loop, c: *Completion) void {
        var head = self.submitted.load(.acquire);
        while (true) {
            c.next = head;
            head = self.submitted.cmpxchgWeak(head, c, .acq_rel, .acquire) orelse break;
        }
        _ = self.submitted_count.fetchAdd(1, .monotonic);
    }

    /// 把跨线程提交的操作搬进循环。
    ///
    /// **搬到在飞窗口满为止**，剩下的留在 `submitted` 栈里等下一轮。这是
    /// 硬性背压：一次灌入上万个操作会把后端环灌爆，完成包被丢弃，回调
    /// 永不触发。
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
            if (c.op != .timer and c.op != .work and self.inflight >= self.inflight_max) {
                // 窗口满：这个和后面的都放回去，下轮再来。
                self.enqueueSubmitted(c);
                var rest = reversed;
                while (rest) |r| {
                    rest = r.next;
                    r.next = null;
                    self.enqueueSubmitted(r);
                }
                break;
            }
            self.add(c);
            count += 1;
        }
        _ = self.submitted_count.fetchSub(count, .monotonic);
    }
    /// 提交一个操作。回调可能在本调用内触发（同步完成），也可能稍后由 `run` 触发。
    pub fn add(self: *Loop, c: *Completion) void {
        // 在飞窗口满了：压进待提交栈，由 `run` 下一轮再处理。
        // 计时器与 work 不占窗口（它们不进后端环）。
        if (c.op != .timer and c.op != .work and c.op != .async) {
            if (self.inflight >= self.inflight_max) {
                self.enqueueSubmitted(c);
                return;
            }
            self.inflight += 1;
        }
        self.addRaw(c);
    }

    /// 不经窗口检查的提交。`drainSubmitted` 已自行控制节奏。
    fn addRaw(self: *Loop, c: *Completion) void {
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
                    self.pushReadySync(c);
                    return;
                };
                if (r) |n| {
                    c.bytes = n;
                    self.pushReadySync(c);
                }
            },

            .net_send => {
                const t: *NetSend = @fieldParentPtr("c", c);
                const r = self.io.vtable.send(self.io.userdata, t.socket, t.bytes_buffer, &c.ov) catch |e| {
                    c.err = e;
                    self.pushReadySync(c);
                    return;
                };
                if (r) |n| {
                    c.bytes = n;
                    self.pushReadySync(c);
                }
            },

            .net_accept => {
                const t: *NetAccept = @fieldParentPtr("c", c);
                const r = self.io.vtable.accept(self.io.userdata, t.listen, t.accept_socket, &t.addr_buf, &c.ov) catch |e| {
                    c.err = e;
                    self.pushReadySync(c);
                    return;
                };
                if (r) |_| self.pushReadySync(c); // pending is the normal case
            },

            .net_connect => {
                const t: *NetConnect = @fieldParentPtr("c", c);
                self.io.vtable.connect(self.io.userdata, t.socket, t.address, &c.ov) catch |e| {
                    c.err = e;
                    self.pushReadySync(c);
                    return;
                };
                // 尚未完成是常态
            },

            .net_close => {
                const t: *NetClose = @fieldParentPtr("c", c);
                self.io.vtable.close(self.io.userdata, t.socket);
                self.pushReadySync(c);
            },

            .net_shutdown => {
                const t: *root.NetShutdown = @fieldParentPtr("c", c);
                // `shutdown` 是同步的（只改连接状态，不排队数据），
                // 与 `.net_close` 同构：调完直接进就绪队列。
                const vt = self.io.vtable.shutdown orelse {
                    c.err = error.Unsupported;
                    self.pushReadySync(c);
                    return;
                };
                vt(self.io.userdata, t.socket, t.how) catch |e| {
                    c.err = e;
                };
                self.pushReadySync(c);
            },

            .net_sendmsg => {
                const t: *root.NetSendMsg = @fieldParentPtr("c", c);
                const vt = self.io.vtable.sendMsg orelse {
                    // 后端没有原生 sendmsg：回落成依次 send。语义等价，
                    // 只是失去「一次系统调用」的原子性（多路复用时可能
                    // 被其他写入插入，破坏帧边界）。
                    var total: usize = 0;
                    for (t.bufs) |b| {
                        const r = self.io.vtable.send(self.io.userdata, t.socket, b, &c.ov) catch |e| {
                            c.err = e;
                            self.pushReadySync(c);
                            return;
                        };
                        if (r) |n| {
                            total += n;
                            // 短写：剩下的部分这里不再续发。调用方应检查
                            // 返回值是否等于总长度。
                            if (n < b.len) break;
                        }
                    }
                    t.sent = total;
                    c.bytes = total;
                    self.pushReadySync(c);
                    return;
                };
                vt(self.io.userdata, t.socket, t.bufs, &t.hdr, &c.ov) catch |e| {
                    c.err = e;
                    self.pushReadySync(c);
                    return;
                };
            },

            .net_recvmsg => {
                const t: *root.NetRecvMsg = @fieldParentPtr("c", c);
                const vt = self.io.vtable.recvMsg orelse {
                    c.err = error.Unsupported;
                    self.pushReadySync(c);
                    return;
                };
                vt(self.io.userdata, t.socket, t.bufs, &t.hdr, &c.ov) catch |e| {
                    c.err = e;
                    self.pushReadySync(c);
                    return;
                };
            },

            .file_read => {
                const f: *root.ReadFileAsync = @fieldParentPtr("c", c);
                const vf = self.io.vtable.readFileAsync orelse {
                    c.err = error.Unsupported;
                    self.pushReadySync(c);
                    return;
                };
                const r = vf(self.io.userdata, @ptrCast(f.path.ptr), f.offset, f.buf, &c.ov) catch |e| {
                    c.err = e;
                    self.pushReadySync(c);
                    return;
                };
                if (r) |_| self.pushReadySync(c);
            },

            .file_write => {
                const f: *root.WriteFileAsync = @fieldParentPtr("c", c);
                const vf = self.io.vtable.writeFileAsync orelse {
                    c.err = error.Unsupported;
                    self.pushReadySync(c);
                    return;
                };
                const r = vf(self.io.userdata, @ptrCast(f.path.ptr), f.offset, f.bytes, &c.ov) catch |e| {
                    c.err = e;
                    self.pushReadySync(c);
                    return;
                };
                if (r) |_| self.pushReadySync(c);
            },

            .watch_fd => {
                const w: *root.WatchFd = @fieldParentPtr("c", c);
                const vtable_fn = self.io.vtable.watchFd orelse {
                    c.err = error.Unsupported;
                    self.pushReadySync(c);
                    return;
                };
                const r = vtable_fn(self.io.userdata, w.fd, w.want, &c.ov) catch |e| {
                    c.err = e;
                    self.pushReadySync(c);
                    return;
                };
                if (r) |_| self.pushReadySync(c); // 立即就绪；否则等后端投递
            },

            .udp_recv, .udp_send => {
                // 这两种操作由 `Udp` 自己向后端提交（它同时持有能力表和节点
                // 布局，不必反过来让 Loop 认识 UDP 节点）。回落到线程池时，
                // op 已被改回 `.work`，因此不会走到这里。
                @panic("UDP 操作通过 Udp.recv()/Udp.send() 提交，不要直接 loop.add");
            },

            .work => {
                const w: *Work = @fieldParentPtr("c", c);
                self.submitWork(w);
            },

            .async => {
                // 跨线程投递：已经在循环线程上了（走到 addRaw 说明是循环
                // 线程自己 add，或 drainSubmitted 搬进来的），直接排进就绪
                // 队列，下一轮 drainReady 执行回调。
                self.pushReadySync(c);
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

            // 主循环也给超时设上限，与 `drainOpen` 一致。否则当所有连接都挂着
            // 长 idle 定时器时（HTTP 默认 60s），`nextTimeout` 返回一个超大值，
            // `waitBatch` 的 `poll` 会睡满 60s；期间若有连接完成但新事件未到，
            // 整个 loop 被活锁——实测 HTTP 在 ~450 并发直接断崖。
            const timeout = @min(self.nextTimeout(), 200);
            const n = try self.io.vtable.waitBatch(self.io.userdata, timeout, &batch);
            self.fireTimers();
            if (!self.running) break;

            var i: usize = 0;
            while (i < n) : (i += 1) {
                self.completeOne(batch[i]);
                // 完成包回来就腾出在飞名额。计时器/work 不进后端，不会出现在
                // `batch` 里，所以这里每个 `Ref` 都对应一个占过名额的操作。
                if (self.inflight > 0) self.inflight -= 1;
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
        if (c.op == .file_read and c.err == null) {
            const f: *root.ReadFileAsync = @fieldParentPtr("c", c);
            f.len = ref.bytes;
        }
        if (c.op == .file_write and c.err == null) {
            const f: *root.WriteFileAsync = @fieldParentPtr("c", c);
            f.written = ref.bytes;
        }
        if (c.op == .watch_fd and c.err == null) {
            const w: *root.WatchFd = @fieldParentPtr("c", c);
            w.ready = root.Ready.fromBits(@truncate(ref.bytes));
        }
        if (c.op == .net_sendmsg and c.err == null) {
            const m: *root.NetSendMsg = @fieldParentPtr("c", c);
            m.sent = ref.bytes;
        }
        if (c.op == .net_recvmsg and c.err == null) {
            const m: *root.NetRecvMsg = @fieldParentPtr("c", c);
            m.received = ref.bytes;
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
        self.retired.put(self.allocator, &c.ov, .{
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
    /// 完成包对应一个被取消的操作：只回收对象，不回调。
    fn reclaim(self: *Loop, scratch: *Scratch) bool {
        const r = self.retired.fetchRemove(scratch) orelse return false;
        r.value.dispose(r.value.context);
        return true;
    }
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
        while (self.retired.count() != 0) {
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

    /// 停机后继续驱动循环，直到 `done(ctx)` 返回 true 或超过 `max_wait_ms`。
    ///
    /// 用于优雅关闭：`run()` 因 `stop()` 退出后，可能还有连接要收尾（取消
    /// 在飞操作、等它们的完成包回来释放内存）。这时需要把循环再跑起来，
    /// 让正常完成包（如 `NetClose`）的回调真正执行——`drainRetired` 只回收
    /// 取消项、不跑普通回调，所以不能替代本函数。
    ///
    /// 与 `run()` 的区别：不理会 `stop()`（停机关闭过程中回调再调 `stop`
    /// 不会打断收尾），退出条件完全由 `done` 与超时决定。超时是硬边界，
    /// 到期即返回，残留对象归属转交调用方。
    pub fn drainOpen(
        self: *Loop,
        max_wait_ms: u32,
        ctx: *anyopaque,
        done: *const fn (*anyopaque) bool,
    ) void {
        const start = self.io.vtable.now(self.io.userdata);
        var batch: [batch_size]Ref = undefined;
        while (!done(ctx)) {
            if (self.io.vtable.now(self.io.userdata) - start >= max_wait_ms) {
                self.running = false;
                return;
            }
            // 停机后仍要跑回调：置 running 为真，`drainReady` / `drainWork`
            // 里的 `if (!self.running) return` 才不会把收尾回调挡掉。
            self.running = true;
            self.drainSubmitted();
            self.drainReady();
            self.drainWork();
            // 轮询上限压到 50ms：保证能及时复查 `done` 与超时，不被一个
            // 「永远等待」的 waitBatch 卡死（停机时后端可能已无事件）。
            const timeout = @min(self.nextTimeout(), 50);
            const n = self.io.vtable.waitBatch(self.io.userdata, timeout, &batch) catch {
                self.running = false;
                return;
            };
            self.fireTimers();
            var i: usize = 0;
            while (i < n) : (i += 1) {
                self.completeOne(batch[i]);
                if (self.inflight > 0) self.inflight -= 1;
            }
        }
        self.running = false;
    }

    pub fn stop(self: *Loop) void {
        self.running = false;
        // 主动唤醒可能正睡在 waitBatch 里的循环，让停机即时生效（否则最多等 200ms）。
        self.io.vtable.notify(self.io.userdata);
    }

    /// 把套接字的 I/O（以及其上投递的 AcceptEx）路由到本后端。
    /// 监听套接字必须先关联再接受。
    pub fn associate(self: *Loop, socket: Handle, key: usize) !void {
        try self.io.vtable.associate(self.io.userdata, socket, key);
    }

    /// 零拷贝把文件送进 socket（阻塞，`sendfile`）。不支持时返回
    /// `error.Unsupported`。异步场景请用 `SendFile` 节点。
    pub fn sendFile(self: *Loop, socket: Handle, path: []const u8, offset: u64, count: usize) !usize {
        const f = self.io.vtable.sendFileTo orelse return error.Unsupported;
        return f(self.io.userdata, socket, path, offset, count);
    }

    /// 建一个 Unix domain socket（`AF_UNIX` + `SOCK_STREAM`）。
    /// 后端不支持时（Windows）返回 `error.Unsupported`。
    pub fn createUnixSocket(self: *Loop) !Handle {
        const f = self.io.vtable.createUnix orelse return error.Unsupported;
        return f(self.io.userdata);
    }

    /// 把 UDS 绑到文件系统路径。路径已存在时返回 `error.PathAlreadyExists`。
    pub fn bindUnix(self: *Loop, socket: Handle, path: []const u8) !void {
        const f = self.io.vtable.bindUnix orelse return error.Unsupported;
        return f(self.io.userdata, socket, path);
    }

    /// 连到 UDS。不支持时返回 `error.Unsupported`。
    pub fn connectUnix(self: *Loop, socket: Handle, path: []const u8, scratch: *Scratch) !void {
        const f = self.io.vtable.connectUnix orelse return error.Unsupported;
        _ = try f(self.io.userdata, socket, path, scratch);
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

    /// 挂载一个内存文件（通常是编译期常量或测试替身）。路径按字节精确匹配；
    /// `bytes` 的生命周期必须长于本循环，这里不复制。
    pub fn mountMemory(self: *Loop, path: []const u8, bytes: []const u8) !void {
        try self.memory_fs.mount(path, bytes);
    }

    /// 返回文件字节数，供静态文件响应分配缓冲区。内存文件命中时直接返回
    /// 其长度，不触碰磁盘；未命中才回落到后端的 `fileSize`。
    pub fn fileSize(self: *Loop, path: []const u8) !u64 {
        if (self.memory_fs.size(path)) |n| return n;
        return self.io.vtable.fileSize(self.io.userdata, path);
    }


    // ---- 可观测接口 ---------------------------------------------------------

    /// 返回当前在飞操作数（已提交到后端、尚未收到完成包的非 timer/work 操作）。
    pub fn inflightCount(self: *const Loop) usize {
        return self.inflight;
    }

    /// 返回待触发的定时器数量（包括普通定时器和 watchdog 定时器）。
    pub fn pendingTimers(self: *const Loop) usize {
        return self.timers.items.items.len;
    }

    /// 返回已登记、待回收的取消项数量。正常停机后应为 0；非零说明有完成包未能在预算内回来。
    pub fn pendingRetired(self: *const Loop) usize {
        return self.retired.count();
    }
    // ---- 目录与元数据（阻塞调用，在 `Work` 池线程里跑才不卡循环） ----------
    //
    // 这些是**同步**入口：直接调平台层，会阻塞当前线程。放在 `Loop` 上是为了
    // 让 `Work` 节点内部能拿到同一个 `io`；用户代码在循环线程里直接调用会卡住
    // 整个循环，异步场景请用 `MakeDir` / `RemoveDir` 等节点。

    pub fn makeDir(self: *Loop, path: []const u8, mode: u32) !void {
        return self.io.vtable.makeDir(self.io.userdata, path, mode);
    }

    pub fn removeDir(self: *Loop, path: []const u8) !void {
        return self.io.vtable.removeDir(self.io.userdata, path);
    }

    pub fn rename(self: *Loop, old_path: []const u8, new_path: []const u8) !void {
        return self.io.vtable.rename(self.io.userdata, old_path, new_path);
    }

    pub fn symLink(self: *Loop, target: []const u8, link_path: []const u8) !void {
        return self.io.vtable.symLink(self.io.userdata, target, link_path);
    }

    pub fn statPath(self: *Loop, path: []const u8) !root.Stat {
        return self.io.vtable.statPath(self.io.userdata, path);
    }

    pub fn listDir(self: *Loop, path: []const u8, buf: []root.DirEntry) !usize {
        return self.io.vtable.listDir(self.io.userdata, path, buf);
    }

    /// 同步整文件写入（阻塞）。`WriteFile` 节点内部也走这条路。
    pub fn writeFileAll(self: *Loop, path: []const u8, bytes: []const u8) !void {
        return self.io.vtable.writeFileAll(self.io.userdata, path, bytes);
    }

    /// 同步删除文件（阻塞）。平台层吞掉所有失败，因此这里不会报错。
    pub fn deleteFile(self: *Loop, path: []const u8) void {
        self.io.vtable.deleteFile(self.io.userdata, path) catch {};
    }

    // ---- 内部实现 ---------------------------------------------------------

    fn invoke(self: *Loop, c: *Completion) void {
        if (c.cancelled) {
            _ = self.reclaim(&c.ov);
            return;
        }
        // 操作正常完成：先撤销它的截止时间定时器，再回调。
        // 「先撤销」保证回调里可安全释放对象（watchdog 不会再碰到它）。
        self.unwatchdog(c);
        // `.async` 走自己的函数指针（签名不同：不带 Loop 参数，
        // 而是 user ctx）。其余操作走统一的 `callback`。
        if (c.op == .async) {
            const a: *Async = @fieldParentPtr("c", c);
            a.func(a.ctx, a);
            return;
        }
        if (c.callback) |cb| cb(self, c);
    }

    /// 给已提交的操作挂一个截止时间（毫秒）。到点时若操作仍未完成，
    /// 它的回调会带着 `error.DeadlineExceeded` 被调用一次；此后后端投递的
    /// 完成包被静默丢弃，对象仍归调用方。
    ///
    /// `timer` 由调用方持有，生命周期必须覆盖 `ms` 或直到操作完成——
    /// 与其它完成节点一样，`Loop` 不分配、不释放它。返回值是给调用方
    /// 在未超时前主动撤销用的句柄（传回 `unwatchdog`）。
    ///
    /// 一个操作只能挂一个 watchdog；重复挂会覆盖前一个（旧定时器被摘除）。
    pub fn watchdog(self: *Loop, c: *Completion, timer: *Timer, ms: u64) void {
        self.unwatchdog(c);
        timer.duration_ms = ms;
        timer.target = c;
        // 与 `Loop.add` 的 `.timer` 分支一致：堆按 `deadline_ms` 排序，
        // 漏设会让定时器永远「已到期」，操作被误判超时。
        timer.c.deadline_ms = self.io.vtable.now(self.io.userdata) + ms;
        c.timeout = &timer.c;
        self.timers.add(&timer.c);
    }

    /// 主动撤销截止时间（例如调用方自己决定放弃等待）。操作本身不受影响。
    pub fn unwatchdog(self: *Loop, c: *Completion) void {
        const t = c.timeout orelse return;
        c.timeout = null;
        if (self.timers.remove(t)) {
            const node: *Timer = @fieldParentPtr("c", t);
            node.target = null;
        }
    }

    fn pushReady(self: *Loop, c: *Completion) void {
        self.ready.push(c);
    }

    /// addRaw 同步完成路径专用。
    ///
    /// `add` 对所有非 timer/work 操作预增 `inflight`，但 `inflight -= 1` 只发生
    /// 在 `run` 主循环的 `completeOne` 路径（来自 `waitBatch` 的异步完成包）。
    /// 同步完成的操作不进后端队列，永远不会出现在 `batch` 里，故必须在此补减，
    /// 否则每次同步完成都泄漏 +1，最终堆满窗口导致循环冻结。
    fn pushReadySync(self: *Loop, c: *Completion) void {
        if (c.op != .timer and c.op != .work and c.op != .async) {
            if (self.inflight > 0) self.inflight -= 1;
        }
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
            // `watchdog` 定时器：到点时若目标还没完成，就通知后端放弃在飞
            // 操作、把 `DeadlineExceeded` 交给目标的回调。目标自己先完成的
            // 情况已在 `unwatchdog` 撤销本定时器，不会走到这里。
            //
            // 这里**不**走 `cancel`：`cancel` 会登记延迟回收并释放对象，而
            // 超时后对象仍归调用方（要靠 `getResult()` 读错误）。改为把
            // `callback` 置空：后端最终投递的完成包会因无回调被静默丢弃，
            // 对象不被框架释放、也不会重复回调。
            if (c.op == .timer) {
                const t: *Timer = @fieldParentPtr("c", c);
                if (t.target) |target| {
                    t.target = null;
                    target.timeout = null;
                    if (!target.cancelled) {
                        self.io.vtable.cancel(self.io.userdata, target.socket, &target.ov);
                        target.err = error.DeadlineExceeded;
                        const cb = target.callback;
                        target.callback = null;
                        if (cb) |f| f(self, target);
                    }
                    continue; // watchdog 定时器已处理，不再走普通回调路径。
                }
            }
            self.invoke(c);
            if (!self.running) return;
        }
    }

    fn nextTimeout(self: *Loop) u32 {
        return self.timers.nextTimeout(self.io.vtable.now(self.io.userdata), !self.ready.isEmpty());
    }
};
