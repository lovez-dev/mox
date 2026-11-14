//! `mox_io` 的 BSD / Darwin `kqueue` 后端（已做编译校验）。
//!
//! `kqueue` 是「就绪」接口，不像 io_uring 那样给完成。本后端
//! 负责搭桥：每个未完成操作注册一个一次性过滤器
//! （recv / accept / udp_recv 用 `EVFILT_READ`，
//!  send / connect / udp_send 用 `EVFILT_WRITE`）
//! 和一条 `Pending` 记录。`wait` 取出事件时就地执行
//! 对应的非阻塞系统调用，再把它转成
//! 循环期望的完成。`Work` 通知走 `EVFILT_USER`。
//!
//! macOS arm64 CI 已跑通全量运行时测试（包括 UDP 数据报搭桥路径）；
//! BSD / 其它 Darwin 目标只做编译校验，未在有主机的环境下实测。

const std = @import("std");
const c = std.c;
const builtin = @import("builtin");
const types = @import("../types.zig");
const io_mod = @import("../io.zig");
const completion = @import("../completion.zig");
const loop_mod = @import("../loop.zig");
const sys = @import("../sys.zig");
const net = std.Io.net;

const Handle = types.Handle;
const INVALID_HANDLE = types.INVALID_HANDLE;

const Kind = enum { recv, send, accept, connect, udp_recv, udp_send, watch, recvmsg, sendmsg };

/// `EVFILT_USER` 唤醒源的 ident。固定值即可，只要不与真实 fd 冲突；
/// 真实 fd 从 3 起，用 1 是安全的。
const NOTIFY_IDENT = 1;

const Pending = struct {
    ident: usize,
    filter: i16,
    kind: Kind,
    scratch: *types.Scratch,
    buf: []u8 = &.{},
    /// `udp_recv` 的源地址缓冲：指向调用方节点，随节点一起存活。
    from: []u8 = &.{},
    /// `udp_send` 的 sockaddr 存储：编在调用方节点的 `hdr` 里，这里只留指针和长度。
    hdr: []usize = &.{},
    hdr_len: c.socklen_t = 0,
    /// `recvmsg`/`sendmsg` 的 iovec 来源：指向调用方节点的 bufs 切片。
    /// 只用 `?[]const []const u8` 一种形态，recvmsg 时由后端 `@constCast`。
    msg_bufs: ?[]const []const u8 = null,
    /// 池内同方向 FIFO 链的下一个下标。
    next: u32 = NO_PENDING,
};

const NO_PENDING: u32 = std.math.maxInt(u32);
const MIN_SLOTS: usize = 64;

/// 一个 fd 上的读 / 写两条过滤器链。fd 直接当数组下标，定位 O(1)——
/// 与 epoll 后端一致，也对齐 libev `anfds[]`。
const FdSlot = struct {
    read: u32 = NO_PENDING,
    write: u32 = NO_PENDING,
    /// 过滤器当前是否已注册进 kqueue。`EV_ONESHOT` 事件到达即自动注销，
    /// 此时置 false，同步重挂剩余方向。
    read_armed: bool = false,
    write_armed: bool = false,
};

const State = struct {
    alloc: std.mem.Allocator,
    kq: i32,
    /// fd → 两条链，O(1) 定位。
    slots: []FdSlot = &.{},
    /// 预分配 `Pending` 池 + 空闲链：submit 热路径零分配。
    pool: []Pending = &.{},
    free_head: u32 = NO_PENDING,
    events: std.ArrayListUnmanaged(c.Kevent) = .empty,
    /// 被取消的操作：立即合成一个完成包，让循环能回收节点。
    /// 用 head 游标消费，避免 `orderedRemove(0)` 的 O(n) 搬移。
    cancelled: std.ArrayListUnmanaged(types.Ref) = .empty,
    cancelled_head: usize = 0,
    ref: types.Ref = undefined,
};

fn stateOf(userdata: ?*anyopaque) *State {
    return @ptrCast(@alignCast(userdata.?));
}

fn fdOf(h: Handle) c.fd_t {
    return @intCast(h);
}

// ---- 池 / 链辅助 -----------------------------------------------------------

fn slotFor(state: *State, fd: i32) ?*FdSlot {
    if (fd < 0) return null;
    const i: usize = @intCast(fd);
    if (i >= state.slots.len) return null;
    return &state.slots[i];
}

/// submit 路径用：按需扩容 slot 表（fd 号可能很大，如 accept 分配的 fd）。
fn slotOf(state: *State, fd: i32) !*FdSlot {
    const idx: usize = @intCast(fd);
    if (idx >= state.slots.len) {
        const old_len = state.slots.len;
        var len = @max(old_len, MIN_SLOTS);
        while (len <= idx) len *= 2;
        const grown = if (old_len == 0)
            try state.alloc.alloc(FdSlot, len)
        else
            try state.alloc.realloc(state.slots, len);
        @memset(grown[old_len..], .{});
        state.slots = grown;
    }
    return &state.slots[idx];
}

fn chainOf(slot: *FdSlot, filter: i16) *u32 {
    return if (filter == c.EVFILT.READ) &slot.read else &slot.write;
}

fn armedOf(slot: *FdSlot, filter: i16) *bool {
    return if (filter == c.EVFILT.READ) &slot.read_armed else &slot.write_armed;
}

fn allocPending(state: *State) !u32 {
    if (state.free_head != NO_PENDING) {
        const idx = state.free_head;
        state.free_head = state.pool[idx].next;
        return idx;
    }
    const old_len = state.pool.len;
    const new_len = @max(old_len * 2, 64);
    const grown = if (old_len == 0)
        try state.alloc.alloc(Pending, new_len)
    else
        try state.alloc.realloc(state.pool, new_len);
    state.pool = grown;
    var i = old_len;
    while (i < new_len - 1) : (i += 1) {
        grown[i] = .{ .ident = 0, .filter = 0, .kind = .watch, .scratch = undefined, .next = @intCast(i + 1) };
    }
    grown[new_len - 1] = .{ .ident = 0, .filter = 0, .kind = .watch, .scratch = undefined, .next = NO_PENDING };
    const first: u32 = @intCast(old_len);
    state.free_head = if (old_len + 1 < new_len) first + 1 else NO_PENDING;
    return first;
}

fn freePending(state: *State, idx: u32) void {
    state.pool[idx].next = state.free_head;
    state.free_head = idx;
}

/// 从链上摘掉指定 scratch 的节点；返回其池下标。
fn removeFrom(state: *State, head: *u32, scratch: *types.Scratch) ?u32 {
    var prev: u32 = NO_PENDING;
    var cur = head.*;
    while (cur != NO_PENDING) {
        const nxt = state.pool[cur].next;
        if (state.pool[cur].scratch == scratch) {
            if (prev == NO_PENDING) head.* = nxt else state.pool[prev].next = nxt;
            return cur;
        }
        prev = cur;
        cur = nxt;
    }
    return null;
}

/// 按 fd 上剩余方向同步 kqueue 注册（一次 syscall 封顶）。
fn syncArm(state: *State, fd: i32) void {
    const slot = slotFor(state, fd) orelse return;
    inline for (.{ c.EVFILT.READ, c.EVFILT.WRITE }) |filter| {
        const chain = chainOf(slot, filter).*;
        const armed = armedOf(slot, filter);
        const want = chain != NO_PENDING;
        if (want and !armed.*) {
            evAdd(state, @intCast(fd), filter, c.EV.ONESHOT) catch return;
            armed.* = true;
        } else if (!want and armed.*) {
            evDelete(state, @intCast(fd), filter);
            armed.* = false;
        }
    }
}

/// 摘一个待办：放入池、并入对应方向链、按需注册过滤器。
/// 失败（池满或 kevent 失败）时把刚入链的节点摘掉并归还，保持一致性。
fn putPending(state: *State, p: Pending) !u32 {
    const slot = try slotOf(state, @intCast(p.ident));
    const idx = try allocPending(state);
    state.pool[idx] = p;
    state.pool[idx].next = NO_PENDING;
    const head = chainOf(slot, p.filter);
    // 追加到链尾，保证 FIFO。
    if (head.* == NO_PENDING) {
        head.* = idx;
    } else {
        var cur = head.*;
        while (state.pool[cur].next != NO_PENDING) cur = state.pool[cur].next;
        state.pool[cur].next = idx;
    }
    if (!armedOf(slot, p.filter).*) {
        evAdd(state, p.ident, p.filter, c.EV.ONESHOT) catch |e| {
            _ = removeFrom(state, head, p.scratch);
            freePending(state, idx);
            return e;
        };
        armedOf(slot, p.filter).* = true;
    }
    return idx;
}

// ---- kevent 辅助函数 -------------------------------------------------------

/// 只有真正注册进 kqueue 的 fd 才需要 `O_NONBLOCK`：`finishOne` 在事件
/// 就绪后就地执行 `recv/send/accept`，不能让它们把事件循环线程卡住。
/// 同步辅助函数（`acceptSocket` / `connectSocket` / `sendBlocking` ...）
/// 不经过这里，因此保持阻塞语义，与 io_uring / IOCP 两个后端一致。
/// `EVFILT.USER` 的 ident 不是 fd，必须跳过。
fn evAdd(state: *State, ident: usize, filter: i16, flags: u16) !void {
    if (filter == c.EVFILT.READ or filter == c.EVFILT.WRITE) {
        setNonblock(@intCast(ident));
    }
    var changes = [_]c.Kevent{.{
        .ident = ident,
        .filter = filter,
        .flags = c.EV.ADD | flags,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    }};
    if (c.kevent(state.kq, &changes, 1, undefined, 0, null) < 0) return error.KeventFailed;
}

fn evDelete(state: *State, ident: usize, filter: i16) void {
    var changes = [_]c.Kevent{.{
        .ident = ident,
        .filter = filter,
        .flags = c.EV.DELETE,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    }};
    _ = c.kevent(state.kq, &changes, 1, undefined, 0, null);
}

// ---- VTable 接线 ------------------------------------------------------------

fn vtDeinit(userdata: ?*anyopaque) void {
    const state = stateOf(userdata);
    const alloc = state.alloc;
    alloc.free(state.slots);
    alloc.free(state.pool);
    state.events.deinit(alloc);
    state.cancelled.deinit(alloc);
    _ = c.close(state.kq);
    alloc.destroy(state);
}

fn vtNow(userdata: ?*anyopaque) u64 {
    _ = userdata;
    var ts: std.posix.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

fn vtAssociate(userdata: ?*anyopaque, socket: Handle, key: usize) anyerror!void {
    _ = userdata;
    _ = socket;
    _ = key;
}

fn vtWatchFd(userdata: ?*anyopaque, fd: Handle, want: types.Ready, scratch: *types.Scratch) anyerror!?void {
    const state = stateOf(userdata);
    const ident: usize = @intCast(fdOf(fd));
    if (!want.read and !want.write) return error.NothingToWatch;
    // kqueue 一个 kevent 只能盯一个 filter，可读可写要挂两条。
    // 这里只挂第一条，完成时 `complete` 会按 filter 匹配；同时要两个方向的
    // 调用方应当用两个 `WatchFd` 节点。
    const filter: i16 = if (want.read) c.EVFILT.READ else c.EVFILT.WRITE;
    _ = try putPending(state, .{
        .ident = ident,
        .filter = filter,
        .kind = .watch,
        .scratch = scratch,
    });
    return null;
}

fn vtRecv(userdata: ?*anyopaque, socket: Handle, buffer: []u8, scratch: *types.Scratch) anyerror!?usize {
    const state = stateOf(userdata);
    _ = try putPending(state, .{
        .ident = socket,
        .filter = c.EVFILT.READ,
        .kind = .recv,
        .scratch = scratch,
        .buf = buffer,
    });
    return null;
}

fn vtSend(userdata: ?*anyopaque, socket: Handle, bytes: []const u8, scratch: *types.Scratch) anyerror!?usize {
    const state = stateOf(userdata);
    // send() 需要非 const 缓冲区；循环保证这些字节在操作期间存活。
    _ = try putPending(state, .{
        .ident = socket,
        .filter = c.EVFILT.WRITE,
        .kind = .send,
        .scratch = scratch,
        .buf = @constCast(bytes),
    });
    return null;
}

fn vtClose(userdata: ?*anyopaque, socket: Handle) void {
    closeImpl(userdata, socket) catch {};
}

/// 与 `vtClose` 相同的动作（摘掉 fd 上的在飞节点、注销 EVFILT 兴趣、
/// 关闭 fd），但把 `close(2)` 的 errno 映射成具体错误。
/// `EBADF` 说明句柄已失效（重复关闭 / 被别人关掉），其余归 `CloseFailed`。
fn vtCloseChecked(userdata: ?*anyopaque, socket: Handle) anyerror!void {
    return closeImpl(userdata, socket);
}

fn closeImpl(userdata: ?*anyopaque, socket: Handle) anyerror!void {
    const state = stateOf(userdata);
    const fd: i32 = @intCast(fdOf(socket));
    // 该 fd 上所有在飞操作合成取消完成包，保证 Loop 能回收节点。
    if (slotFor(state, fd)) |slot| {
        var emitted: [64]*types.Scratch = undefined;
        var emitted_len: usize = 0;
        drainChain(state, &slot.read, &emitted, &emitted_len);
        drainChain(state, &slot.write, &emitted, &emitted_len);
        if (slot.read_armed) {
            evDelete(state, @intCast(fd), c.EVFILT.READ);
            slot.read_armed = false;
        }
        if (slot.write_armed) {
            evDelete(state, @intCast(fd), c.EVFILT.WRITE);
            slot.write_armed = false;
        }
    }
    const rc = c.close(fd);
    if (rc < 0) return switch (-rc) {
        @as(isize, @intCast(@backingInt(c.E.BADF))) => error.NotOpen,
        else => error.CloseFailed,
    };
}

/// 把一条链上的节点逐个归还池，并为每个（去重的）scratch 投递一个取消
/// 完成包。`emitted` 防止同一个 scratch 在两条链上重复投递。
fn drainChain(state: *State, head: *u32, emitted: *[64]*types.Scratch, emitted_len: *usize) void {
    var cur = head.*;
    head.* = NO_PENDING;
    while (cur != NO_PENDING) {
        const nxt = state.pool[cur].next;
        const scratch = state.pool[cur].scratch;
        freePending(state, cur);
        var dup = false;
        for (emitted[0..emitted_len.*]) |e| {
            if (e == scratch) {
                dup = true;
                break;
            }
        }
        if (!dup) {
            if (emitted_len.* < emitted.len) {
                emitted[emitted_len.*] = scratch;
                emitted_len.* += 1;
            }
            queueCancel(state, scratch);
        }
        cur = nxt;
    }
}

/// 取消：按 `scratch` 找到待办，撤销已注册的 oneshot 事件，
/// 并合成一个失败完成包，保证循环一定能回收该节点。
fn vtCancel(userdata: ?*anyopaque, socket: types.Handle, scratch: *types.Scratch) void {
    const state = stateOf(userdata);
    if (socket == INVALID_HANDLE) {
        cancelAnywhere(state, scratch);
        return;
    }
    const fd: i32 = @intCast(fdOf(socket));
    const slot = slotFor(state, fd) orelse {
        cancelAnywhere(state, scratch);
        return;
    };
    var found = false;
    if (removeFrom(state, &slot.read, scratch)) |idx| {
        freePending(state, idx);
        found = true;
    }
    if (removeFrom(state, &slot.write, scratch)) |idx| {
        freePending(state, idx);
        found = true;
    }
    if (!found) {
        cancelAnywhere(state, scratch);
        return;
    }
    syncArm(state, fd);
    queueCancel(state, scratch);
}

fn cancelAnywhere(state: *State, scratch: *types.Scratch) void {
    for (state.slots, 0..) |*slot, idx| {
        var found = false;
        if (removeFrom(state, &slot.read, scratch)) |i| {
            freePending(state, i);
            found = true;
        }
        if (removeFrom(state, &slot.write, scratch)) |i| {
            freePending(state, i);
            found = true;
        }
        if (found) {
            syncArm(state, @intCast(idx));
            queueCancel(state, scratch);
            return;
        }
    }
}

/// 完成包绝不静默丢弃：OOM 时 fail-fast，否则被取消的节点永远不回收。
fn queueCancel(state: *State, scratch: *types.Scratch) void {
    state.cancelled.append(state.alloc, .{
        .scratch = scratch,
        .bytes = 0,
        .failed = true,
        .new_handle = types.INVALID_HANDLE,
    }) catch @panic("mox_io: OOM queueing cancelled completion (node would leak)");
}

fn vtAccept(userdata: ?*anyopaque, listen: Handle, accept_socket: Handle, addr_buf: []u8, scratch: *types.Scratch) anyerror!?usize {
    const state = stateOf(userdata);
    _ = c.close(fdOf(accept_socket)); // kernel allocates the fd for us
    _ = try putPending(state, .{
        .ident = listen,
        .filter = c.EVFILT.READ,
        .kind = .accept,
        .scratch = scratch,
        .buf = addr_buf,
    });
    return null;
}

fn vtUpdateAccept(userdata: ?*anyopaque, listen: Handle, accept_socket: Handle) void {
    _ = userdata;
    _ = listen;
    _ = accept_socket;
}

fn vtConnect(userdata: ?*anyopaque, socket: Handle, address: net.IpAddress, scratch: *types.Scratch) anyerror!void {
    const state = stateOf(userdata);
    var storage: [128]u8 = undefined;
    const len = buildSockaddr(address, &storage);
    _ = c.connect(fdOf(socket), @ptrCast(@alignCast(&storage)), len); // EINPROGRESS expected
    _ = try putPending(state, .{
        .ident = socket,
        .filter = c.EVFILT.WRITE,
        .kind = .connect,
        .scratch = scratch,
    });
}

fn vtUpdateConnect(userdata: ?*anyopaque, socket: Handle) void {
    _ = userdata;
    _ = socket;
}

/// UDP 数据报接收：和 TCP `recv` 一样注册一次性 `EVFILT_READ`，事件就绪后
/// 就地执行非阻塞 `recvfrom`。数据报因此不再占用 `Work` 池线程，"无人应答
/// 的接收"也不会再把停机拖成永久等待 —— kqueue 是 level-triggered 加
/// one-shot，语义上等价于其它后端的异步数据报。
fn vtUdpRecv(
    userdata: ?*anyopaque,
    socket: Handle,
    buf: []u8,
    from: []u8,
    hdr: []usize,
    scratch: *types.Scratch,
) anyerror!void {
    _ = hdr;
    const state = stateOf(userdata);
    _ = try putPending(state, .{
        .ident = socket,
        .filter = c.EVFILT.READ,
        .kind = .udp_recv,
        .scratch = scratch,
        .buf = buf,
        .from = from,
    });
}

/// UDP 数据报发送：`sendto` 的 sockaddr 必须活到事件被处理，所以编进调用方
/// 节点自带的 `hdr`（后端私有存储）而不是栈上临时量。
fn vtUdpSend(
    userdata: ?*anyopaque,
    socket: Handle,
    buf: []const u8,
    to: net.IpAddress,
    hdr: []usize,
    scratch: *types.Scratch,
) anyerror!void {
    const state = stateOf(userdata);
    if (hdr.len * @sizeOf(usize) < 128) return error.BufferTooSmall;
    const store: *[128]u8 = @ptrCast(@alignCast(hdr.ptr));
    const len = buildSockaddr(to, store);
    _ = try putPending(state, .{
        .ident = socket,
        .filter = c.EVFILT.WRITE,
        .kind = .udp_send,
        .scratch = scratch,
        .buf = @constCast(buf),
        .hdr = hdr,
        .hdr_len = len,
    });
}

/// 一次 `kevent` 收集最多 64 个事件，逐个转成完成包后批量返回。
fn vtWaitBatch(userdata: ?*anyopaque, timeout_ms: u32, refs: []types.Ref) anyerror!usize {
    const state = stateOf(userdata);
    var n: usize = 0;

    // 取消产生的合成完成包优先返回。
    while (n < refs.len and state.cancelled_head < state.cancelled.items.len) {
        refs[n] = state.cancelled.items[state.cancelled_head];
        state.cancelled_head += 1;
        n += 1;
    }
    if (state.cancelled_head == state.cancelled.items.len) {
        state.cancelled.clearRetainingCapacity();
        state.cancelled_head = 0;
    }
    if (n != 0) return n;

    if (state.events.items.len == 0) {
        var ts: std.posix.timespec = undefined;
        var tsp: ?*const std.posix.timespec = null;
        if (timeout_ms < std.math.maxInt(u32) / 2) {
            ts = .{ .sec = @intCast(timeout_ms / 1000), .nsec = @intCast((timeout_ms % 1000) * 1_000_000) };
            tsp = &ts;
        }
        var batch: [64]c.Kevent = undefined;
        const got = c.kevent(state.kq, undefined, 0, &batch, batch.len, tsp);
        if (got < 0) return 0;
        try state.events.appendSlice(state.alloc, batch[0..@intCast(got)]);
    }
    while (n < refs.len and state.events.items.len != 0) {
        const ev = state.events.orderedRemove(0);
        if (ev.filter == c.EVFILT.USER) continue; // work wake-up; loop drains it
        if (complete(state, ev)) |r| {
            refs[n] = r;
            n += 1;
        }
    }
    return n;
}

fn complete(state: *State, ev: c.Kevent) ?types.Ref {
    const slot = slotFor(state, @intCast(ev.ident)) orelse return null;
    const head = chainOf(slot, ev.filter);
    const idx = head.*;
    if (idx == NO_PENDING) return null;
    const p = state.pool[idx];
    head.* = p.next;
    // EV_ONESHOT 事件到达会注销该过滤器。
    armedOf(slot, ev.filter).* = false;
    const r = finishOne(state, p, ev.flags);
    freePending(state, idx);
    // 还有同方向待办就重挂；没有则保持注销。
    syncArm(state, @intCast(ev.ident));
    return r;
}

fn finishOne(state: *State, p: Pending, ev_flags: u16) types.Ref {
    var res: isize = 0;
    switch (p.kind) {
        .recv => res = c.recv(fdOf(p.ident), p.buf.ptr, p.buf.len, 0),
        .send => res = c.send(fdOf(p.ident), p.buf.ptr, p.buf.len, 0),
        .accept => res = c.accept(fdOf(p.ident), null, null),
        .connect => {
            var err: c_int = 0;
            var len: c.socklen_t = @sizeOf(c_int);
            _ = c.getsockopt(fdOf(p.ident), c.SOL.SOCKET, c.SO.ERROR, &err, &len);
            res = if (err == 0) 0 else -err;
        },
        .sendmsg => {
            // 可写了：这时 sendmsg 不会阻塞（内核至少能收一部分）。
            // 返回字节数交给 Loop 回填 NetSendMsg.sent。
            const bufs = p.msg_bufs orelse &.{};
            var iov: [IOV_MAX]std.posix.iovec_const = undefined;
            for (bufs, 0..) |b, i| iov[i] = .{ .base = b.ptr, .len = b.len };
            var msg: c.msghdr_const = .{
                .name = null,
                .namelen = 0,
                .iov = @ptrCast(&iov),
                .iovlen = @intCast(bufs.len),
                .control = null,
                .controllen = 0,
                .flags = 0,
            };
            res = c.sendmsg(fdOf(p.ident), &msg, 0);
        },
        .recvmsg => {
            const bufs = p.msg_bufs orelse &.{};
            var iov: [IOV_MAX]std.posix.iovec = undefined;
            for (bufs, 0..) |b, i| iov[i] = .{ .base = @constCast(b.ptr), .len = b.len };
            var msg: c.msghdr = .{
                .name = null,
                .namelen = 0,
                .iov = @ptrCast(&iov),
                .iovlen = @intCast(bufs.len),
                .control = null,
                .controllen = 0,
                .flags = 0,
            };
            res = c.recvmsg(fdOf(p.ident), &msg, 0);
        },
        .watch => {
            // 不代收数据，只回填方向。`EVFILT.READ` 就绪 = 可读，
            // `EV_EOF` 表示对端关闭（此时读会拿到 0 字节）。
            var r: types.Ready = .{};
            if (p.filter == c.EVFILT.READ) r.read = true;
            if (p.filter == c.EVFILT.WRITE) r.write = true;
            if (ev_flags & c.EV.EOF != 0) r.hangup = true;
            if (ev_flags & c.EV.ERROR != 0) r.failed = true;
            if (!r.any()) r.failed = true;
            // 就绪位经 `Ref.bytes` 回传，由 Loop 统一翻译（见 VTable 注释）。
            res = @intCast(r.bits());
        },
        .udp_recv => {
            var len: c.socklen_t = @intCast(p.from.len);
            res = c.recvfrom(
                fdOf(p.ident),
                p.buf.ptr,
                p.buf.len,
                0,
                @ptrCast(@alignCast(p.from.ptr)),
                &len,
            );
        },
        .udp_send => {
            res = c.sendto(
                fdOf(p.ident),
                p.buf.ptr,
                p.buf.len,
                0,
                @ptrCast(@alignCast(p.hdr.ptr)),
                p.hdr_len,
            );
        },
    }
    state.ref = .{
        .scratch = p.scratch,
        .bytes = if (res >= 0) @intCast(res) else 0,
        .failed = res < 0,
        .new_handle = if (p.kind == .accept and res >= 0) @intCast(res) else types.INVALID_HANDLE,
    };
    return state.ref;
}

// ---- Unix domain socket ---------------------------------------------------

/// 把路径编成 `sockaddr_un`（BSD 带 `len` 字段）。返回长度。
fn buildUnixSockaddr(path: []const u8, storage: *c.sockaddr.un) !c.socklen_t {
    if (path.len == 0) return error.InvalidPath;
    if (path.len >= storage.path.len) return error.NameTooLong;
    storage.family = c.AF.UNIX;
    @memcpy(storage.path[0..path.len], path);
    storage.path[path.len] = 0;
    // BSD 的 `sun_len` 由调用方填，内核会校验。
    storage.len = @intCast(@offsetOf(c.sockaddr.un, "path") + path.len + 1);
    return @intCast(@offsetOf(c.sockaddr.un, "path") + path.len + 1);
}

fn vtCreateUnix(userdata: ?*anyopaque) anyerror!types.Handle {
    _ = userdata;
    return createSocket(@intCast(c.AF.UNIX), @intCast(c.SOCK.STREAM), 0);
}

fn vtBindUnix(userdata: ?*anyopaque, socket: types.Handle, path: []const u8) anyerror!void {
    _ = userdata;
    var sa: c.sockaddr.un = undefined;
    const len = try buildUnixSockaddr(path, &sa);
    if (c.bind(fdOf(socket), @ptrCast(&sa), len) != 0) {
        return sys.lastErrno();
    }
}

fn vtConnectUnix(userdata: ?*anyopaque, socket: types.Handle, path: []const u8, scratch: *types.Scratch) anyerror!?void {
    _ = userdata;
    var sa: c.sockaddr.un = undefined;
    const len = try buildUnixSockaddr(path, &sa);
    // 与 uring 一致：`sockaddr_un` 必须活到内核读完，塞进 `Scratch`。
    if (len > @sizeOf(types.Scratch)) return error.NameTooLong;
    @memcpy(std.mem.asBytes(scratch)[0..len], std.mem.asBytes(&sa)[0..len]);
    // kqueue 后端没有异步 connect 的 SQE 可用，直接调阻塞 connect 后由
    // `evAdd` 注册写就绪；非阻塞 socket 上 connect 会返回 EINPROGRESS，
    // 这是「已发起」而非失败。
    const rc = c.connect(fdOf(socket), @ptrCast(@alignCast(scratch)), len);
    if (rc == 0) return {}; // 立即连上（本机 UDS 常见）
    if (std.c._errno().* == @backingInt(c.E.INPROGRESS)) return null;
    return error.ConnectFailed;
}

// ---- 零拷贝文件→socket ----------------------------------------------------
//
// Darwin 与 FreeBSD 的 `sendfile` 签名不同：
//   Darwin:  (in, out, offset, len: *off_t, hdtr, flags)
//   FreeBSD: (in, out, offset, nbytes: usize, hdtr, sbytes: ?*off_t, flags)
// 两者都是「偏移 + 长度上限」语义，一次调用可能只发一部分，要循环。
// Darwin 还要把 SIGPIPE 抑制掉——已在 `createSocket` 设了 `SO_NOSIGPIPE`。

fn vtSendFileTo(
    userdata: ?*anyopaque,
    socket: types.Handle,
    path: []const u8,
    offset: u64,
    count: usize,
) anyerror!usize {
    _ = userdata;
    var zbuf: [4096]u8 = undefined;
    const zp = try zpath(path, &zbuf);

    const in_fd = c.open(zp, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c.mode_t, 0));
    if (in_fd < 0) return error.FileNotFound;
    defer _ = c.close(in_fd);

    const out_fd = fdOf(socket);
    var off: c.off_t = @intCast(offset);
    var remaining: usize = if (count == 0) blk: {
        const st = try stat(path);
        break :blk @intCast(st.size - @min(st.size, offset));
    } else count;

    var total: usize = 0;
    while (remaining > 0) {
        var sent: c.off_t = @intCast(remaining);
        const rc = switch (builtin.os.tag) {
            .macos, .ios, .tvos, .watchos, .visionos => c.sendfile(in_fd, out_fd, off, &sent, null, 0),
            else => blk: {
                var sbytes: c.off_t = 0;
                break :blk c.sendfile(in_fd, out_fd, off, remaining, null, &sbytes, 0);
            },
        };
        if (rc != 0) {
            // Darwin/BSD 即使成功也可能返回 -1 + EAGAIN；这里当作短写结束。
            if (total != 0) break;
            return error.SendFileFailed;
        }
        const n: usize = if (builtin.os.tag == .macos or builtin.os.tag == .ios or
            builtin.os.tag == .tvos or builtin.os.tag == .watchos or builtin.os.tag == .visionos)
            @intCast(@max(sent, 0))
        else
            @intCast(remaining);
        if (n == 0) break;
        total += n;
        off += @intCast(n);
        remaining -= @min(remaining, n);
    }
    return total;
}

fn vtNotify(userdata: ?*anyopaque) void {
    const state = stateOf(userdata);
    var change = [_]c.Kevent{.{
        .ident = NOTIFY_IDENT,
        .filter = c.EVFILT.USER,
        // 该过滤器已在 `create` 里 EV.ADD 过，这里只触发；再带 EV.ADD 会
        // 以 EEXIST 失败，唤醒就丢了。
        .flags = c.EV.CLEAR,
        .fflags = c.NOTE.TRIGGER,
        .data = 0,
        .udata = 0,
    }};
    _ = c.kevent(state.kq, &change, 1, undefined, 0, null);
}

// ---- 套接字 / 文件辅助操作（经 VTable 暴露给上层） ------------------------

fn vtCreateSocket(userdata: ?*anyopaque, address: net.IpAddress) anyerror!types.Handle {
    _ = userdata;
    return try createTcpSocket(address);
}

fn vtSetReuseAddress(userdata: ?*anyopaque, socket: types.Handle, on: bool) anyerror!void {
    _ = userdata;
    try setReuseAddress(socket, on);
}

fn vtSetSockOpt(userdata: ?*anyopaque, socket: types.Handle, opt: types.SockOpt, value: u32) anyerror!void {
    _ = userdata;
    try setSockOpt(socket, opt, value);
}

fn vtShutdownSend(userdata: ?*anyopaque, socket: types.Handle) anyerror!void {
    _ = userdata;
    try shutdownSend(socket);
}

fn vtShutdown(userdata: ?*anyopaque, socket: types.Handle, how: types.ShutdownHow) anyerror!void {
    _ = userdata;
    const flag: c_int = switch (how) {
        .read => c.SHUT.RD,
        .write => c.SHUT.WR,
        .both => c.SHUT.RDWR,
    };
    if (c.shutdown(fdOf(socket), flag) < 0) return error.ShutdownFailed;
}

fn vtSendMsg(
    userdata: ?*anyopaque,
    socket: types.Handle,
    bufs: []const []const u8,
    hdr: []usize,
    scratch: *types.Scratch,
) anyerror!void {
    _ = hdr;
    // **不能同步 sendmsg**：socket 可能暂时写不进去，同步调用会把整个
    // 循环线程卡住（macOS CI 实测 NetRecvMsg 挂死就是这么来的）。
    // 正确做法与 `vtSend` 一致：注册 EVFILT.WRITE，就绪后在 reap 里
    // 同步执行那一次系统调用。
    const state = stateOf(userdata);
    _ = try putPending(state, .{
        .ident = socket,
        .filter = c.EVFILT.WRITE,
        .kind = .sendmsg,
        .scratch = scratch,
        .msg_bufs = bufs,
    });
}

fn vtRecvMsg(
    userdata: ?*anyopaque,
    socket: types.Handle,
    bufs: []const []u8,
    hdr: []usize,
    scratch: *types.Scratch,
) anyerror!void {
    _ = hdr;
    // 理由同 `vtSendMsg`：绝不能同步 recvmsg。
    const state = stateOf(userdata);
    _ = try putPending(state, .{
        .ident = socket,
        .filter = c.EVFILT.READ,
        .kind = .recvmsg,
        .scratch = scratch,
        .msg_bufs = @ptrCast(bufs),
    });
}

fn vtBind(userdata: ?*anyopaque, socket: types.Handle, address: net.IpAddress) anyerror!void {
    _ = userdata;
    try bindSocket(socket, address);
}

fn vtListen(userdata: ?*anyopaque, socket: types.Handle, backlog: c_int) anyerror!void {
    _ = userdata;
    try listenSocket(socket, backlog);
}

fn vtFileSize(userdata: ?*anyopaque, path: []const u8) anyerror!u64 {
    _ = userdata;
    return fileSize(path);
}

/// 阻塞读文件适配器：忽略 `userdata`，转发到本后端的通用文件实现。
fn vtReadFileInto(userdata: ?*anyopaque, path: []const u8, buf: []u8) anyerror!usize {
    _ = userdata;
    return readFileInto(path, buf);
}

fn vtWriteFileAll(userdata: ?*anyopaque, path: []const u8, bytes: []const u8) anyerror!void {
    _ = userdata;
    return writeFileAll(path, bytes);
}

fn vtReadFileAt(userdata: ?*anyopaque, path: []const u8, offset: u64, buf: []u8) anyerror!usize {
    _ = userdata;
    return readFileAt(path, offset, buf);
}

fn vtAppendFile(userdata: ?*anyopaque, path: []const u8, bytes: []const u8) anyerror!void {
    _ = userdata;
    return appendFile(path, bytes);
}

fn vtTruncateFile(userdata: ?*anyopaque, path: []const u8, size: u64) anyerror!void {
    _ = userdata;
    return truncateFile(path, size);
}

fn vtOpenFile(userdata: ?*anyopaque, path: []const u8, mode: types.FileMode) anyerror!types.Handle {
    _ = userdata;
    return openFile(path, mode);
}

fn vtReadFileHandle(userdata: ?*anyopaque, file: types.Handle, offset: u64, buf: []u8) anyerror!usize {
    _ = userdata;
    return readFileHandle(file, offset, buf);
}

fn vtWriteFileHandle(userdata: ?*anyopaque, file: types.Handle, offset: u64, bytes: []const u8) anyerror!usize {
    _ = userdata;
    return writeFileHandle(file, offset, bytes);
}

fn vtCloseFile(userdata: ?*anyopaque, file: types.Handle) void {
    _ = userdata;
    closeFile(file);
}

fn vtStatFile(userdata: ?*anyopaque, file: types.Handle) anyerror!types.Stat {
    _ = userdata;
    const st = try statFile(file);
    return .{ .kind = @fromBackingInt(@intCast(@backingInt(st.kind))), .size = st.size, .mtime_ms = st.mtime_ms };
}

fn vtSetFileSize(userdata: ?*anyopaque, file: types.Handle, size: u64) anyerror!void {
    _ = userdata;
    return setFileSize(file, size);
}

fn vtSyncFile(userdata: ?*anyopaque, file: types.Handle) anyerror!void {
    _ = userdata;
    return syncFile(file);
}

fn vtSetFilePermissions(userdata: ?*anyopaque, file: types.Handle, mode: u32) anyerror!void {
    _ = userdata;
    return setFilePermissions(file, mode);
}

fn vtSetFileOwner(userdata: ?*anyopaque, file: types.Handle, uid: u32, gid: u32) anyerror!void {
    _ = userdata;
    return setFileOwner(file, uid, gid);
}

fn vtSetFileTimestamps(userdata: ?*anyopaque, file: types.Handle, atime_ns: i64, mtime_ns: i64) anyerror!void {
    _ = userdata;
    return setFileTimestamps(file, atime_ns, mtime_ns);
}

fn vtSetPermissions(userdata: ?*anyopaque, path: []const u8, mode: u32) anyerror!void {
    _ = userdata;
    return setPermissions(path, mode);
}

fn vtSetOwner(userdata: ?*anyopaque, path: []const u8, uid: u32, gid: u32) anyerror!void {
    _ = userdata;
    return setOwner(path, uid, gid);
}

fn vtSetTimestamps(userdata: ?*anyopaque, path: []const u8, atime_ns: i64, mtime_ns: i64) anyerror!void {
    _ = userdata;
    return setTimestamps(path, atime_ns, mtime_ns);
}

fn vtAccess(userdata: ?*anyopaque, path: []const u8, mode: u32) anyerror!void {
    _ = userdata;
    return access(path, mode);
}

fn vtRealPath(userdata: ?*anyopaque, path: []const u8, buf: []u8) anyerror!usize {
    _ = userdata;
    return realPath(path, buf);
}

fn vtHardLink(userdata: ?*anyopaque, old_path: []const u8, new_path: []const u8) anyerror!void {
    _ = userdata;
    return hardLink(old_path, new_path);
}

fn vtReadLink(userdata: ?*anyopaque, link_path: []const u8, buf: []u8) anyerror!usize {
    _ = userdata;
    return readLink(link_path, buf);
}

fn vtOpenDir(userdata: ?*anyopaque, path: []const u8) anyerror!types.Handle {
    _ = userdata;
    return openDir(path);
}

fn vtReadDirHandle(userdata: ?*anyopaque, dir: types.Handle, buf: []types.DirEntry) anyerror!usize {
    _ = userdata;
    return readDirHandle(dir, buf);
}

fn vtCloseDir(userdata: ?*anyopaque, dir: types.Handle) void {
    _ = userdata;
    closeDir(dir);
}

fn vtMakeDir(userdata: ?*anyopaque, path: []const u8, mode: u32) anyerror!void {
    _ = userdata;
    return makeDir(path, mode);
}

fn vtRemoveDir(userdata: ?*anyopaque, path: []const u8) anyerror!void {
    _ = userdata;
    return removeDir(path);
}

fn vtRename(userdata: ?*anyopaque, old_path: []const u8, new_path: []const u8) anyerror!void {
    _ = userdata;
    return rename(old_path, new_path);
}

fn vtSymLink(userdata: ?*anyopaque, target: []const u8, link_path: []const u8) anyerror!void {
    _ = userdata;
    return symLink(target, link_path);
}

fn vtStatPath(userdata: ?*anyopaque, path: []const u8) anyerror!types.Stat {
    _ = userdata;
    const st = try stat(path);
    return .{ .kind = @fromBackingInt(@intCast(@backingInt(st.kind))), .size = st.size, .mtime_ms = st.mtime_ms };
}

fn vtListDir(userdata: ?*anyopaque, path: []const u8, buf: []types.DirEntry) anyerror!usize {
    _ = userdata;
    return listDir(path, @ptrCast(buf));
}

fn vtDeleteFile(userdata: ?*anyopaque, path: []const u8) anyerror!void {
    _ = userdata;
    try deleteFileChecked(path);
}

const blocking_net = @import("blocking_net.zig").adapt(@This());

const vtable_storage: io_mod.VTable = .{
    .blockingNet = &blocking_net,
    .deinit = vtDeinit,
    .now = vtNow,
    .createSocket = vtCreateSocket,
    .setReuseAddress = vtSetReuseAddress,
    .setSockOpt = vtSetSockOpt,
    .shutdownSend = vtShutdownSend,
    .shutdown = vtShutdown,
    .sendMsg = vtSendMsg,
    .recvMsg = vtRecvMsg,
    .bind = vtBind,
    .listen = vtListen,
    .fileSize = vtFileSize,
    .readFileInto = vtReadFileInto,
    .writeFileAll = vtWriteFileAll,
    .readFileAt = vtReadFileAt,
    .appendFile = vtAppendFile,
    .truncateFile = vtTruncateFile,
    .openFile = vtOpenFile,
    .readFileHandle = vtReadFileHandle,
    .writeFileHandle = vtWriteFileHandle,
    .closeFile = vtCloseFile,
    .statFile = vtStatFile,
    .setFileSize = vtSetFileSize,
    .syncFile = vtSyncFile,
    .setFilePermissions = vtSetFilePermissions,
    .setFileOwner = vtSetFileOwner,
    .setFileTimestamps = vtSetFileTimestamps,
    .setPermissions = vtSetPermissions,
    .setOwner = vtSetOwner,
    .setTimestamps = vtSetTimestamps,
    .access = vtAccess,
    .realPath = vtRealPath,
    .hardLink = vtHardLink,
    .deleteFile = vtDeleteFile,
    .makeDir = vtMakeDir,
    .removeDir = vtRemoveDir,
    .rename = vtRename,
    .symLink = vtSymLink,
    .readLink = vtReadLink,
    .openDir = vtOpenDir,
    .readDirHandle = vtReadDirHandle,
    .closeDir = vtCloseDir,
    .statPath = vtStatPath,
    .listDir = vtListDir,
    .associate = vtAssociate,
    .recv = vtRecv,
    .send = vtSend,
    .udpRecv = vtUdpRecv,
    .udpSend = vtUdpSend,
    .accept = vtAccept,
    .updateAccept = vtUpdateAccept,
    .connect = vtConnect,
    .updateConnect = vtUpdateConnect,
    .cancel = vtCancel,
    .watchFd = vtWatchFd,
    // socket 就绪等待与任意 fd 走同一套机制，直接复用。
    .netPoll = vtWatchFd,
    .createUnix = vtCreateUnix,
    .bindUnix = vtBindUnix,
    .connectUnix = vtConnectUnix,
    .sendFileTo = vtSendFileTo,
    .close = vtClose,
    .closeChecked = vtCloseChecked,
    .waitBatch = vtWaitBatch,
    .notify = vtNotify,
};

/// 带配置的入口：`queue_size` 决定 `pending` / `cancelled` 容器的**预分配**
/// 容量（`events` 固定 64，对应 kevent 批量）。容器启动时一次备齐，
/// 稳态 submit / reap / cancel 不再 malloc。
pub fn create(alloc: std.mem.Allocator, opts: io_mod.Options) !io_mod.Io {
    return createBody(alloc, opts.queue_size);
}

fn createBody(alloc: std.mem.Allocator, queue_size: u16) !io_mod.Io {
    const state = try alloc.create(State);
    errdefer alloc.destroy(state);
    const kq = c.kqueue();
    if (kq < 0) return error.KqueueFailed;
    state.* = .{ .alloc = alloc, .kq = kq };
    // 按在飞窗口预分配容器：稳态 submit / reap / cancel 只写已分配内存。
    const cap: usize = @max(@as(usize, queue_size) * 4, MIN_SLOTS);
    state.slots = try alloc.alloc(FdSlot, cap);
    @memset(state.slots, .{});
    state.pool = try alloc.alloc(Pending, cap);
    var pi: usize = 0;
    while (pi < cap - 1) : (pi += 1) state.pool[pi] = .{ .ident = 0, .filter = 0, .kind = .watch, .scratch = undefined, .next = @intCast(pi + 1) };
    state.pool[cap - 1] = .{ .ident = 0, .filter = 0, .kind = .watch, .scratch = undefined, .next = NO_PENDING };
    state.free_head = 0;
    errdefer {
        state.events.deinit(alloc);
        state.cancelled.deinit(alloc);
        alloc.free(state.slots);
        alloc.free(state.pool);
    }
    state.events.ensureTotalCapacity(alloc, 64) catch return error.SetupFailed;
    state.cancelled.ensureTotalCapacity(alloc, cap) catch return error.SetupFailed;
    // 必须先在这个 kq 上注册 `EVFILT_USER`，`vtNotify` 才能用它唤醒
    // `waitBatch`。没有这一步，notify 会以 ENOENT 失败且被丢弃 —— 跨线程
    // `submit` 与 `Work` 完成就再也叫不醒循环，表现为整个进程挂死。
    var reg = [_]c.Kevent{.{
        .ident = NOTIFY_IDENT,
        .filter = c.EVFILT.USER,
        .flags = c.EV.ADD | c.EV.CLEAR,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    }};
    if (c.kevent(kq, &reg, 1, undefined, 0, null) < 0) {
        _ = c.close(kq);
        return error.KqueueFailed; // errdefer 回收 slots/pool/state
    }
    return .{ .userdata = state, .vtable = &vtable_storage };
}

// ---- sockaddr 编组（BSD 布局：sa_len 在最前） -----------------------------

fn buildSockaddr(address: net.IpAddress, storage: *[128]u8) c.socklen_t {
    switch (address) {
        .ip4 => |a| {
            storage[0] = @sizeOf(SockAddrIn);
            storage[1] = @intCast(c.AF.INET);
            std.mem.writeInt(u16, storage[2..4], std.mem.nativeToBig(u16, a.port), .big);
            @memcpy(storage[4..8], &a.bytes);
            @memset(storage[8..@sizeOf(SockAddrIn)], 0);
            return @sizeOf(SockAddrIn);
        },
        .ip6 => |a| {
            storage[0] = @sizeOf(SockAddrIn6);
            storage[1] = @intCast(c.AF.INET6);
            std.mem.writeInt(u16, storage[2..4], std.mem.nativeToBig(u16, a.port), .big);
            std.mem.writeInt(u32, storage[4..8], 0, .big); // flowinfo
            @memcpy(storage[8..24], &a.bytes); // addr
            std.mem.writeInt(u32, storage[24..28], 0, .native); // scope_id
            return @sizeOf(SockAddrIn6);
        },
    }
}

const SockAddrIn = extern struct { len: u8, family: u8, port: u16, addr: [4]u8, zero: [8]u8 };
const SockAddrIn6 = extern struct { len: u8, family: u8, port: u16, flowinfo: u32, addr: [16]u8, scope_id: u32 };

fn fromSockaddr(storage: *const [128]u8) net.IpAddress {
    if (storage[1] == @as(u8, @intCast(c.AF.INET))) {
        return .{ .ip4 = .{
            .port = std.mem.bigToNative(u16, std.mem.readInt(u16, storage[2..4], .big)),
            .bytes = storage[4..8].*,
        } };
    }
    return .{ .ip6 = .{
        .port = std.mem.bigToNative(u16, std.mem.readInt(u16, storage[2..4], .big)),
        .bytes = storage[8..24].*,
    } };
}

// ---- 平台套接字 + 文件辅助函数 ---------------------------------------------

fn setNonblock(h: Handle) void {
    const raw: u32 = @bitCast(c.fcntl(fdOf(h), c.F.GETFL, @as(c_int, 0)));
    var opt: c.O = @bitCast(raw);
    opt.NONBLOCK = true;
    _ = c.fcntl(fdOf(h), c.F.SETFL, @as(c_int, @bitCast(opt)));
}

pub fn createSocket(domain: c_uint, kind: c_uint, protocol: c_uint) !Handle {
    const fd = c.socket(domain, kind, protocol);
    if (fd < 0) return error.SocketFailed;
    // BSD 没有 `MSG_NOSIGNAL`，抑制 SIGPIPE 靠 socket 级的 `SO_NOSIGPIPE`。
    // 在创建处一次设好，`send` 的所有路径（异步与阻塞）就都覆盖了。
    var on: c_int = 1;
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, &on, @sizeOf(c_int));
    return @intCast(fd);
}

pub fn createTcpSocket(address: net.IpAddress) !Handle {
    const domain: c_uint = switch (address) {
        .ip4 => @intCast(c.AF.INET),
        .ip6 => @intCast(c.AF.INET6),
    };
    // 与 io_uring / IOCP 后端一致：socket 创建时保持阻塞。
    // 非阻塞属性由 `evAdd` 在注册进 kqueue 时才赋予，避免把
    // `acceptSocket` / `connectSocket` 这类同步辅助函数变成 EAGAIN。
    return createSocket(domain, c.SOCK.STREAM, c.IPPROTO.TCP);
}

/// 语义选项 → BSD `setsockopt`。`TCP_NODELAY` 在 `c.TCP` 下；
/// 保活空闲秒数在 Darwin/FreeBSD 上叫 `TCP_KEEPIDLE`，`SO_KEEPALIVE`
/// 需先打开才有意义，这里一并置位。
pub fn setSockOpt(h: Handle, opt: types.SockOpt, value: u32) !void {
    var v: c_int = @intCast(value);
    const fd = fdOf(h);
    switch (opt) {
        .tcp_nodelay => if (c.setsockopt(fd, c.IPPROTO.TCP, c.TCP.NODELAY, &v, @sizeOf(c_int)) < 0) return error.OptionFailed,
        .keepalive_idle => {
            var on: c_int = 1;
            if (c.setsockopt(fd, c.SOL.SOCKET, c.SO.KEEPALIVE, &on, @sizeOf(c_int)) < 0) return error.OptionFailed;
            // Darwin 用 `TCP_KEEPALIVE`，FreeBSD/NetBSD 用 `TCP_KEEPIDLE`，
            // 语义相同但常量名不同 —— 编译期按目标平台挑。
            const idle = switch (builtin.os.tag) {
                .macos, .ios, .tvos, .watchos, .visionos => c.TCP.KEEPALIVE,
                else => c.TCP.KEEPIDLE,
            };
            if (c.setsockopt(fd, c.IPPROTO.TCP, idle, &v, @sizeOf(c_int)) < 0) return error.OptionFailed;
        },
        .recv_buf => if (c.setsockopt(fd, c.SOL.SOCKET, c.SO.RCVBUF, &v, @sizeOf(c_int)) < 0) return error.OptionFailed,
        .send_buf => if (c.setsockopt(fd, c.SOL.SOCKET, c.SO.SNDBUF, &v, @sizeOf(c_int)) < 0) return error.OptionFailed,
    }
}

/// 只关发送方向（`SHUT_WR`）。与 `close` 直接终止不同，
/// 对端仍能读完我们已发出的数据。
pub fn shutdownSend(h: Handle) !void {
    if (c.shutdown(fdOf(h), c.SHUT.WR) < 0) return error.ShutdownFailed;
}

/// iovec 上限，与 `MSG_HDR_WORDS` 的预算对应。
pub const IOV_MAX = 32;

/// 阻塞版分散聚合发送。
pub fn sendMsgBlocking(h: Handle, bufs: []const []const u8) !void {
    if (bufs.len == 0) return error.NoBuffers;
    if (bufs.len > IOV_MAX) return error.TooManyBuffers;
    var iov: [IOV_MAX]std.posix.iovec_const = undefined;
    for (bufs, 0..) |b, i| iov[i] = .{ .base = b.ptr, .len = b.len };
    var msg: c.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = @ptrCast(&iov),
        .iovlen = @intCast(bufs.len),
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    if (c.sendmsg(fdOf(h), &msg, 0) < 0) return error.SendFailed;
}

/// 阻塞版分散聚合接收。
pub fn recvMsgBlocking(h: Handle, bufs: []const []u8) !void {
    if (bufs.len == 0) return error.NoBuffers;
    if (bufs.len > IOV_MAX) return error.TooManyBuffers;
    var iov: [IOV_MAX]std.posix.iovec = undefined;
    for (bufs, 0..) |b, i| iov[i] = .{ .base = b.ptr, .len = b.len };
    var msg: c.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = @ptrCast(&iov),
        .iovlen = @intCast(bufs.len),
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    if (c.recvmsg(fdOf(h), &msg, 0) < 0) return error.RecvFailed;
}

/// UDP 能力用的阻塞数据报 helper；在 `Work` 池线程里调用。
pub fn createUdpSocket(address: net.IpAddress) !Handle {
    const domain: c_uint = switch (address) {
        .ip4 => @intCast(c.AF.INET),
        .ip6 => @intCast(c.AF.INET6),
    };
    // 能力实现走阻塞 `recvfrom`，这里不设 O_NONBLOCK。
    return createSocket(domain, c.SOCK.DGRAM, c.IPPROTO.UDP);
}

pub fn recvFromBlocking(h: Handle, buf: []u8, from: []u8) !usize {
    var len: c.socklen_t = @intCast(from.len);
    const n = c.recvfrom(fdOf(h), buf.ptr, buf.len, 0, @ptrCast(@alignCast(from.ptr)), &len);
    if (n < 0) return error.RecvFailed;
    return @intCast(n);
}

pub fn sendToBlocking(h: Handle, buf: []const u8, address: net.IpAddress) !usize {
    var storage: [128]u8 = undefined;
    const len = buildSockaddr(address, &storage);
    const sa: *const c.sockaddr = @ptrCast(@alignCast(&storage));
    const n = c.sendto(fdOf(h), buf.ptr, buf.len, 0, sa, len);
    if (n < 0) return error.SendFailed;
    return @intCast(n);
}

pub fn bindSocket(h: Handle, address: net.IpAddress) !void {
    var storage: [128]u8 = undefined;
    const len = buildSockaddr(address, &storage);
    if (c.bind(fdOf(h), @ptrCast(@alignCast(&storage)), len) < 0) return error.BindFailed;
}

pub fn listenSocket(h: Handle, backlog: c_int) !void {
    if (c.listen(fdOf(h), @intCast(backlog)) < 0) return error.ListenFailed;
}

pub fn localAddress(h: Handle) !net.IpAddress {
    var storage: [128]u8 = undefined;
    var len: c.socklen_t = storage.len;
    if (c.getsockname(fdOf(h), @ptrCast(@alignCast(&storage)), &len) < 0) return error.GetSockNameFailed;
    return fromSockaddr(&storage);
}

pub fn acceptSocket(h: Handle) !struct { socket: Handle, address: net.IpAddress } {
    var storage: [128]u8 = undefined;
    var len: c.socklen_t = storage.len;
    const fd = c.accept(fdOf(h), @ptrCast(@alignCast(&storage)), &len);
    if (fd < 0) return error.AcceptFailed;
    return .{ .socket = @intCast(fd), .address = fromSockaddr(&storage) };
}

pub fn connectSocket(h: Handle, address: net.IpAddress) !void {
    var storage: [128]u8 = undefined;
    const len = buildSockaddr(address, &storage);
    if (c.connect(fdOf(h), @ptrCast(@alignCast(&storage)), len) < 0) return error.ConnectFailed;
}

pub fn setReuseAddress(h: Handle, on: bool) !void {
    var v: c_int = if (on) 1 else 0;
    if (c.setsockopt(fdOf(h), c.SOL.SOCKET, c.SO.REUSEADDR, &v, @sizeOf(c_int)) < 0) return error.OptionFailed;
}

pub fn closeSocket(h: Handle) void {
    _ = c.close(fdOf(h));
}

pub fn sendBlocking(h: Handle, bytes: []const u8) !usize {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.send(fdOf(h), bytes.ptr + off, bytes.len - off, 0);
        if (n < 0) return error.SendFailed;
        off += @intCast(n);
    }
    return off;
}

/// 阻塞接收，仅用于测试 / benchmark 的客户端线程。
pub fn recvBlocking(h: Handle, buf: []u8) !usize {
    const n = c.recv(fdOf(h), buf.ptr, buf.len, 0);
    if (n < 0) return error.RecvFailed;
    return @intCast(n);
}

pub fn tickCount() u64 {
    var ts: std.posix.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

// ---- 扁平文件 I/O（在 `Work` 池线程中执行） --------------------------------

fn zpath(path: []const u8, buf: []u8) ![:0]u8 {
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

pub fn fileSize(path: []const u8) !u64 {
    var zbuf: [1024]u8 = undefined;
    const z = try zpath(path, &zbuf);
    const fd = c.open(z.ptr, .{ .ACCMODE = .RDONLY }, @as(c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    const end = c.lseek(fd, 0, c.SEEK.END);
    if (end < 0) return error.SeekFailed;
    return @intCast(end);
}

pub fn readFileInto(path: []const u8, buf: []u8) !usize {
    var zbuf: [1024]u8 = undefined;
    const z = try zpath(path, &zbuf);
    const fd = c.open(z.ptr, .{ .ACCMODE = .RDONLY }, @as(c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var total: usize = 0;
    while (total < buf.len) {
        const n = c.read(fd, buf.ptr + total, buf.len - total);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        total += @intCast(n);
    }
    return total;
}

pub fn writeFileAll(path: []const u8, bytes: []const u8) !void {
    var zbuf: [1024]u8 = undefined;
    const z = try zpath(path, &zbuf);
    const fd = c.open(z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o644));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

// ---- 目录与元数据 ---------------------------------------------------------

pub const FileKind = enum { file, directory, sym_link, other };

pub const Stat = struct {
    kind: FileKind,
    size: u64,
    /// 最后修改时间（Unix 毫秒）；0 表示内核未回填。
    mtime_ms: i64,
};

/// 创建目录（含所有缺失的父目录，等价 `mkdir -p`）。
pub fn makeDir(path: []const u8, mode: u32) !void {
    if (path.len == 0) return error.InvalidPath;
    var buf: [1024]u8 = undefined;
    var i: usize = 0;
    while (i <= path.len) : (i += 1) {
        if (i != path.len and path[i] != '/') continue;
        if (i == 0) continue;
        const z = try zpath(path[0..i], &buf);
        if (c.mkdir(z.ptr, @intCast(mode)) != 0) {
            if (std.c._errno().* == @backingInt(std.c.E.EXIST)) continue;
            return error.MakeDirFailed;
        }
    }
    return;
}

pub fn removeDir(path: []const u8) !void {
    var buf: [1024]u8 = undefined;
    const z = try zpath(path, &buf);
    if (c.rmdir(z.ptr) == 0) return;
    return sys.lastErrno();
}

pub fn rename(old_path: []const u8, new_path: []const u8) !void {
    var obuf: [1024]u8 = undefined;
    var nbuf: [1024]u8 = undefined;
    const o = try zpath(old_path, &obuf);
    const n = try zpath(new_path, &nbuf);
    if (c.rename(o.ptr, n.ptr) == 0) return;
    return sys.lastErrno();
}

pub fn symLink(target: []const u8, link_path: []const u8) !void {
    var tbuf: [1024]u8 = undefined;
    var lbuf: [1024]u8 = undefined;
    const t = try zpath(target, &tbuf);
    const l = try zpath(link_path, &lbuf);
    if (c.symlink(t.ptr, l.ptr) == 0) return;
    return sys.lastErrno();
}

/// 取路径元数据。`c.stat` 跟随符号链接（与 `stat(1)` 一致）。
pub fn stat(path: []const u8) !Stat {
    var buf: [1024]u8 = undefined;
    const z = try zpath(path, &buf);
    var st: c.Stat = undefined;
    if (c.stat(z.ptr, &st) != 0) {
        return sys.lastErrno();
    }
    const fmt: u32 = @intCast(st.mode & c.S.IFMT);
    const kind: FileKind = if (fmt == c.S.IFREG)
        .file
    else if (fmt == c.S.IFDIR)
        .directory
    else if (fmt == c.S.IFLNK)
        .sym_link
    else
        .other;
    const mt = st.mtime();
    return .{
        .kind = kind,
        .size = @intCast(st.size),
        .mtime_ms = @as(i64, @intCast(mt.sec)) * 1000 + @divTrunc(@as(i64, @intCast(mt.nsec)), 1_000_000),
    };
}

pub const DirEntry = struct {
    name: [256]u8 = undefined,
    len: usize = 0,
    is_dir: bool = false,

    pub fn slice(self: *const DirEntry) []const u8 {
        return self.name[0..self.len];
    }
};

/// 列目录项，返回条目数（超出 `buf` 时截断）。不排序、不含 `.` 与 `..`。
pub fn listDir(path: []const u8, buf: []DirEntry) !usize {
    var zbuf: [1024]u8 = undefined;
    const z = try zpath(path, &zbuf);
    const d = c.opendir(z.ptr) orelse return error.OpenFailed;
    defer _ = c.closedir(d);

    var count: usize = 0;
    while (c.readdir(d)) |ent| {
        // Darwin 用 `namlen`，FreeBSD 用 `name` 直到 NUL；两者都按 NUL 截断更稳。
        const name = std.mem.sliceTo(&ent.name, 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (count >= buf.len) return count;
        if (name.len <= buf[count].name.len) {
            @memcpy(buf[count].name[0..name.len], name);
            buf[count].len = name.len;
            buf[count].is_dir = ent.type == c.DT.DIR;
            count += 1;
        }
    }
    return count;
}

/// 清理用 void 版本，专为 `defer`。
pub fn deleteFile(path: []const u8) void {
    deleteFileChecked(path) catch {};
}

pub fn deleteFileChecked(path: []const u8) !void {
    var zbuf: [1024]u8 = undefined;
    const z = try zpath(path, &zbuf);
    if (c.unlink(z.ptr) < 0) {
        const e = sys.lastErrnoValue();
        if (e == .NOENT) return; // 幂等：文件已不存在视为成功
        return sys.fromErrno(e);
    }
}

/// 从 `offset` 处读入 `buf`，返回实际读到的字节数（文件尾会短读）。
pub fn readFileAt(path: []const u8, offset: u64, buf: []u8) !usize {
    var zbuf: [1024]u8 = undefined;
    const z = try zpath(path, &zbuf);
    const fd = c.open(z.ptr, .{ .ACCMODE = .RDONLY }, @as(c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    if (c.lseek(fd, @intCast(offset), c.SEEK.SET) < 0) return error.SeekFailed;
    var total: usize = 0;
    while (total < buf.len) {
        const n = c.read(fd, buf.ptr + total, buf.len - total);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        total += @intCast(n);
    }
    return total;
}

/// 在文件末尾追加 `bytes`；文件不存在时创建。
pub fn appendFile(path: []const u8, bytes: []const u8) !void {
    var zbuf: [1024]u8 = undefined;
    const z = try zpath(path, &zbuf);
    const fd = c.open(z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(c.mode_t, 0o644));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

/// 把文件截断到 `size` 字节。
pub fn truncateFile(path: []const u8, size: u64) !void {
    var zbuf: [1024]u8 = undefined;
    const z = try zpath(path, &zbuf);
    const fd = c.open(z.ptr, .{ .ACCMODE = .WRONLY }, @as(c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    if (c.ftruncate(fd, @intCast(size)) < 0) return error.TruncateFailed;
}

// ---- 文件句柄层（阶段 A）--------------------------------------------------
// 与 Linux 后端同一套语义：打开一次拿句柄，之后按显式 offset 读写。
// BSD/Darwin 的 pread/pwrite 不移动文件偏移，多读者可共用同一 fd。

/// 打开文件并返回句柄（fd）。
pub fn openFile(path: []const u8, mode: types.FileMode) !types.Handle {
    var zbuf: [1024]u8 = undefined;
    const z = try zpath(path, &zbuf);
    const flags: c.O = switch (mode) {
        .read_only => .{ .ACCMODE = .RDONLY },
        .write_only => .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        .read_write => .{ .ACCMODE = .RDWR, .CREAT = true },
        .append => .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
    };
    const fd = c.open(z.ptr, flags, @as(c.mode_t, 0o644));
    if (fd < 0) {
        // 与 Linux 后端保持一致的语义错误：调用方需要区分「不存在」与「没权限」。
        return switch (std.posix.errno(@as(isize, fd))) {
            .NOENT => error.FileNotFound,
            .ACCES => error.AccessDenied,
            .ISDIR => error.IsDirectory,
            .NAMETOOLONG => error.NameTooLong,
            else => error.OpenFailed,
        };
    }
    return @intCast(fd);
}

/// 从 `offset` 读入 `buf`。返回实际读到的字节数；文件尾短读不报错。
pub fn readFileHandle(file: types.Handle, offset: u64, buf: []u8) !usize {
    const fd: c.fd_t = @intCast(file);
    var total: usize = 0;
    while (total < buf.len) {
        const n = c.pread(fd, buf.ptr + total, buf.len - total, @intCast(offset + total));
        if (n < 0) return error.ReadFailed;
        if (n == 0) break; // EOF
        total += @intCast(n);
    }
    return total;
}

/// 从 `offset` 写入全部 `bytes`。返回写入的字节数。
pub fn writeFileHandle(file: types.Handle, offset: u64, bytes: []const u8) !usize {
    const fd: c.fd_t = @intCast(file);
    var total: usize = 0;
    while (total < bytes.len) {
        const n = c.pwrite(fd, bytes.ptr + total, bytes.len - total, @intCast(offset + total));
        if (n < 0) return error.WriteFailed;
        if (n == 0) return error.WriteZero;
        total += @intCast(n);
    }
    return total;
}

/// 关闭句柄。重复关闭或无效句柄不报错（幂等）。
pub fn closeFile(file: types.Handle) void {
    const fd: c.fd_t = @intCast(file);
    if (fd >= 0) _ = c.close(fd);
}

// ---- 句柄级元数据与同步（阶段 B）------------------------------------------

/// 取句柄元数据。`fstat` 直接作用于 fd，不重新解析路径。
pub fn statFile(file: types.Handle) !Stat {
    const fd: c.fd_t = @intCast(file);
    var st: c.Stat = undefined;
    if (c.fstat(fd, &st) != 0) {
        return switch (std.posix.errno(@as(isize, -1))) {
            .BADF => error.InvalidHandle,
            else => error.StatFailed,
        };
    }
    const kind: FileKind = switch (st.mode & c.S.IFMT) {
        c.S.IFREG => .file,
        c.S.IFDIR => .directory,
        c.S.IFLNK => .sym_link,
        else => .other,
    };
    return .{
        .kind = kind,
        .size = @intCast(st.size),
        // 用 `mtime()` 而不是直接读字段：Darwin 是 `mtimespec`、FreeBSD 是
        // `mtim`，但两者都提供同名访问器，比按平台分叉稳。
        .mtime_ms = blk: {
            const mt = st.mtime();
            break :blk @as(i64, @intCast(mt.sec)) * 1000 + @divTrunc(@as(i64, @intCast(mt.nsec)), 1_000_000);
        },
    };
}

/// 把句柄对应文件截断到 `size` 字节。
pub fn setFileSize(file: types.Handle, size: u64) !void {
    const fd: c.fd_t = @intCast(file);
    if (c.ftruncate(fd, @intCast(size)) < 0) return error.TruncateFailed;
}

/// 把缓冲内容刷到磁盘。`fsync` 在 BSD/Darwin 上同时保证数据与元数据。
pub fn syncFile(file: types.Handle) !void {
    const fd: c.fd_t = @intCast(file);
    if (c.fsync(fd) != 0) return error.SyncFailed;
}

// ---- 元数据写入、路径解析与硬链接（阶段 F）--------------------------------

/// 改权限位（`fchmod`）。`mode` 是 POSIX 权限位。
pub fn setFilePermissions(file: types.Handle, mode: u32) !void {
    const fd: c.fd_t = @intCast(file);
    if (c.fchmod(fd, @intCast(mode)) != 0) return error.SetPermissionsFailed;
}

/// 改属主（`fchown`）。
pub fn setFileOwner(file: types.Handle, uid: u32, gid: u32) !void {
    const fd: c.fd_t = @intCast(file);
    if (c.fchown(fd, uid, gid) != 0) return error.SetOwnerFailed;
}

/// 改时间戳（`futimens`）。时间是 Unix 纪元纳秒。
pub fn setFileTimestamps(file: types.Handle, atime_ns: i64, mtime_ns: i64) !void {
    const fd: c.fd_t = @intCast(file);
    const times = [_]c.timespec{
        .{ .sec = @divFloor(atime_ns, 1_000_000_000), .nsec = @mod(atime_ns, 1_000_000_000) },
        .{ .sec = @divFloor(mtime_ns, 1_000_000_000), .nsec = @mod(mtime_ns, 1_000_000_000) },
    };
    if (c.futimens(fd, &times) != 0) return error.SetTimestampsFailed;
}

/// 按路径改权限位（`fchmodat`）。
pub fn setPermissions(path: []const u8, mode: u32) !void {
    var zbuf: [1024]u8 = undefined;
    const z = try zpath(path, &zbuf);
    if (c.fchmodat(std.posix.AT.FDCWD, z.ptr, @intCast(mode), 0) != 0) return error.SetPermissionsFailed;
}

/// 按路径改属主（`fchownat`）。
pub fn setOwner(path: []const u8, uid: u32, gid: u32) !void {
    var zbuf: [1024]u8 = undefined;
    const z = try zpath(path, &zbuf);
    if (c.fchownat(std.posix.AT.FDCWD, z.ptr, uid, gid, 0) != 0) return error.SetOwnerFailed;
}

/// 按路径改时间戳（`utimensat`）。
pub fn setTimestamps(path: []const u8, atime_ns: i64, mtime_ns: i64) !void {
    var zbuf: [1024]u8 = undefined;
    const z = try zpath(path, &zbuf);
    const times = [_]c.timespec{
        .{ .sec = @divFloor(atime_ns, 1_000_000_000), .nsec = @mod(atime_ns, 1_000_000_000) },
        .{ .sec = @divFloor(mtime_ns, 1_000_000_000), .nsec = @mod(mtime_ns, 1_000_000_000) },
    };
    if (c.utimensat(std.posix.AT.FDCWD, z.ptr, &times, 0) != 0) return error.SetTimestampsFailed;
}

/// 检查路径可达性（`access`）。`mode`: 0=存在、4=可读、2=可写、1=可执行。
pub fn access(path: []const u8, mode: u32) !void {
    var zbuf: [1024]u8 = undefined;
    const z = try zpath(path, &zbuf);
    if (c.access(z.ptr, mode) != 0) {
        return switch (std.posix.errno(@as(isize, -1))) {
            .NOENT => error.FileNotFound,
            .ACCES => error.AccessDenied,
            else => error.AccessFailed,
        };
    }
}

/// 解析符号链接拿绝对路径（`realpath`）。
/// BSD/Darwin 有 libc 的 `realpath(3)`，直接用。
pub fn realPath(path: []const u8, buf: []u8) !usize {
    var zbuf: [1024]u8 = undefined;
    const z = try zpath(path, &zbuf);
    const result = c.realpath(z.ptr, buf.ptr) orelse {
        return switch (std.posix.errno(@as(isize, -1))) {
            .NOENT => error.FileNotFound,
            else => error.RealPathFailed,
        };
    };
    _ = result;
    // realpath 写入 buf，返回长度 = strlen(buf)
    var n: usize = 0;
    while (n < buf.len and buf[n] != 0) n += 1;
    return n;
}

/// 创建硬链接（`linkat`）。两个路径指向同一 inode。
pub fn hardLink(old_path: []const u8, new_path: []const u8) !void {
    var obuf: [1024]u8 = undefined;
    var nbuf: [1024]u8 = undefined;
    const o = try zpath(old_path, &obuf);
    const n = try zpath(new_path, &nbuf);
    if (c.linkat(std.posix.AT.FDCWD, o.ptr, std.posix.AT.FDCWD, n.ptr, 0) != 0) return error.HardLinkFailed;
}

// ---- 符号链接读取 + 目录流式句柄（阶段 C）--------------------------------

/// 读符号链接指向的目标。
pub fn readLink(link_path: []const u8, buf: []u8) !usize {
    var zbuf: [1024]u8 = undefined;
    const z = try zpath(link_path, &zbuf);
    const rc = c.readlink(z.ptr, buf.ptr, buf.len);
    if (rc < 0) {
        return switch (std.posix.errno(@as(isize, -1))) {
            .NOENT => error.FileNotFound,
            .INVAL => error.NotASymLink,
            else => error.ReadLinkFailed,
        };
    }
    const n: usize = @intCast(rc);
    // 与 Linux 侧同样的理由：`readlink` 装满缓冲时静默截断，
    // n == buf.len 分不清「刚好」和「被切」，宁可报错。
    if (n >= buf.len) return error.NameTooLong;
    return n;
}

/// 打开目录拿 fd。
pub fn openDir(path: []const u8) !types.Handle {
    var zbuf: [1024]u8 = undefined;
    const z = try zpath(path, &zbuf);
    // 直接 `opendir` 并把 `DIR*` 本身当句柄：`readdir` 是逐条推进的
    // 有状态游标，天然没有「整批前移丢条目」的问题。这比 open(2) + 手工
    // getdirentries 解析更稳——实测 macOS 上后者用 seekoff + lseek 回退
    // 会无限重复同一批条目（CI 抓到 expected 5, found 40）。
    const d = c.opendir(z.ptr) orelse {
        return switch (std.posix.errno(@as(isize, -1))) {
            .NOENT => error.FileNotFound,
            .ACCES => error.AccessDenied,
            .NOTDIR => error.NotDirectory,
            else => error.OpenFailed,
        };
    };
    return @intFromPtr(d);
}

/// 从目录句柄读下一批条目。
///
/// 用 `readdir` 逐条推进：每次调用只消耗一条，游标状态由 `DIR*` 自己
/// 维护在堆上，跨 `readDirHandle` 调用持续有效。因此不存在 Linux
/// `getdents64` 那种「整批前移、缓冲装不下就丢」的问题，也不需要任何
/// 偏移回退技巧。
pub fn readDirHandle(dir: types.Handle, buf: []types.DirEntry) !usize {
    if (buf.len == 0) return 0;
    const d: *c.DIR = @ptrFromInt(dir);

    var count: usize = 0;
    while (count < buf.len) {
        const ent = c.readdir(d) orelse break; // 读完（或出错）
        // Darwin 的名字是定长数组按 NUL 截断；FreeBSD 是 [255:0]。
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (name.len > buf[count].name.len) continue; // 名字超长，跳过
        @memcpy(buf[count].name[0..name.len], name);
        buf[count].len = name.len;
        buf[count].is_dir = ent.type == c.DT.DIR;
        count += 1;
    }
    return count;
}

/// 关闭目录句柄。幂等（同一实例重复调用由节点层保证）。
pub fn closeDir(dir: types.Handle) void {
    const d: *c.DIR = @ptrFromInt(dir);
    _ = c.closedir(d);
}

test "kqueue backend type-checks end to end" {
    // 强制分析整个后端（根测试文件若无 test 块则什么也不分析）。
    // 逐个引用入口点即可对每个函数体做类型检查。
    _ = create;
    _ = createSocket;
    _ = createTcpSocket;
    _ = bindSocket;
    _ = listenSocket;
    _ = localAddress;
    _ = acceptSocket;
    _ = connectSocket;
    _ = setReuseAddress;
    _ = closeSocket;
    _ = sendBlocking;
    _ = tickCount;
    _ = fileSize;
    _ = readFileInto;
    _ = writeFileAll;
    _ = deleteFile;
    _ = &vtable_storage;
}

// ---- 真机回归：fd-slot 表的全双工 / 同方向多 pending ----------------------
// 只在 macOS / FreeBSD 真机上跑（CI 的 macos-latest）；其它平台只做编译校验。
// 这两个用例验证新的 slots[] + FIFO 链 + ONESHOT 重挂逻辑，旧实现的
// "同 filter 只留一个 pending" 会直接丢节点。

const can_run_runtime = builtin.os.tag == .macos or builtin.os.tag == .freebsd;

fn kqPair() ![2]i32 {
    var fds: [2]i32 = undefined;
    if (c.socketpair(@intCast(c.AF.UNIX), @intCast(c.SOCK.STREAM), 0, &fds) < 0)
        return error.SocketPairFailed;
    return fds;
}

test "kqueue: 同一 fd 全双工 recv+send 不丢方向" {
    if (!can_run_runtime) return error.SkipZigTest;
    var l = loop_mod.Loop.init(try create(std.testing.allocator, .{}), std.testing.allocator, .{});
    defer l.deinit();

    const pair = try kqPair();
    defer _ = c.close(pair[0]);
    defer _ = c.close(pair[1]);

    const Ctx = struct {
        var recv_done = false;
        var send_done = false;
        var recv_buf: [8]u8 = undefined;
        var recv_node: completion.NetRecv = undefined;
        var send_node: completion.NetSend = undefined;
        var peer: i32 = 0;

        fn onRecv(lp: *loop_mod.Loop, cc: *completion.Completion) void {
            const r: *completion.NetRecv = @fieldParentPtr("c", cc);
            recv_done = r.c.err == null and r.c.bytes == 3;
            if (recv_done) tryStop(lp);
        }
        fn onSend(lp: *loop_mod.Loop, cc: *completion.Completion) void {
            const s: *completion.NetSend = @fieldParentPtr("c", cc);
            send_done = s.c.err == null and s.c.bytes == 3;
            if (send_done) tryStop(lp);
        }
        fn tryStop(lp: *loop_mod.Loop) void {
            if (recv_done and send_done) lp.stop();
        }
    };
    Ctx.recv_done = false;
    Ctx.send_done = false;
    Ctx.peer = pair[1];

    Ctx.recv_node = completion.NetRecv.init(@intCast(pair[0]), &Ctx.recv_buf);
    Ctx.recv_node.c.callback = &Ctx.onRecv;
    Ctx.send_node = completion.NetSend.init(@intCast(pair[0]), "abc");
    Ctx.send_node.c.callback = &Ctx.onSend;
    l.add(&Ctx.recv_node.c);
    l.add(&Ctx.send_node.c);

    const Writer = struct {
        fn run(fd: i32) void {
            const ts: c.timespec = .{ .sec = 0, .nsec = 20 * 1_000_000 };
            _ = c.nanosleep(&ts, null);
            _ = c.write(fd, "xyz", 3);
        }
    };
    const t = try std.Thread.spawn(.{}, Writer.run, .{Ctx.peer});
    defer t.join();

    var guard = completion.Timer.init(2000);
    guard.c.callback = struct {
        fn cb(lp: *loop_mod.Loop, cc: *completion.Completion) void {
            _ = cc;
            lp.stop();
        }
    }.cb;
    l.add(&guard.c);
    try l.run();
    try std.testing.expect(Ctx.send_done);
    try std.testing.expect(Ctx.recv_done);
    try std.testing.expectEqualStrings("xyz", Ctx.recv_buf[0..3]);
}

test "kqueue: 同一 fd 同方向多个 recv 依次完成" {
    if (!can_run_runtime) return error.SkipZigTest;
    const n: usize = 4;
    var l = loop_mod.Loop.init(try create(std.testing.allocator, .{}), std.testing.allocator, .{});
    defer l.deinit();

    const pair = try kqPair();
    defer _ = c.close(pair[0]);
    defer _ = c.close(pair[1]);
    _ = c.write(pair[1], "abcd", n);

    const Ctx = struct {
        var done: usize = 0;
        var bufs: [n][1]u8 = undefined;
        var nodes: [n]completion.NetRecv = undefined;

        fn onRecv(lp: *loop_mod.Loop, cc: *completion.Completion) void {
            const r: *completion.NetRecv = @fieldParentPtr("c", cc);
            if (r.c.err == null and r.c.bytes == 1) done += 1;
            if (done == n) lp.stop();
        }
    };
    Ctx.done = 0;
    for (&Ctx.nodes, 0..) |*node, i| {
        node.* = completion.NetRecv.init(@intCast(pair[0]), &Ctx.bufs[i]);
        node.c.callback = &Ctx.onRecv;
        l.add(&node.c);
    }

    var guard = completion.Timer.init(2000);
    guard.c.callback = struct {
        fn cb(lp: *loop_mod.Loop, cc: *completion.Completion) void {
            _ = cc;
            lp.stop();
        }
    }.cb;
    l.add(&guard.c);
    try l.run();
    try std.testing.expectEqual(@as(usize, n), Ctx.done);
}
