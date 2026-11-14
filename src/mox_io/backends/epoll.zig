//! `mox_io` 的 Linux `epoll` 后端。
//!
//! `io_uring` 被内核 / seccomp / 容器策略禁用时，本后端接管事件循环。
//! 与 kqueue 后端同构：epoll 只给「就绪」不给「完成」，因此每个未完成
//! 操作注册一个 `ONESHOT` 事件并记一条 `Pending`；`waitBatch` 拿到就绪
//! 事件后就地执行非阻塞 `recv/send/accept/...`，再合成循环期望的完成包。
//!
//! 同步辅助函数（建 socket / bind / listen / 文件读写）直接复用
//! `uring.zig` 里与环无关的 pub 实现，避免重复一套 POSIX 编组代码。
//! `Work` 唤醒用 `eventfd` 注册进同一个 epoll 实例，无需额外线程。

const std = @import("std");
const linux = std.os.linux;
const types = @import("../types.zig");
const io_mod = @import("../io.zig");
const completion = @import("../completion.zig");
const sys = @import("../sys.zig");
const loop_mod = @import("../loop.zig");
const uring = @import("uring.zig");
const net = std.Io.net;

const Handle = types.Handle;
const INVALID_HANDLE = types.INVALID_HANDLE;

/// `epoll_wait` 一次最多取回的事件数；与 `Loop` 的 batch 上限无关，
/// 未取完的留在 `state.events` 里，下一次 `waitBatch` 优先消费。
const MAX_EVENTS = 64;

/// slot 表初始容量（按 `Options.queue_size` 放大）。按 fd 索引；遇到更大的
/// fd 时指数扩容一次，fd 集合稳定后不再分配（稳态 0 malloc）。
const MIN_SLOTS: usize = 1024;

const Kind = enum { recv, send, accept, connect, udp_recv, udp_send, watch, recvmsg, sendmsg };

const Pending = struct {
    fd: i32 = 0,
    /// 关注方向：`EPOLL.IN` / `EPOLL.OUT`；`watch` 可两者皆有。
    events: u32 = 0,
    kind: Kind = .recv,
    scratch: *types.Scratch = undefined,
    buf: []u8 = &.{},
    /// `udp_recv` 的源地址缓冲，指向调用方节点，随节点一起存活。
    from: []u8 = &.{},
    /// `udp_send` 的 sockaddr 存储：编在调用方节点的 `hdr` 里。
    hdr: []usize = &.{},
    hdr_len: linux.socklen_t = 0,
    /// `recvmsg`/`sendmsg` 的 iovec 来源：指向调用方节点的 bufs 切片。
    msg_bufs: ?[]const []const u8 = null,
    /// 池中的下一个下标（同方向 FIFO 链 / 空闲链）。用下标而不是指针：
    /// 池扩容搬迁时索引稳定，不会留下悬垂指针。`NO_PENDING` = 链尾。
    next: u32 = NO_PENDING,
};

const NO_PENDING: u32 = std.math.maxInt(u32);

/// 一个 fd 上的读 / 写两个待办链（池下标）。fd 直接当数组下标，定位 O(1)：
/// 对齐 libev `anfds[]` / libuv watcher 数组。
const FdSlot = struct {
    read: u32 = NO_PENDING,
    write: u32 = NO_PENDING,
    /// kernel 侧**当前仍生效**的兴趣掩码（不含 ONESHOT）。
    /// 初始 0；`EPOLLONESHOT` 事件到达会同时禁用 IN/OUT，此时置回 0。
    /// 用「掩码」而不是 bool 表示注册状态：want == armed_mask 时无需
    /// 任何 `epoll_ctl`，`0` 表示内核里已无该 fd 的兴趣（无需 CTL_DEL）。
    armed_mask: u32 = 0,
};

const State = struct {
    alloc: std.mem.Allocator,
    ep: i32,
    efd: i32,
    /// fd → watcher，O(1) 定位。
    slots: []FdSlot = &.{},
    /// 预分配的 `Pending` 池 + 空闲链：`putPending` 只摘一个格子，
    /// submit 热路径零分配；用完扩容（指数），索引链不会失效。
    pool: []Pending = &.{},
    free_head: u32 = NO_PENDING,
    /// 上一轮 `refs` 装不下的就绪事件。定长数组 + 游标，永不分配。
    events: [MAX_EVENTS]linux.epoll_event = undefined,
    events_head: usize = 0,
    events_len: usize = 0,
    /// cancel / close / 溢出合成的完成包，预分配环形缓冲。
    queued: []types.Ref = &.{},
    queued_head: usize = 0,
    queued_tail: usize = 0,
    ref: types.Ref = undefined,

    fn queuedLen(self: *const State) usize {
        return self.queued_tail -% self.queued_head;
    }

    fn pushQueued(self: *State, r: types.Ref) void {
        if (self.queuedLen() >= self.queued.len) growQueued(self);
        self.queued[self.queued_tail % self.queued.len] = r;
        self.queued_tail +%= 1;
    }

    fn popQueued(self: *State) ?types.Ref {
        if (self.queued_head == self.queued_tail) return null;
        const r = self.queued[self.queued_head % self.queued.len];
        self.queued_head +%= 1;
        return r;
    }

    fn poolGet(self: *State, idx: u32) *Pending {
        return &self.pool[idx];
    }

    /// 摘一个空闲格子；不足时扩容并把新格子接进空闲链。
    fn allocPending(self: *State) !u32 {
        if (self.free_head != NO_PENDING) {
            const idx = self.free_head;
            self.free_head = self.pool[idx].next;
            return idx;
        }
        const old_len = self.pool.len;
        const new_len = @max(old_len * 2, 64);
        const grown = if (old_len == 0)
            try self.alloc.alloc(Pending, new_len)
        else
            try self.alloc.realloc(self.pool, new_len);
        self.pool = grown;
        var i: usize = old_len;
        while (i < new_len - 1) : (i += 1) {
            grown[i] = .{ .next = @intCast(i + 1) };
        }
        grown[new_len - 1] = .{ .next = NO_PENDING };
        const first: u32 = @intCast(old_len);
        self.free_head = if (old_len + 1 < new_len) first + 1 else NO_PENDING;
        return first;
    }

    fn freePending(self: *State, idx: u32) void {
        self.pool[idx].next = self.free_head;
        self.free_head = idx;
    }
};

/// 容量不足时翻倍并把环形内容线性化。只在取消/溢出风暴超过预分配容量时
/// 发生；极端 OOM 直接 fail-fast，**绝不静默丢完成包**（丢了就是回调永不
/// 触发、节点泄漏，比崩溃更难排查）。
fn growQueued(state: *State) void {
    const old_cap = state.queued.len;
    const new_cap = @max(old_cap * 2, 16);
    const grown = state.alloc.alloc(types.Ref, new_cap) catch
        @panic("mox_io/epoll: OOM while queueing a completion");
    const n = state.queuedLen();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        grown[i] = state.queued[(state.queued_head +% i) % old_cap];
    }
    if (old_cap != 0) state.alloc.free(state.queued);
    state.queued = grown;
    state.queued_head = 0;
    state.queued_tail = n;
}

fn stateOf(userdata: ?*anyopaque) *State {
    return @ptrCast(@alignCast(userdata.?));
}

fn fdOf(h: Handle) i32 {
    return @intCast(h);
}

fn signed(rc: usize) isize {
    return @bitCast(rc);
}

/// Linux 系统调用以 `-errno` 返回错误。
fn cvt(rc: usize) !usize {
    if (signed(rc) < 0) return sys.fromSyscall(signed(rc));
    return rc;
}

// ---- epoll 注册 ------------------------------------------------------------

fn evDelete(state: *State, fd: i32) void {
    _ = linux.epoll_ctl(state.ep, linux.EPOLL.CTL_DEL, fd, null);
}

/// 取 fd 对应的 slot；首次遇到更大的 fd 时扩容一次（指数）。
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

/// 不扩容的查询：事件 / 取消 / 关闭路径用，fd 从没提交过就直接返回 null。
fn slotFor(state: *State, fd: i32) ?*FdSlot {
    if (fd < 0) return null;
    const idx: usize = @intCast(fd);
    if (idx >= state.slots.len) return null;
    return &state.slots[idx];
}

fn wantedMask(slot: *const FdSlot) u32 {
    var m: u32 = 0;
    if (slot.read != NO_PENDING) m |= linux.EPOLL.IN;
    if (slot.write != NO_PENDING) m |= linux.EPOLL.OUT;
    return m;
}

/// 让 epoll 注册与 slot 里的待办保持一致：
/// - want == armed_mask → **0 syscall**（最常见：新提交的方向已经武装）
/// - 有剩余方向但 kernel 侧兴趣已失效 / 掩码变化 → 一次 ADD/MOD
/// - 无剩余方向且 kernel 侧仍注册 → 一次 DEL
///
/// 注册掩码是**这个 fd 上所有未完成方向的并集**：只注册单个方向的话，
/// 「先 recv 后 send」的第二次 MOD 会把 IN 抹掉，读方向再也等不到事件。
fn syncArm(state: *State, fd: i32, force: bool) !void {
    const slot = slotFor(state, fd) orelse return;
    const want = wantedMask(slot);
    if (want == 0) {
        if (slot.armed_mask != 0) {
            evDelete(state, fd);
            slot.armed_mask = 0;
        }
        return;
    }
    if (!force and slot.armed_mask == want) return;
    // 只有真正注册进 epoll 的 fd 才设 O_NONBLOCK：finishOne 在就绪后就地
    // 执行系统调用，不能把循环线程卡住。同步辅助函数保持阻塞语义。
    setNonblock(fd);
    var ep_ev = linux.epoll_event{
        .events = want | linux.EPOLL.ONESHOT,
        .data = .{ .fd = fd },
    };
    var rc = linux.epoll_ctl(state.ep, linux.EPOLL.CTL_ADD, fd, &ep_ev);
    if (signed(rc) < 0) rc = linux.epoll_ctl(state.ep, linux.EPOLL.CTL_MOD, fd, &ep_ev);
    _ = try cvt(rc);
    slot.armed_mask = want;
}

fn cancelRef(scratch: *types.Scratch) types.Ref {
    return .{
        .scratch = scratch,
        .bytes = 0,
        .failed = true,
        .new_handle = INVALID_HANDLE,
    };
}

/// 挂一个待办。同一方向的多个操作按 FIFO 排队，不返回 `error.Busy`：
/// 现有 API（连续多个 recv、UDP 批量收）依赖这个语义。
fn putPending(state: *State, p: Pending) !void {
    // 每条方向链独占一个池格子，不能共享 next 或把同一格子归还两次。
    if (p.events & linux.EPOLL.IN != 0 and p.events & linux.EPOLL.OUT != 0) {
        var read = p;
        read.events = linux.EPOLL.IN;
        try putPending(state, read);
        var write = p;
        write.events = linux.EPOLL.OUT;
        putPending(state, write) catch |err| {
            const slot = slotFor(state, p.fd).?;
            if (removeFrom(state, &slot.read, p.scratch)) |idx| state.freePending(idx);
            syncArm(state, p.fd, false) catch {};
            return err;
        };
        return;
    }
    const slot = try slotOf(state, p.fd);
    const idx = try state.allocPending();
    state.pool[idx] = .{ .fd = p.fd, .events = p.events, .kind = p.kind, .scratch = p.scratch, .buf = p.buf, .from = p.from, .hdr = p.hdr, .hdr_len = p.hdr_len, .msg_bufs = p.msg_bufs, .next = NO_PENDING };
    const wants_read = p.events & linux.EPOLL.IN != 0;
    const wants_write = p.events & linux.EPOLL.OUT != 0;
    if (wants_read) appendTo(state, &slot.read, idx);
    if (wants_write) appendTo(state, &slot.write, idx);
    syncArm(state, p.fd, false) catch |e| {
        // arm 失败（fd 已关闭等）：摘掉刚挂的待办并同步报错，让 Loop 走
        // 同步完成路径，不能把节点留在 slot 里等一个永不来的事件。
        if (wants_read) _ = removeFrom(state, &slot.read, p.scratch);
        if (wants_write) _ = removeFrom(state, &slot.write, p.scratch);
        state.freePending(idx);
        return e;
    };
}

fn appendTo(state: *State, head: *u32, idx: u32) void {
    if (head.* == NO_PENDING) {
        head.* = idx;
        return;
    }
    var cur = head.*;
    while (state.pool[cur].next != NO_PENDING) cur = state.pool[cur].next;
    state.pool[cur].next = idx;
}

/// 按 scratch 从一条链里摘掉待办，返回它的池下标（供释放）；双向 WatchFd
/// 会占读 / 写两条链，调用方需用 `dropByScratch` 一次清干净。
fn removeFrom(state: *State, head: *u32, scratch: *types.Scratch) ?u32 {
    var cur = head.*;
    var prev: u32 = NO_PENDING;
    while (cur != NO_PENDING) {
        const p = &state.pool[cur];
        if (p.scratch == scratch) {
            if (prev != NO_PENDING) state.pool[prev].next = p.next else head.* = p.next;
            p.next = NO_PENDING;
            return cur;
        }
        prev = cur;
        cur = p.next;
    }
    return null;
}

// ---- VTable 接线 ------------------------------------------------------------

fn vtDeinit(userdata: ?*anyopaque) void {
    const state = stateOf(userdata);
    const alloc = state.alloc;
    if (state.slots.len != 0) alloc.free(state.slots);
    if (state.pool.len != 0) alloc.free(state.pool);
    if (state.queued.len != 0) alloc.free(state.queued);
    _ = linux.close(state.efd);
    _ = linux.close(state.ep);
    alloc.destroy(state);
}

fn vtNow(userdata: ?*anyopaque) u64 {
    _ = userdata;
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

fn vtCreateSocket(userdata: ?*anyopaque, address: net.IpAddress) anyerror!Handle {
    _ = userdata;
    return uring.createTcpSocket(address);
}

fn vtSetReuseAddress(userdata: ?*anyopaque, socket: Handle, on: bool) anyerror!void {
    _ = userdata;
    return uring.setReuseAddress(socket, on);
}

fn vtSetSockOpt(userdata: ?*anyopaque, socket: Handle, opt: types.SockOpt, value: u32) anyerror!void {
    _ = userdata;
    return uring.setSockOpt(socket, opt, value);
}

fn vtShutdownSend(userdata: ?*anyopaque, socket: Handle) anyerror!void {
    _ = userdata;
    return uring.shutdownSend(socket);
}

fn vtShutdown(userdata: ?*anyopaque, socket: Handle, how: types.ShutdownHow) anyerror!void {
    _ = userdata;
    return uring.shutdownSocket(socket, how);
}

fn vtSendMsg(
    userdata: ?*anyopaque,
    socket: Handle,
    bufs: []const []const u8,
    hdr: []usize,
    scratch: *types.Scratch,
) anyerror!void {
    _ = hdr;
    // **不能同步 sendmsg**：socket 写不进去时会把整个循环线程卡住。
    // 正确做法与 `vtSend` 一致：等 EPOLLOUT，就绪后在 reap 里做那一次
    // 系统调用。
    const state = stateOf(userdata);
    const fd = fdOf(socket);
    try putPending(state, .{
        .fd = fd,
        .events = linux.EPOLL.OUT,
        .kind = .sendmsg,
        .scratch = scratch,
        .msg_bufs = bufs,
    });
}

fn vtRecvMsg(
    userdata: ?*anyopaque,
    socket: Handle,
    bufs: []const []u8,
    hdr: []usize,
    scratch: *types.Scratch,
) anyerror!void {
    _ = hdr;
    // 理由同 `vtSendMsg`：绝不能同步 recvmsg。
    const state = stateOf(userdata);
    const fd = fdOf(socket);
    try putPending(state, .{
        .fd = fd,
        .events = linux.EPOLL.IN,
        .kind = .recvmsg,
        .scratch = scratch,
        .msg_bufs = @ptrCast(bufs),
    });
}

fn vtBind(userdata: ?*anyopaque, socket: Handle, address: net.IpAddress) anyerror!void {
    _ = userdata;
    return uring.bindSocket(socket, address);
}

fn vtListen(userdata: ?*anyopaque, socket: Handle, backlog: c_int) anyerror!void {
    _ = userdata;
    return uring.listenSocket(socket, backlog);
}

fn vtFileSize(userdata: ?*anyopaque, path: []const u8) anyerror!u64 {
    _ = userdata;
    return uring.fileSize(path);
}

fn vtMakeDir(userdata: ?*anyopaque, path: []const u8, mode: u32) anyerror!void {
    _ = userdata;
    return uring.makeDir(path, mode);
}

fn vtRemoveDir(userdata: ?*anyopaque, path: []const u8) anyerror!void {
    _ = userdata;
    return uring.removeDir(path);
}

fn vtRename(userdata: ?*anyopaque, old_path: []const u8, new_path: []const u8) anyerror!void {
    _ = userdata;
    return uring.rename(old_path, new_path);
}

fn vtSymLink(userdata: ?*anyopaque, target: []const u8, link_path: []const u8) anyerror!void {
    _ = userdata;
    return uring.symLink(target, link_path);
}

fn vtStatPath(userdata: ?*anyopaque, path: []const u8) anyerror!types.Stat {
    _ = userdata;
    const st = try uring.stat(path);
    return .{ .kind = @fromBackingInt(@intCast(@backingInt(st.kind))), .size = st.size, .mtime_ms = st.mtime_ms };
}

fn vtListDir(userdata: ?*anyopaque, path: []const u8, buf: []types.DirEntry) anyerror!usize {
    _ = userdata;
    // 两个后端的 `DirEntry` 布局一致（同样的 name/len/is_dir），直接按内存复用。
    return uring.listDir(path, @ptrCast(buf));
}

fn vtReadFileInto(userdata: ?*anyopaque, path: []const u8, buf: []u8) anyerror!usize {
    _ = userdata;
    return uring.readFileInto(path, buf);
}

fn vtWriteFileAll(userdata: ?*anyopaque, path: []const u8, bytes: []const u8) anyerror!void {
    _ = userdata;
    return uring.writeFileAll(path, bytes);
}

fn vtReadFileAt(userdata: ?*anyopaque, path: []const u8, offset: u64, buf: []u8) anyerror!usize {
    _ = userdata;
    return uring.readFileAt(path, offset, buf);
}

fn vtAppendFile(userdata: ?*anyopaque, path: []const u8, bytes: []const u8) anyerror!void {
    _ = userdata;
    return uring.appendFile(path, bytes);
}

fn vtTruncateFile(userdata: ?*anyopaque, path: []const u8, size: u64) anyerror!void {
    _ = userdata;
    return uring.truncateFile(path, size);
}

// 文件句柄层：Linux 两后端共用同一套 syscall 实现（见 uring.zig）。
fn vtOpenFile(userdata: ?*anyopaque, path: []const u8, mode: types.FileMode) anyerror!types.Handle {
    _ = userdata;
    return uring.openFile(path, mode);
}

fn vtReadFileHandle(userdata: ?*anyopaque, file: types.Handle, offset: u64, buf: []u8) anyerror!usize {
    _ = userdata;
    return uring.readFileHandle(file, offset, buf);
}

fn vtWriteFileHandle(userdata: ?*anyopaque, file: types.Handle, offset: u64, bytes: []const u8) anyerror!usize {
    _ = userdata;
    return uring.writeFileHandle(file, offset, bytes);
}

fn vtCloseFile(userdata: ?*anyopaque, file: types.Handle) void {
    _ = userdata;
    uring.closeFile(file);
}

// 句柄级元数据与同步：与 uring 后端共用同一套 syscall 实现。
fn vtStatFile(userdata: ?*anyopaque, file: types.Handle) anyerror!types.Stat {
    _ = userdata;
    const st = try uring.statFile(file);
    return .{ .kind = @fromBackingInt(@intCast(@backingInt(st.kind))), .size = st.size, .mtime_ms = st.mtime_ms };
}

fn vtSetFileSize(userdata: ?*anyopaque, file: types.Handle, size: u64) anyerror!void {
    _ = userdata;
    return uring.setFileSize(file, size);
}

fn vtSyncFile(userdata: ?*anyopaque, file: types.Handle) anyerror!void {
    _ = userdata;
    return uring.syncFile(file);
}

// 阶段 F：与 uring 后端共用同一套实现（同属 Linux）。
fn vtSetFilePermissions(userdata: ?*anyopaque, file: types.Handle, mode: u32) anyerror!void {
    _ = userdata;
    return uring.setFilePermissions(file, mode);
}

fn vtSetFileOwner(userdata: ?*anyopaque, file: types.Handle, uid: u32, gid: u32) anyerror!void {
    _ = userdata;
    return uring.setFileOwner(file, uid, gid);
}

fn vtSetFileTimestamps(userdata: ?*anyopaque, file: types.Handle, atime_ns: i64, mtime_ns: i64) anyerror!void {
    _ = userdata;
    return uring.setFileTimestamps(file, atime_ns, mtime_ns);
}

fn vtSetPermissions(userdata: ?*anyopaque, path: []const u8, mode: u32) anyerror!void {
    _ = userdata;
    return uring.setPermissions(path, mode);
}

fn vtSetOwner(userdata: ?*anyopaque, path: []const u8, uid: u32, gid: u32) anyerror!void {
    _ = userdata;
    return uring.setOwner(path, uid, gid);
}

fn vtSetTimestamps(userdata: ?*anyopaque, path: []const u8, atime_ns: i64, mtime_ns: i64) anyerror!void {
    _ = userdata;
    return uring.setTimestamps(path, atime_ns, mtime_ns);
}

fn vtAccess(userdata: ?*anyopaque, path: []const u8, mode: u32) anyerror!void {
    _ = userdata;
    return uring.access(path, mode);
}

fn vtRealPath(userdata: ?*anyopaque, path: []const u8, buf: []u8) anyerror!usize {
    _ = userdata;
    return uring.realPath(path, buf);
}

fn vtHardLink(userdata: ?*anyopaque, old_path: []const u8, new_path: []const u8) anyerror!void {
    _ = userdata;
    return uring.hardLink(old_path, new_path);
}

// 阶段 C：与 uring 后端共用同一套实现（同属 Linux）。
fn vtReadLink(userdata: ?*anyopaque, link_path: []const u8, buf: []u8) anyerror!usize {
    _ = userdata;
    return uring.readLink(link_path, buf);
}

fn vtOpenDir(userdata: ?*anyopaque, path: []const u8) anyerror!types.Handle {
    _ = userdata;
    return uring.openDir(path);
}

fn vtReadDirHandle(userdata: ?*anyopaque, dir: types.Handle, buf: []types.DirEntry) anyerror!usize {
    _ = userdata;
    return uring.readDirHandle(dir, buf);
}

fn vtCloseDir(userdata: ?*anyopaque, dir: types.Handle) void {
    _ = userdata;
    uring.closeDir(dir);
}

fn vtDeleteFile(userdata: ?*anyopaque, path: []const u8) anyerror!void {
    _ = userdata;
    try uring.deleteFileChecked(path);
}

fn vtAssociate(userdata: ?*anyopaque, socket: Handle, key: usize) anyerror!void {
    _ = userdata;
    _ = socket;
    _ = key;
}

fn vtSendFileTo(userdata: ?*anyopaque, socket: types.Handle, path: []const u8, offset: u64, count: usize) anyerror!usize {
    _ = userdata;
    return uring.vtSendFileTo(null, socket, path, offset, count);
}

fn vtCreateUnix(userdata: ?*anyopaque) anyerror!types.Handle {
    _ = userdata;
    return uring.vtCreateUnix(null);
}

fn vtBindUnix(userdata: ?*anyopaque, socket: types.Handle, path: []const u8) anyerror!void {
    _ = userdata;
    return uring.vtBindUnix(null, socket, path);
}

/// epoll 是就绪模型，没有「异步 connect」：非阻塞 `connect` 返回 EINPROGRESS
/// 后要等 `EPOLL.OUT`，由调用方通过 `WatchFd` 或 `NetConnect` 语义处理。
/// 这里直接做非阻塞 connect，立即连上（本机 UDS 常见）就返回，否则返回 null。
fn vtConnectUnix(userdata: ?*anyopaque, socket: types.Handle, path: []const u8, scratch: *types.Scratch) anyerror!?void {
    _ = userdata;
    var sa: linux.sockaddr.un = undefined;
    const len = try uring.buildUnixSockaddrPub(path, &sa);
    if (len > @sizeOf(types.Scratch)) return error.NameTooLong;
    @memcpy(std.mem.asBytes(scratch)[0..len], std.mem.asBytes(&sa)[0..len]);
    const rc = linux.connect(fdOf(socket), @ptrCast(@alignCast(scratch)), len);
    const rc_s = signed(rc);
    if (rc_s == 0) return {};
    if (rc_s == -@as(isize, @backingInt(linux.E.INPROGRESS))) return null;
    return error.ConnectFailed;
}

fn vtWatchFd(userdata: ?*anyopaque, fd: Handle, want: types.Ready, scratch: *types.Scratch) anyerror!?void {
    const state = stateOf(userdata);
    const raw = fdOf(fd);
    var events: u32 = 0;
    if (want.read) events |= linux.EPOLL.IN;
    if (want.write) events |= linux.EPOLL.OUT;
    if (events == 0) return error.NothingToWatch;
    try putPending(state, .{
        .fd = raw,
        .events = events,
        // ONESHOT 由 `arm` 统一加；这里关心 ERR/HUP 也会被 `complete` 接受。
        .kind = .watch,
        .scratch = scratch,
    });
    return null;
}

fn vtRecv(userdata: ?*anyopaque, socket: Handle, buffer: []u8, scratch: *types.Scratch) anyerror!?usize {
    const state = stateOf(userdata);
    const fd = fdOf(socket);
    try putPending(state, .{
        .fd = fd,
        .events = linux.EPOLL.IN,
        .kind = .recv,
        .scratch = scratch,
        .buf = buffer,
    });
    return null;
}

fn vtSend(userdata: ?*anyopaque, socket: Handle, bytes: []const u8, scratch: *types.Scratch) anyerror!?usize {
    const state = stateOf(userdata);
    const fd = fdOf(socket);
    // send() 需要非 const 缓冲区；循环保证这些字节在操作期间存活。
    try putPending(state, .{
        .fd = fd,
        .events = linux.EPOLL.OUT,
        .kind = .send,
        .scratch = scratch,
        .buf = @constCast(bytes),
    });
    return null;
}

/// 关闭 fd：把这个 fd 上所有在飞操作合成失败完成包（让 `Loop` 能回收各自
/// 的节点），全部归还池格子，再撤销 epoll 注册并 close。
fn vtClose(userdata: ?*anyopaque, socket: Handle) void {
    closeImpl(userdata, socket) catch {};
}

/// 与 `vtClose` 相同的动作（摘掉 fd 上的在飞节点、注销 epoll 兴趣、
/// 关闭 fd），但把 `close(2)` 的 errno 映射成具体错误。
/// `EBADF` 说明句柄已失效（重复关闭 / 被别人关掉），其余归 `CloseFailed`。
fn vtCloseChecked(userdata: ?*anyopaque, socket: Handle) anyerror!void {
    return closeImpl(userdata, socket);
}

fn closeImpl(userdata: ?*anyopaque, socket: Handle) anyerror!void {
    const state = stateOf(userdata);
    const fd = fdOf(socket);
    const slot = slotFor(state, fd) orelse {
        return closeFdChecked(fd);
    };
    // 双向 WatchFd 同时在读 / 写链上是同一个 scratch：去重后每个节点
    // 只投递一次失败完成包。
    drainChain(state, &slot.read, &slot.write);
    drainChain(state, &slot.write, &slot.read);
    evDelete(state, fd);
    slot.armed_mask = 0;
    return closeFdChecked(fd);
}

/// 关闭 fd 并映射 errno。`EBADF` → `error.NotOpen`，其余 → `error.CloseFailed`。
fn closeFdChecked(fd: i32) anyerror!void {
    const rc = linux.close(fd);
    const rcs = signed(rc);
    if (rcs < 0) return switch (-rcs) {
        @as(isize, @intCast(@backingInt(linux.E.BADF))) => error.NotOpen,
        else => error.CloseFailed,
    };
}

fn drainChain(
    state: *State,
    head: *u32,
    other: *u32,
) void {
    var cur = head.*;
    head.* = NO_PENDING;
    while (cur != NO_PENDING) {
        const idx = cur;
        const p = state.pool[idx];
        cur = p.next;
        if (removeFrom(state, other, p.scratch)) |sibling| state.freePending(sibling);
        state.pushQueued(cancelRef(p.scratch));
        state.freePending(idx);
    }
}

/// 取消：fd 直接定位 slot，按 scratch 摘掉待办（读写同 scratch 的 watch
/// 两条链一起摘），同步重挂剩余方向，并合成一个失败完成包。
/// 完成包绝不静默丢弃：环路必须能回收被取消的节点。
///
/// `socket == INVALID_HANDLE` 时按 scratch 全表兜底：正常节点都带 fd，但
/// 定时器 / work 与本后端无关；万一有节点漏设 socket，也不会让取消静默
/// 失效（这条是异常路径，O(slot 数) 不影响热路径）。
fn vtCancel(userdata: ?*anyopaque, socket: Handle, scratch: *types.Scratch) void {
    const state = stateOf(userdata);
    if (socket == INVALID_HANDLE) {
        cancelAnywhere(state, scratch);
        return;
    }
    const fd = fdOf(socket);
    const slot = slotFor(state, fd) orelse {
        cancelAnywhere(state, scratch);
        return;
    };
    var found = false;
    if (removeFrom(state, &slot.read, scratch)) |idx| {
        state.freePending(idx);
        found = true;
    }
    if (removeFrom(state, &slot.write, scratch)) |idx| {
        state.freePending(idx);
        found = true;
    }
    if (!found) {
        // 已同步完成 / 上一轮取消过；也扫一遍兜底，防止 socket 填错。
        cancelAnywhere(state, scratch);
        return;
    }
    syncArm(state, fd, false) catch {};
    state.pushQueued(cancelRef(scratch));
}

fn cancelAnywhere(state: *State, scratch: *types.Scratch) void {
    for (state.slots, 0..) |*slot, idx| {
        var found = false;
        if (removeFrom(state, &slot.read, scratch)) |i| {
            state.freePending(i);
            found = true;
        }
        if (removeFrom(state, &slot.write, scratch)) |i| {
            state.freePending(i);
            found = true;
        }
        if (found) {
            syncArm(state, @intCast(idx), false) catch {};
            state.pushQueued(cancelRef(scratch));
            return;
        }
    }
}

fn vtAccept(userdata: ?*anyopaque, listen: Handle, accept_socket: Handle, addr_buf: []u8, scratch: *types.Scratch) anyerror!?usize {
    const state = stateOf(userdata);
    const fd = fdOf(listen);
    // 新 fd 由内核分配；预先建好的 socket 属于 AcceptEx 习惯，这里不用。
    _ = linux.close(fdOf(accept_socket));
    try putPending(state, .{
        .fd = fd,
        .events = linux.EPOLL.IN,
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
    const fd = fdOf(socket);
    var storage: [128]u8 = undefined;
    const len = buildSockaddr(address, &storage);
    // 非阻塞连接预期返回 EINPROGRESS；就绪后用 SO_ERROR 取结果。
    _ = linux.connect(fd, @ptrCast(@alignCast(&storage)), len);
    try putPending(state, .{
        .fd = fd,
        .events = linux.EPOLL.OUT,
        .kind = .connect,
        .scratch = scratch,
    });
}

fn vtUpdateConnect(userdata: ?*anyopaque, socket: Handle) void {
    _ = userdata;
    _ = socket;
}

// ---- UDP：与 kqueue 后端同一套「就绪 → 就地执行」搭桥 ---------------------

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
    const fd = fdOf(socket);
    try putPending(state, .{
        .fd = fd,
        .events = linux.EPOLL.IN,
        .kind = .udp_recv,
        .scratch = scratch,
        .buf = buf,
        .from = from,
    });
}

fn vtUdpSend(
    userdata: ?*anyopaque,
    socket: Handle,
    buf: []const u8,
    to: net.IpAddress,
    hdr: []usize,
    scratch: *types.Scratch,
) anyerror!void {
    const state = stateOf(userdata);
    const fd = fdOf(socket);
    const len = buildSockaddr(to, @ptrCast(@alignCast(hdr.ptr)));
    try putPending(state, .{
        .fd = fd,
        .events = linux.EPOLL.OUT,
        .kind = .udp_send,
        .scratch = scratch,
        .buf = @constCast(buf),
        .hdr = hdr,
        .hdr_len = len,
    });
}

fn vtWaitBatch(userdata: ?*anyopaque, timeout_ms: u32, refs: []types.Ref) anyerror!usize {
    const state = stateOf(userdata);
    var n: usize = 0;

    // 取消 / 上一轮溢出产生的合成完成包优先返回。
    while (n < refs.len) {
        refs[n] = state.popQueued() orelse break;
        n += 1;
    }
    if (n != 0) return n;

    if (state.events_head == state.events_len) {
        const wait_forever = timeout_ms >= std.math.maxInt(u32) / 2;
        const pt: i32 = if (wait_forever) -1 else @intCast(timeout_ms);
        const got = linux.epoll_wait(state.ep, &state.events, state.events.len, pt);
        if (signed(got) < 0) return 0;
        state.events_head = 0;
        state.events_len = @intCast(got);
    }
    while (state.events_head < state.events_len and n < refs.len) {
        const ev = state.events[state.events_head];
        state.events_head += 1;
        if (ev.data.fd == state.efd) {
            // Work 唤醒：读掉计数，让循环去 drainWork。
            var buf: [8]u8 = undefined;
            _ = linux.read(state.efd, &buf, buf.len);
            continue;
        }
        // 一个 epoll 事件最多同时命中读 / 写两个方向的待办。
        var staging: [2]types.Ref = undefined;
        const m = complete(state, ev, &staging);
        var i: usize = 0;
        while (i < m) : (i += 1) {
            if (n < refs.len) {
                refs[n] = staging[i];
                n += 1;
            } else {
                // refs 满了：完成包不丢，压进预分配环形缓冲下一轮再交。
                state.pushQueued(staging[i]);
            }
        }
    }
    return n;
}

/// 按 (fd, 方向) 就地完成待办，O(1)（fd 直接索引 slot）。
///
/// `EPOLLONESHOT` 到点会**同时**禁用该 fd 的 IN/OUT，因此这里必须把
/// 剩余方向用一次 `CTL_MOD` 重新武装——否则同 fd 上的另一个在飞操作会
/// 永远收不到事件。这是全双工正确性的关键，也是旧实现出错的地方。
///
/// 每次事件只消费命中的方向上**队头**一条；同方向其余待办留到下一次
/// ONESHOT 重挂后再收。这样既不会重复消费，也不用一次性分配批量结果。
fn complete(state: *State, ev: linux.epoll_event, out: *[2]types.Ref) usize {
    const fd = ev.data.fd;
    const slot = slotFor(state, fd) orelse return 0;
    slot.armed_mask = 0; // ONESHOT 已禁用这个 fd 的全部兴趣
    const has_err = ev.events & (linux.EPOLL.ERR | linux.EPOLL.HUP) != 0;
    var n: usize = 0;

    if (slot.read != NO_PENDING) {
        const idx = slot.read;
        const p = state.pool[idx];
        if (has_err or ev.events & p.events != 0) {
            slot.read = p.next;
            out[n] = finishOne(state, p, ev.events);
            n += 1;
            // 双向 WatchFd 占两条链：这一条一并摘掉，保证回调恰好一次。
            if (removeFrom(state, &slot.write, p.scratch)) |other|
                state.freePending(other);
            state.freePending(idx);
        }
    }
    if (slot.write != NO_PENDING) {
        const idx = slot.write;
        const p = state.pool[idx];
        if (has_err or ev.events & p.events != 0) {
            slot.write = p.next;
            out[n] = finishOne(state, p, ev.events);
            n += 1;
            if (removeFrom(state, &slot.read, p.scratch)) |other|
                state.freePending(other);
            state.freePending(idx);
        }
    }
    // 还有未完成方向就重挂；没有就撤销注册。
    syncArm(state, fd, true) catch {};
    return n;
}

fn finishOne(state: *State, p: Pending, ev_events: u32) types.Ref {
    var res: isize = 0;
    switch (p.kind) {
        // std 的 linux 层没有裸 recv/send；用 recvfrom/sendto 配空地址等价实现。
        .recv => res = @bitCast(linux.recvfrom(p.fd, p.buf.ptr, p.buf.len, 0, null, null)),
        .send => res = @bitCast(linux.sendto(p.fd, p.buf.ptr, p.buf.len, 0, null, 0)),
        // 必须带 CLOEXEC：fork+exec 时已接受的连接不能泄漏进子进程。
        // accept4 返回 -errno，用 @bitCast 保留负值交给 `failed` 判定。
        .accept => res = @bitCast(linux.accept4(p.fd, null, null, linux.SOCK.CLOEXEC)),
        .connect => {
            var err: c_int = 0;
            var len: linux.socklen_t = @sizeOf(c_int);
            _ = linux.getsockopt(p.fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&err), &len);
            res = if (err == 0) 0 else -err;
        },
        .udp_recv => {
            var len: linux.socklen_t = @intCast(p.from.len);
            res = @bitCast(linux.recvfrom(
                p.fd,
                p.buf.ptr,
                p.buf.len,
                0,
                @ptrCast(@alignCast(p.from.ptr)),
                &len,
            ));
        },
        .sendmsg => {
            // 可写了：这时 sendmsg 不会阻塞。
            const bufs = p.msg_bufs orelse &.{};
            var iov: [uring.IOV_MAX]std.posix.iovec_const = undefined;
            for (bufs, 0..) |b, i| iov[i] = .{ .base = b.ptr, .len = b.len };
            var msg: linux.msghdr_const = .{
                .name = null,
                .namelen = 0,
                .iov = &iov,
                .iovlen = @intCast(bufs.len),
                .control = null,
                .controllen = 0,
                .flags = 0,
            };
            res = @bitCast(linux.sendmsg(p.fd, &msg, linux.MSG.NOSIGNAL));
        },
        .recvmsg => {
            const bufs = p.msg_bufs orelse &.{};
            var iov: [uring.IOV_MAX]std.posix.iovec = undefined;
            for (bufs, 0..) |b, i| iov[i] = .{ .base = @constCast(b.ptr), .len = b.len };
            var msg: linux.msghdr = .{
                .name = null,
                .namelen = 0,
                .iov = &iov,
                .iovlen = @intCast(bufs.len),
                .control = null,
                .controllen = 0,
                .flags = 0,
            };
            res = @bitCast(linux.recvmsg(p.fd, &msg, 0));
        },
        .watch => {
            // 不代收数据，只把内核给的方向位翻成 `Ready` 回填给调用方。
            var r: types.Ready = .{};
            if (ev_events & linux.EPOLL.IN != 0) r.read = true;
            if (ev_events & linux.EPOLL.OUT != 0) r.write = true;
            if (ev_events & linux.EPOLL.ERR != 0) r.failed = true;
            if (ev_events & linux.EPOLL.HUP != 0) r.hangup = true;
            // 方向全空时至少置 `error`，避免调用方拿到一个「什么都没发生」
            // 的完成包后无限重挂。
            if (!r.any()) r.failed = true;
            // 就绪位经 `Ref.bytes` 回传，由 Loop 统一翻译（见 VTable 注释）。
            res = @intCast(r.bits());
        },
        .udp_send => {
            res = @bitCast(linux.sendto(
                p.fd,
                p.buf.ptr,
                p.buf.len,
                0,
                @ptrCast(@alignCast(p.hdr.ptr)),
                p.hdr_len,
            ));
        },
    }
    state.ref = .{
        .scratch = p.scratch,
        .bytes = if (res >= 0) @intCast(res) else 0,
        .failed = res < 0,
        .new_handle = if (p.kind == .accept and res >= 0) @intCast(res) else INVALID_HANDLE,
    };
    return state.ref;
}

fn vtNotify(userdata: ?*anyopaque) void {
    const state = stateOf(userdata);
    var one: u64 = 1;
    _ = linux.write(state.efd, std.mem.asBytes(&one), @sizeOf(u64));
}

const vtable_storage: io_mod.VTable = .{
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
    .sendFileTo = vtSendFileTo,
    .createUnix = vtCreateUnix,
    .bindUnix = vtBindUnix,
    .connectUnix = vtConnectUnix,
    .close = vtClose,
    .closeChecked = vtCloseChecked,
    .waitBatch = vtWaitBatch,
    .notify = vtNotify,
};

/// 无配置入口，保留给旧调用点。
pub fn create(alloc: std.mem.Allocator) !io_mod.Io {
    return createWith(alloc, .{});
}

/// 带配置的入口：`queue_size` 决定 fd-slot 表与完成包环形缓冲的**预分配**
/// 容量。这一步是「稳态 0 malloc」的关键——所有容器在启动时一次性备齐，
/// 之后 submit / reap / cancel 都只写已分配的内存。
pub fn createWith(alloc: std.mem.Allocator, opts: io_mod.Options) !io_mod.Io {
    return createBody(alloc, opts.queue_size);
}

fn createBody(alloc: std.mem.Allocator, queue_size: u16) !io_mod.Io {
    const cap: usize = @max(@as(usize, queue_size) * 4, MIN_SLOTS);
    const slots = try alloc.alloc(FdSlot, cap);
    @memset(slots, .{});
    errdefer alloc.free(slots);

    const queued = try alloc.alloc(types.Ref, cap);
    errdefer alloc.free(queued);

    // 在启动时就把 Pending 池备足：正常在飞窗口（queue_size × 4）内
    // submit 永不分配；超出时才指数扩容。
    const pool = try alloc.alloc(Pending, cap);
    errdefer alloc.free(pool);
    var i: usize = 0;
    while (i < cap - 1) : (i += 1) pool[i] = .{ .next = @intCast(i + 1) };
    pool[cap - 1] = .{ .next = NO_PENDING };

    const state = try alloc.create(State);
    errdefer alloc.destroy(state);

    const ep = try cvt(linux.epoll_create1(linux.EPOLL.CLOEXEC));
    const epfd: i32 = @intCast(ep);
    const efd_raw = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (signed(efd_raw) < 0) {
        _ = linux.close(epfd);
        return error.SetupFailed;
    }
    const efd: i32 = @intCast(efd_raw);

    // eventfd 常驻注册（level-triggered，不用 ONESHOT）：Work 池只管写计数。
    var ev = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .fd = efd },
    };
    if (signed(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, efd, &ev)) < 0) {
        _ = linux.close(efd);
        _ = linux.close(epfd);
        return error.SetupFailed;
    }

    state.* = .{
        .alloc = alloc,
        .ep = epfd,
        .efd = efd,
        .slots = slots,
        .pool = pool,
        .free_head = 0,
        .queued = queued,
    };
    return .{ .userdata = state, .vtable = &vtable_storage };
}
// ---- 与 uring.zig 共用的 POSIX 小工具 -------------------------------------

/// 把 `IpAddress` 编成 sockaddr 写进 `storage`，返回长度。
fn buildSockaddr(address: net.IpAddress, storage: *[128]u8) linux.socklen_t {
    switch (address) {
        .ip4 => |a| {
            const sa = linux.sockaddr.in{
                .port = std.mem.nativeToBig(u16, a.port),
                .addr = @bitCast(a.bytes),
            };
            @memcpy(storage[0..@sizeOf(linux.sockaddr.in)], std.mem.asBytes(&sa));
            return @sizeOf(linux.sockaddr.in);
        },
        .ip6 => |a| {
            const sa = linux.sockaddr.in6{
                .port = std.mem.nativeToBig(u16, a.port),
                .flowinfo = 0,
                .addr = a.bytes,
                .scope_id = 0,
            };
            @memcpy(storage[0..@sizeOf(linux.sockaddr.in6)], std.mem.asBytes(&sa));
            return @sizeOf(linux.sockaddr.in6);
        },
    }
}

fn setNonblock(fd: i32) void {
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    if (signed(flags) < 0) return;
    const nonblock: usize = 1 << @bitOffsetOf(linux.O, "NONBLOCK");
    _ = linux.fcntl(fd, linux.F.SETFL, flags | nonblock);
}

// ---- 测试（只在 Linux 目标编译；在 WSL 里真跑 epoll 路径） ----------------

test "epoll: 定时器经 waitBatch 触发" {
    var l = loop_mod.Loop.init(try create(std.testing.allocator));
    defer l.deinit();

    const Ctx = struct {
        var fired: usize = 0;
        fn cb(lp: *loop_mod.Loop, c: *completion.Completion) void {
            _ = c;
            fired += 1;
            lp.stop();
        }
    };
    var timer = completion.Timer.init(20);
    timer.c.callback = &Ctx.cb;
    l.add(&timer.c);
    try l.run();
    try std.testing.expectEqual(@as(usize, 1), Ctx.fired);
}

test "epoll: accept + recv + send 全链路" {
    var l = loop_mod.Loop.init(try create(std.testing.allocator));
    defer l.deinit();

    const bind_addr = try net.IpAddress.parse("127.0.0.1", 0);
    const listener = try uring.createTcpSocket(bind_addr);
    defer uring.closeSocket(listener);
    try uring.setReuseAddress(listener, true);
    try uring.bindSocket(listener, bind_addr);
    const bound = try uring.localAddress(listener);
    try uring.listenSocket(listener, 16);

    const accept_sock = try uring.createTcpSocket(bind_addr);

    const Client = struct {
        fn run(addr: net.IpAddress) void {
            const c = uring.createTcpSocket(addr) catch return;
            defer uring.closeSocket(c);
            uring.connectSocket(c, addr) catch return;
            _ = linux.write(fdOf(c), "hello", 5);
        }
    };
    const t = try std.Thread.spawn(.{}, Client.run, .{bound});
    defer t.join();

    const Ctx = struct {
        var accepted: Handle = INVALID_HANDLE;
        var got: usize = 0;
        var buf: [64]u8 = undefined;
        var recv: completion.NetRecv = undefined;

        fn onAccept(lp: *loop_mod.Loop, c: *completion.Completion) void {
            const a: *completion.NetAccept = @fieldParentPtr("c", c);
            accepted = a.getResult() catch {
                lp.stop();
                return;
            };
            recv = completion.NetRecv.init(accepted, &buf);
            recv.c.callback = &onRecv;
            lp.add(&recv.c);
        }
        fn onRecv(lp: *loop_mod.Loop, c: *completion.Completion) void {
            const r: *completion.NetRecv = @fieldParentPtr("c", c);
            got = r.getResult() catch 0;
            lp.stop();
        }
    };

    var acc = completion.NetAccept.init(listener, accept_sock);
    acc.c.callback = &Ctx.onAccept;
    l.add(&acc.c);
    try l.run();

    try std.testing.expectEqual(@as(usize, 5), Ctx.got);
    try std.testing.expectEqualStrings("hello", Ctx.buf[0..Ctx.got]);
    uring.closeSocket(Ctx.accepted);
}

test "epoll: Work 池任务经 eventfd 唤醒并完成回调" {
    var l = loop_mod.Loop.init(try create(std.testing.allocator));
    defer l.deinit();

    const Ctx = struct {
        var fired: usize = 0;
        fn onDone(lp: *loop_mod.Loop, c: *completion.Completion) void {
            const w: *completion.Work = @fieldParentPtr("c", c);
            _ = w;
            fired += 1;
            lp.stop();
        }
        fn run(w: *completion.Work) void {
            _ = w;
        }
    };
    var w: completion.Work = undefined;
    w = completion.Work.init(&Ctx.run);
    w.c.callback = &Ctx.onDone;
    l.add(&w.c);
    try l.run();
    try std.testing.expectEqual(@as(usize, 1), Ctx.fired);
}

test "epoll: 异步 connect 完成" {
    var l = loop_mod.Loop.init(try create(std.testing.allocator));
    defer l.deinit();

    const bind_addr = try net.IpAddress.parse("127.0.0.1", 0);
    const listener = try uring.createTcpSocket(bind_addr);
    defer uring.closeSocket(listener);
    try uring.setReuseAddress(listener, true);
    try uring.bindSocket(listener, bind_addr);
    const bound = try uring.localAddress(listener);
    try uring.listenSocket(listener, 16);

    const client = try uring.createTcpSocket(bind_addr);
    defer uring.closeSocket(client);

    const Ctx = struct {
        var ok: bool = false;
        fn onConnect(lp: *loop_mod.Loop, c: *completion.Completion) void {
            const cn: *completion.NetConnect = @fieldParentPtr("c", c);
            _ = cn.getResult() catch {
                lp.stop();
                return;
            };
            ok = true;
            lp.stop();
        }
    };
    var con = completion.NetConnect.init(client, bound);
    con.c.callback = &Ctx.onConnect;
    l.add(&con.c);
    try l.run();

    try std.testing.expect(Ctx.ok);
    const accepted = try uring.acceptSocket(listener);
    uring.closeSocket(accepted.socket);
}

test "epoll: 同一 fd 连续 recv，ONESHOT 重挂不丢事件" {
    var l = loop_mod.Loop.init(try create(std.testing.allocator));
    defer l.deinit();

    const bind_addr = try net.IpAddress.parse("127.0.0.1", 0);
    const listener = try uring.createTcpSocket(bind_addr);
    defer uring.closeSocket(listener);
    try uring.setReuseAddress(listener, true);
    try uring.bindSocket(listener, bind_addr);
    const bound = try uring.localAddress(listener);
    try uring.listenSocket(listener, 16);
    const accept_sock = try uring.createTcpSocket(bind_addr);

    const Client = struct {
        fn run(addr: net.IpAddress) void {
            const c = uring.createTcpSocket(addr) catch return;
            defer uring.closeSocket(c);
            uring.connectSocket(c, addr) catch return;
            _ = linux.write(fdOf(c), "one", 3);
            const pause = linux.timespec{ .sec = 0, .nsec = 30 * 1_000_000 };
            _ = linux.nanosleep(&pause, null);
            _ = linux.write(fdOf(c), "two", 3);
        }
    };
    const t = try std.Thread.spawn(.{}, Client.run, .{bound});
    defer t.join();

    const Ctx = struct {
        var accepted: Handle = INVALID_HANDLE;
        var total: usize = 0;
        var rounds: usize = 0;
        var buf: [8]u8 = undefined;
        var recv: completion.NetRecv = undefined;

        fn onAccept(lp: *loop_mod.Loop, c: *completion.Completion) void {
            const a: *completion.NetAccept = @fieldParentPtr("c", c);
            accepted = a.getResult() catch {
                lp.stop();
                return;
            };
            recv = completion.NetRecv.init(accepted, buf[total..]);
            recv.c.callback = &onRecv;
            lp.add(&recv.c);
        }
        fn onRecv(lp: *loop_mod.Loop, c: *completion.Completion) void {
            const r: *completion.NetRecv = @fieldParentPtr("c", c);
            total += r.getResult() catch 0;
            rounds += 1;
            if (rounds == 2) {
                lp.stop();
                return;
            }
            // 同一 fd 再提交一次 recv：epoll 必须用 CTL_MOD 重新武装。
            recv = completion.NetRecv.init(accepted, buf[total..]);
            recv.c.callback = &onRecv;
            lp.add(&recv.c);
        }
    };

    var acc = completion.NetAccept.init(listener, accept_sock);
    acc.c.callback = &Ctx.onAccept;
    l.add(&acc.c);
    try l.run();

    try std.testing.expectEqual(@as(usize, 2), Ctx.rounds);
    try std.testing.expectEqual(@as(usize, 6), Ctx.total);
    uring.closeSocket(Ctx.accepted);
}

test "epoll: WatchFd 监视管道可读" {
    var l = loop_mod.Loop.init(try create(std.testing.allocator));
    defer l.deinit();

    var fds: [2]i32 = undefined;
    const rc = linux.pipe2(&fds, .{ .CLOEXEC = true });
    try std.testing.expect(@as(isize, @bitCast(rc)) >= 0);
    defer _ = linux.close(@intCast(fds[0]));
    defer _ = linux.close(@intCast(fds[1]));

    const Ctx = struct {
        var done = false;
        var got: types.Ready = .{};
        fn cb(lp: *loop_mod.Loop, c: *completion.Completion) void {
            const w: *completion.WatchFd = @fieldParentPtr("c", c);
            got = w.ready;
            done = true;
            lp.stop();
        }
    };

    var w = completion.WatchFd.init(@intCast(fds[0]), .{ .read = true });
    var wd = completion.Timer.init(5000);
    w.c.callback = &Ctx.cb;
    l.add(&w.c);
    l.watchdog(&w.c, &wd, 5000);

    try std.testing.expectEqual(@as(isize, 1), @as(isize, @bitCast(linux.write(@intCast(fds[1]), "x", 1))));

    try l.run();
    try std.testing.expect(Ctx.done);
    try std.testing.expect(Ctx.got.read);
    try std.testing.expect(!Ctx.got.write);
}

// 全双工回归：同一 fd 上 recv + send 同时在飞。
//
// 旧实现把 `ep_ev.events` 整体替换成「本次提交的方向」，第二次 CTL_MOD
// 会抹掉第一次的 IN；加上 EPOLLONESHOT 是 per-fd，一次事件把两个方向
// 一起禁用后剩余方向也不会重挂 —— 读操作静默等不到回调（watchdog 超时）。
// 这里用 socketpair 构造「写方向立刻就绪、读方向稍后才到」的时序。
test "epoll: 同一 fd 全双工 recv+send 不丢方向" {
    var l = loop_mod.Loop.init(try create(std.testing.allocator));
    defer l.deinit();

    var pair: [2]i32 = undefined;
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &pair);
    try std.testing.expect(signed(rc) >= 0);
    defer _ = linux.close(pair[0]);
    defer _ = linux.close(pair[1]);

    const Ctx = struct {
        var recv_done = false;
        var send_done = false;
        var recv_buf: [8]u8 = undefined;
        var recv_node: completion.NetRecv = undefined;
        var send_node: completion.NetSend = undefined;
        var peer: i32 = 0;

        fn onRecv(lp: *loop_mod.Loop, c: *completion.Completion) void {
            const r: *completion.NetRecv = @fieldParentPtr("c", c);
            recv_done = r.c.err == null and r.c.bytes == 3;
            if (recv_done) tryStop(lp);
        }
        fn onSend(lp: *loop_mod.Loop, c: *completion.Completion) void {
            const s: *completion.NetSend = @fieldParentPtr("c", c);
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
    // 先提交 recv（读方向），再提交 send（写方向）：正是旧实现丢事件的顺序。
    Ctx.recv_node = completion.NetRecv.init(@intCast(pair[0]), &Ctx.recv_buf);
    Ctx.recv_node.c.callback = &Ctx.onRecv;
    Ctx.send_node = completion.NetSend.init(@intCast(pair[0]), "abc");
    Ctx.send_node.c.callback = &Ctx.onSend;
    l.add(&Ctx.recv_node.c);
    l.add(&Ctx.send_node.c);

    // 让读方向在写事件之后才就绪，逼出「ONESHOT 到点后必须重挂剩余方向」。
    const Writer = struct {
        fn run(fd: i32) void {
            const pause = linux.timespec{ .sec = 0, .nsec = 20 * 1_000_000 };
            _ = linux.nanosleep(&pause, null);
            _ = linux.write(fd, "xyz", 3);
        }
    };
    const t = try std.Thread.spawn(.{}, Writer.run, .{Ctx.peer});
    defer t.join();

    var wd = completion.Timer.init(1000);
    l.watchdog(&Ctx.recv_node.c, &wd, 1000);
    try l.run();
    try std.testing.expect(Ctx.send_done);
    try std.testing.expect(Ctx.recv_done);
    try std.testing.expectEqualStrings("xyz", Ctx.recv_buf[0..3]);
}

// 同 fd 同方向多个在飞操作（4 个 recv）：旧实现的「每方向单 slot」会直接
// 拒绝或覆盖；新实现的 FIFO 链必须让每一个都恰好回调一次。
test "epoll: 同一 fd 同方向多个 recv 依次完成" {
    var l = loop_mod.Loop.init(try create(std.testing.allocator));
    defer l.deinit();

    var pair: [2]i32 = undefined;
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &pair);
    try std.testing.expect(signed(rc) >= 0);
    defer _ = linux.close(pair[0]);
    defer _ = linux.close(pair[1]);

    const N = 4;
    const Ctx = struct {
        var done: usize = 0;
        var nodes: [N]completion.NetRecv = undefined;
        var bufs: [N][1]u8 = undefined;

        fn cb(lp: *loop_mod.Loop, c: *completion.Completion) void {
            const r: *completion.NetRecv = @fieldParentPtr("c", c);
            if (r.c.err == null and r.c.bytes == 1) done += 1;
            if (done == N) lp.stop();
        }
    };
    Ctx.done = 0;
    // 每个 recv 只给 1 字节缓冲：4 字节数据正好让 4 个在飞 recv 依次各拿 1 字节。
    for (0..N) |i| {
        Ctx.nodes[i] = completion.NetRecv.init(@intCast(pair[0]), &Ctx.bufs[i]);
        Ctx.nodes[i].c.callback = &Ctx.cb;
        l.add(&Ctx.nodes[i].c);
    }
    var payload: [N]u8 = .{ 'a', 'b', 'c', 'd' };
    _ = linux.write(pair[1], &payload, N);

    // 独立定时器收尾：若 FIFO 链漏掉某个节点，run() 不会永久挂住。
    const Guard = struct {
        fn cb(lp: *loop_mod.Loop, c: *completion.Completion) void {
            _ = c;
            lp.stop();
        }
    };
    var guard = completion.Timer.init(2000);
    guard.c.callback = &Guard.cb;
    l.add(&guard.c);

    try l.run();
    try std.testing.expectEqual(@as(usize, N), Ctx.done);
}

test "epoll: 双向 watch 取消后保留另一读操作，池格子不重复归还" {
    const io = try create(std.testing.allocator);
    defer io.vtable.deinit(io.userdata);
    var pair: [2]i32 = undefined;
    _ = try cvt(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &pair));
    defer _ = linux.close(pair[0]);
    defer _ = linux.close(pair[1]);
    var watch: types.Scratch = undefined;
    var recv: types.Scratch = undefined;
    var buf: [1]u8 = undefined;
    const fd: Handle = @intCast(pair[0]);
    _ = try vtWatchFd(io.userdata, fd, .{ .read = true, .write = true }, &watch);
    _ = try vtRecv(io.userdata, fd, &buf, &recv);
    vtCancel(io.userdata, fd, &watch);
    // 取消之后立即复用池，双重归还会让两个分配拿到同一格子。
    const state = stateOf(io.userdata);
    const first = try state.allocPending();
    const second = try state.allocPending();
    try std.testing.expect(first != second);
    state.freePending(first);
    state.freePending(second);
    var refs: [4]types.Ref = undefined;
    try std.testing.expectEqual(@as(usize, 1), try vtWaitBatch(io.userdata, 0, &refs));
    try std.testing.expect(refs[0].scratch == &watch);
    _ = try cvt(linux.write(pair[1], "x", 1));
    try std.testing.expectEqual(@as(usize, 1), try vtWaitBatch(io.userdata, 100, &refs));
    try std.testing.expect(refs[0].scratch == &recv);
    try std.testing.expect(!refs[0].failed);
    try std.testing.expectEqualStrings("x", &buf);
}

test "epoll: 关闭超过 64 个双向 watch 时每个操作只完成一次" {
    const io = try create(std.testing.allocator);
    defer io.vtable.deinit(io.userdata);
    var pair: [2]i32 = undefined;
    _ = try cvt(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &pair));
    defer _ = linux.close(pair[1]);
    var closed = false;
    defer if (!closed) {
        _ = linux.close(pair[0]);
    };
    var scratches: [80]types.Scratch = undefined;
    const fd: Handle = @intCast(pair[0]);
    for (&scratches) |*scratch| {
        _ = try vtWatchFd(io.userdata, fd, .{ .read = true, .write = true }, scratch);
    }
    try vtCloseChecked(io.userdata, fd);
    closed = true;
    var refs: [81]types.Ref = undefined;
    const count = try vtWaitBatch(io.userdata, 0, &refs);
    try std.testing.expectEqual(scratches.len, count);
    for (&scratches) |*scratch| {
        var matches: usize = 0;
        for (refs[0..count]) |ref| {
            if (ref.scratch == scratch) matches += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), matches);
    }
}
