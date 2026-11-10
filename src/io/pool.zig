//! `Work` 线程池：固定并发上限、显式停机、生命周期安全。
//!
//! 待办与已完成各走一个无锁 Treiber 栈（CAS 压入 / swap 排空），因此不需要
//! `std.Io.Mutex`（0.17 里它要一个 `std.Io` 句柄）。工作线程在首次提交时
//! 一次性启动、常驻到 `shutdown()`；空闲时短睡 1ms，不空转烧 CPU。
//! `shutdown()` 会 join 全部线程，因此 `Loop.deinit()` 之后绝不会再有线程
//! 触碰循环对象的内存。

const std = @import("std");
const builtin = @import("builtin");
const Work = @import("completion.zig").Work;

/// 空闲等待：Windows 用 `Sleep`，POSIX 用 `poll` 空集超时 1ms。
/// 不依赖 `std.Io` 句柄，也不占用整颗 CPU。
fn idleSleep() void {
    if (builtin.os.tag == .windows) {
        const k32 = struct {
            extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
        };
        k32.Sleep(1);
    } else {
        var fds: [0]std.posix.pollfd = .{};
        _ = std.posix.poll(&fds, 1) catch {};
    }
}
pub const default_max_workers = 4;

/// 把 `w` 压入栈顶。
fn push(stack: *std.atomic.Value(?*Work), w: *Work) void {
    var head = stack.load(.acquire);
    while (true) {
        w.next = head;
        head = stack.cmpxchgWeak(head, w, .acq_rel, .acquire) orelse break;
    }
}

pub const Pool = struct {
    pending: std.atomic.Value(?*Work) = std.atomic.Value(?*Work).init(null),
    done: std.atomic.Value(?*Work) = std.atomic.Value(?*Work).init(null),
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    started: bool = false,
    shut_down: bool = false,
    max_workers: usize = default_max_workers,
    threads: []std.Thread = &.{},
    thread_count: usize = 0,
    allocator: std.mem.Allocator,

    /// 用 `allocator` 记住线程句柄数组的归属；线程在首次 `submit` 时才启动。
    pub fn init(allocator: std.mem.Allocator, max_workers: usize) Pool {
        return .{ .allocator = allocator, .max_workers = max_workers };
    }

    /// 提交一个任务。`wake(ctx)` 在每个任务完成后调用，用来唤醒阻塞的循环。
    /// 停机后若已无工作线程，退化为在当前线程就地执行，保证任务不丢。
    pub fn submit(self: *Pool, w: *Work, wake: *const fn (*anyopaque) void, ctx: *anyopaque) void {
        if (self.stopping.load(.acquire)) {
            w.func(w);
            push(&self.done, w);
            return;
        }
        if (!self.started) self.start(wake, ctx);
        push(&self.pending, w);
    }

    fn start(self: *Pool, wake: *const fn (*anyopaque) void, ctx: *anyopaque) void {
        const n = @min(self.max_workers, 8);
        self.threads = self.allocator.alloc(std.Thread, n) catch {
            // 拿不到线程数组：保持未启动，任务将在停机或排空时兜底执行。
            return;
        };
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const t = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, worker, .{ self, wake, ctx }) catch break;
            self.threads[i] = t;
            self.thread_count += 1;
        }
        self.started = self.thread_count != 0;
        if (!self.started) self.allocator.free(self.threads);
    }

    fn worker(self: *Pool, wake: *const fn (*anyopaque) void, ctx: *anyopaque) void {
        while (!self.stopping.load(.acquire)) {
            var head = self.pending.swap(null, .acquire);
            if (head == null) {
                idleSleep();
                continue;
            }
            while (head) |w| {
                head = w.next;
                w.func(w);
                push(&self.done, w);
                wake(ctx);
            }
        }
        // 停机前把残余待办执行完，避免任务被静默丢弃。
        var head = self.pending.swap(null, .acquire);
        while (head) |w| {
            head = w.next;
            w.func(w);
            push(&self.done, w);
        }
    }

    /// 一次性取走全部已完成项（顺序与完成顺序相反，对回调无影响）。
    pub fn takeDone(self: *Pool) ?*Work {
        return self.done.swap(null, .acquire);
    }

    /// 停机：join 全部工作线程。返回后不再有线程触碰本池或循环对象。
    pub fn shutdown(self: *Pool) void {
        if (self.shut_down) return;
        self.shut_down = true;
        self.stopping.store(true, .release);
        if (self.started) {
            var i: usize = 0;
            while (i < self.thread_count) : (i += 1) self.threads[i].join();
            self.allocator.free(self.threads);
            self.threads = &.{};
            self.thread_count = 0;
        }
        // 若线程从未启动，兜底执行滞留任务。
        var head = self.pending.swap(null, .acquire);
        while (head) |w| {
            head = w.next;
            w.func(w);
            push(&self.done, w);
        }
    }

    pub fn deinit(self: *Pool) void {
        self.shutdown();
    }
};

test "空池取不到已完成项" {
    var p: Pool = .{ .allocator = std.testing.allocator };
    defer p.deinit();
    try std.testing.expectEqual(@as(?*Work, null), p.takeDone());
}

test "压入的项可全部取走" {
    var p: Pool = .{ .allocator = std.testing.allocator };
    defer p.deinit();
    var a: Work = .{ .func = undefined };
    var b: Work = .{ .func = undefined };
    push(&p.done, &a);
    push(&p.done, &b);
    const first = p.takeDone().?;
    var count: usize = 1;
    var cur = first.next;
    while (cur) |n| : (cur = n.next) count += 1;
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(?*Work, null), p.takeDone());
}

test "并发提交后停机，所有任务都执行" {
    const Ctx = struct {
        var count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
        fn run(w: *Work) void {
            _ = w;
            _ = count.fetchAdd(1, .monotonic);
        }
        fn wake(ctx: *anyopaque) void {
            _ = ctx;
        }
    };

    var p = Pool.init(std.testing.allocator, 4);
    var works: [32]Work = undefined;
    for (&works) |*w| w.* = .{ .func = Ctx.run };
    for (&works) |*w| p.submit(w, Ctx.wake, @ptrCast(&p));

    p.deinit();
    try std.testing.expectEqual(@as(usize, works.len), Ctx.count.load(.acquire));
    var n: usize = 0;
    var cur = p.takeDone();
    while (cur) |w| : (cur = w.next) n += 1;
    try std.testing.expectEqual(@as(usize, works.len), n);
}
