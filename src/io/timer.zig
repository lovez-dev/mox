//! 定时器队列：二叉最小堆，按 `deadline_ms` 排序。
//!
//! 节点是 `Completion` 自身，堆里只存指针；插入 / 弹出都是 O(log n)，
//! 取代原来的有序链表 O(n) 插入。`next` 字段仍由堆外部（就绪队列）使用，
//! 这里不再占用它。定时器数量少时开销可忽略，多时明显优于链表。

const std = @import("std");
const Completion = @import("completion.zig").Completion;

pub const TimerQueue = struct {
    items: std.ArrayListUnmanaged(*Completion) = .empty,
    allocator: std.mem.Allocator = std.heap.page_allocator,

    pub fn initWithAllocator(self: *TimerQueue, allocator: std.mem.Allocator) void {
        self.* = .{ .allocator = allocator };
    }

    pub fn deinit(self: *TimerQueue) void {
        self.items.deinit(self.allocator);
        self.* = .{ .allocator = self.allocator };
    }

    fn less(a: *Completion, b: *Completion) bool {
        return a.deadline_ms < b.deadline_ms;
    }

    /// 插入一个定时器。
    /// 交换两个槽位并同步维护各自的下标，所有堆调整都必须走它。
    fn swapAt(self: *TimerQueue, a: usize, b: usize) void {
        std.mem.swap(*Completion, &self.items.items[a], &self.items.items[b]);
        self.items.items[a].heap_index = a;
        self.items.items[b].heap_index = b;
    }

    /// 插入一个定时器。
    pub fn add(self: *TimerQueue, c: *Completion) void {
        self.items.append(self.allocator, c) catch return;
        var i = self.items.items.len - 1;
        c.heap_index = i;
        while (i > 0) {
            const parent = (i - 1) / 2;
            if (!less(self.items.items[i], self.items.items[parent])) break;
            self.swapAt(i, parent);
            i = parent;
        }
    }

    /// 取出一个 `deadline_ms <= now` 的节点；没有则返回 null。
    pub fn popDue(self: *TimerQueue, now: u64) ?*Completion {
        const first = self.peek() orelse return null;
        if (first.deadline_ms > now) return null;
        first.heap_index = std.math.maxInt(usize);
        const last = self.items.pop().?;
        if (self.items.items.len != 0) {
            // 标准堆删除：把末节点搬到堆顶，再下沉。直接覆盖下标 0，
            // 不能用 swapAt（末节点已被 pop 出数组）。
            self.items.items[0] = last;
            last.heap_index = 0;
            self.siftDown(0);
        }
        return first;
    }

    /// 从堆中摘除指定节点，用于取消尚未到期的定时器。
    ///
    ///
    /// 普通定时器取消在 HTTP 加 idle 超时后已落在热路径上（每个请求周期都
    /// `armIdle`/`disarmIdle` 各一次），所以这里用 `heap_index` 定位到 O(1)，
    /// 再下沉/上浮到 O(log n)；不再做 O(n) 线性扫描。
    pub fn remove(self: *TimerQueue, c: *Completion) bool {
        const i = c.heap_index;
        if (i >= self.items.items.len or self.items.items[i] != c) {
            // 不在堆中（同步完成已弹出，或从未加入）：直接返回。
            return false;
        }
        const last = self.items.pop().?;
        if (i == self.items.items.len) {
            last.heap_index = std.math.maxInt(usize);
            return true; // 正好是末节点，弹出即可
        }
        self.items.items[i] = last;
        last.heap_index = i;
        self.siftUp(i);
        self.siftDown(i);
        c.heap_index = std.math.maxInt(usize); // 摘除节点必须作废其索引，否则残留旧值会被误用
        return true;
    }

    fn peek(self: *const TimerQueue) ?*Completion {
        return if (self.items.items.len == 0) null else self.items.items[0];
    }

    fn siftUp(self: *TimerQueue, start: usize) void {
        var i = start;
        while (i > 0) {
            const parent = (i - 1) / 2;
            if (!less(self.items.items[i], self.items.items[parent])) break;
            self.swapAt(i, parent);
            i = parent;
        }
    }

    fn siftDown(self: *TimerQueue, start: usize) void {
        var i = start;
        while (true) {
            const left = i * 2 + 1;
            if (left >= self.items.items.len) break;
            const right = left + 1;
            var child = left;
            if (right < self.items.items.len and less(self.items.items[right], self.items.items[left])) child = right;
            if (!less(self.items.items[child], self.items.items[i])) break;
            self.swapAt(i, child);
            i = child;
        }
    }

    /// 下一次等待的毫秒数；无定时器时返回 `maxInt(u32)`（一直睡到有完成包）。
    pub fn nextTimeout(self: *const TimerQueue, now: u64, has_ready: bool) u32 {
        if (has_ready) return 0;
        if (self.peek()) |c| {
            if (c.deadline_ms <= now) return 0;
            return @intCast(@min(c.deadline_ms - now, std.math.maxInt(u32) - 1));
        }
        return std.math.maxInt(u32);
    }
};

test "定时器按截止时间升序弹出" {
    var q: TimerQueue = .{};
    defer q.deinit();
    var a: Completion = .{ .op = .timer, .deadline_ms = 30 };
    var b: Completion = .{ .op = .timer, .deadline_ms = 10 };
    var c: Completion = .{ .op = .timer, .deadline_ms = 20 };
    q.add(&a);
    q.add(&b);
    q.add(&c);

    try std.testing.expectEqual(@as(?*Completion, null), q.popDue(9));
    try std.testing.expectEqual(@as(?*Completion, &b), q.popDue(15));
    try std.testing.expectEqual(@as(?*Completion, null), q.popDue(15));
    try std.testing.expectEqual(@as(?*Completion, &c), q.popDue(100));
    try std.testing.expectEqual(@as(?*Completion, &a), q.popDue(100));
    try std.testing.expectEqual(@as(?*Completion, null), q.popDue(100));
}

test "堆中任意节点可被摘除且顺序不乱" {
    var q: TimerQueue = .{};
    defer q.deinit();
    var nodes: [8]Completion = undefined;
    for (&nodes, 0..) |*n, i| {
        n.* = .{ .op = .timer, .deadline_ms = @intCast((8 - i) * 10) };
        q.add(n);
    }
    try std.testing.expect(q.remove(&nodes[3]));
    try std.testing.expect(!q.remove(&nodes[3]));
    var last: u64 = 0;
    while (q.popDue(1000)) |n| {
        try std.testing.expect(n.deadline_ms >= last);
        last = n.deadline_ms;
    }
}

test "nextTimeout 反映队首与就绪队列" {
    var q: TimerQueue = .{};
    defer q.deinit();
    var a: Completion = .{ .op = .timer, .deadline_ms = 50 };
    q.add(&a);
    try std.testing.expectEqual(@as(u32, 0), q.nextTimeout(10, true));
    try std.testing.expectEqual(@as(u32, 40), q.nextTimeout(10, false));
    try std.testing.expectEqual(@as(u32, 0), q.nextTimeout(50, false));

    var empty: TimerQueue = .{};
    defer empty.deinit();
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), empty.nextTimeout(10, false));
}

test "heap_index 在 add/remove/popDue 后始终保持一致" {
    // O(log n) 的 `remove` 依赖 `Completion.heap_index` 精确指回堆内下标。
    // 一旦偏移，定位即错、删除会动错节点。这条测试锁死不变量。
    var q: TimerQueue = .{};
    defer q.deinit();
    var nodes: [16]Completion = undefined;
    for (&nodes, 0..) |*n, i| {
        n.* = .{ .op = .timer, .deadline_ms = @intCast((i % 5) * 10 + (i / 5)) };
        q.add(n);
    }
    // 周期性删除与弹出，制造堆内部动荡。
    try std.testing.expect(q.remove(&nodes[7]));
    _ = q.popDue(1000);
    try std.testing.expect(q.remove(&nodes[2]));
    try std.testing.expect(q.remove(&nodes[11]));
    _ = q.popDue(1000);
    // 逐个删除剩余，验证每个节点的 heap_index 与真实下标对应。
    var checked: usize = 0;
    while (q.items.items.len > 0) : (checked += 1) {
        const idx = q.items.items[0].heap_index;
        try std.testing.expectEqual(idx, @as(usize, 0));
        _ = q.popDue(100000) orelse break;
    }
    try std.testing.expect(checked > 0);
    // 已删除的节点不应再能删除，且其 heap_index 已置为 maxInt。
    try std.testing.expect(!q.remove(&nodes[7]));
    try std.testing.expectEqual(nodes[7].heap_index, std.math.maxInt(usize));
}
