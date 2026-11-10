//! 侵入式 FIFO 就绪队列：同步完成的操作在此排队，等待循环线程回调。
//!
//! 节点就是 `Completion` 自身，靠 `next` 串起来，零分配。

const std = @import("std");
const Completion = @import("completion.zig").Completion;

pub const Queue = struct {
    head: ?*Completion = null,
    tail: ?*Completion = null,

    pub fn push(self: *Queue, c: *Completion) void {
        c.next = null;
        if (self.tail) |t| {
            t.next = c;
            self.tail = c;
        } else {
            self.head = c;
            self.tail = c;
        }
    }

    pub fn pop(self: *Queue) ?*Completion {
        const c = self.head orelse return null;
        self.head = c.next;
        if (self.head == null) self.tail = null;
        c.next = null;
        return c;
    }

    pub fn isEmpty(self: *const Queue) bool {
        return self.head == null;
    }
};

test "就绪队列保持 FIFO 顺序" {
    var q: Queue = .{};
    var a: Completion = .{ .op = .timer };
    var b: Completion = .{ .op = .timer };
    var c: Completion = .{ .op = .timer };
    q.push(&a);
    q.push(&b);
    q.push(&c);
    try std.testing.expectEqual(@as(?*Completion, &a), q.pop());
    try std.testing.expectEqual(@as(?*Completion, &b), q.pop());
    try std.testing.expectEqual(@as(?*Completion, &c), q.pop());
    try std.testing.expect(q.isEmpty());
    try std.testing.expectEqual(@as(?*Completion, null), q.pop());
}

test "取出后重新入队仍可用" {
    var q: Queue = .{};
    var a: Completion = .{ .op = .timer };
    var b: Completion = .{ .op = .timer };
    q.push(&a);
    _ = q.pop();
    q.push(&b);
    q.push(&a);
    try std.testing.expectEqual(@as(?*Completion, &b), q.pop());
    try std.testing.expectEqual(@as(?*Completion, &a), q.pop());
    try std.testing.expect(q.isEmpty());
}
