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
const root = @import("../io.zig");
const uring = @import("uring.zig");
const net = std.Io.net;

const Handle = root.Handle;
const INVALID_HANDLE = root.INVALID_HANDLE;

/// `epoll_wait` 一次最多取回的事件数；与 `Loop` 的 batch 上限无关，
/// 未取完的留在 `state.events` 里，下一次 `waitBatch` 优先消费。
const MAX_EVENTS = 64;

const Kind = enum { recv, send, accept, connect, udp_recv, udp_send, watch, recvmsg, sendmsg };

const Pending = struct {
    fd: i32,
    /// 关注方向：`EPOLL.IN` 或 `EPOLL.OUT`。
    events: u32,
    kind: Kind,
    scratch: *root.Scratch,
    buf: []u8 = &.{},
    /// `udp_recv` 的源地址缓冲，指向调用方节点，随节点一起存活。
    from: []u8 = &.{},
    /// `udp_send` 的 sockaddr 存储：编在调用方节点的 `hdr` 里。
    hdr: []usize = &.{},
    hdr_len: linux.socklen_t = 0,
    /// `recvmsg`/`sendmsg` 的 iovec 来源：指向调用方节点的 bufs 切片。
    msg_bufs: ?[]const []const u8 = null,
};

const State = struct {
    alloc: std.mem.Allocator,
    ep: i32,
    efd: i32,
    pending: std.ArrayListUnmanaged(Pending) = .empty,
    events: std.ArrayListUnmanaged(linux.epoll_event) = .empty,
    /// 被取消的操作：立即合成一个失败完成包，保证循环能回收节点。
    cancelled: std.ArrayListUnmanaged(root.Ref) = .empty,
    ref: root.Ref = undefined,
};

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
    if (signed(rc) < 0) return error.SyscallFailed;
    return rc;
}

// ---- epoll 注册 ------------------------------------------------------------

/// 只有真正注册进 epoll 的 fd 才设 `O_NONBLOCK`：`finishOne` 在就绪后
/// 就地执行系统调用，不能让它们把循环线程卡住。同步辅助函数
/// （`acceptSocket` / `connectSocket` / `sendBlocking` ...）不经过这里，
/// 保持阻塞语义，与 io_uring / kqueue / IOCP 三个后端一致。
///
/// `data` 存 fd 而非 scratch：`vtCancel` 按 scratch 找 pending，就绪事件
/// 按 fd + 方向找 pending，两条路径互不依赖 data 的载荷。同一 fd 上若已有
/// 别的方向注册，`CTL_ADD` 返回 EEXIST，此时改用 `CTL_MOD` 重新武装
/// （ONESHOT 触发后必须显式重挂）。
fn arm(state: *State, fd: i32, events: u32) !void {
    setNonblock(fd);
    var ep_ev = linux.epoll_event{
        .events = events | linux.EPOLL.ONESHOT,
        .data = .{ .fd = fd },
    };
    const rc = linux.epoll_ctl(state.ep, linux.EPOLL.CTL_ADD, fd, &ep_ev);
    if (signed(rc) >= 0) return;
    _ = try cvt(linux.epoll_ctl(state.ep, linux.EPOLL.CTL_MOD, fd, &ep_ev));
}

fn evDelete(state: *State, fd: i32) void {
    _ = linux.epoll_ctl(state.ep, linux.EPOLL.CTL_DEL, fd, null);
}

// ---- VTable 接线 ------------------------------------------------------------

fn vtDeinit(userdata: ?*anyopaque) void {
    const state = stateOf(userdata);
    const alloc = state.alloc;
    state.pending.deinit(alloc);
    state.events.deinit(alloc);
    state.cancelled.deinit(alloc);
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

fn vtSetSockOpt(userdata: ?*anyopaque, socket: Handle, opt: root.SockOpt, value: u32) anyerror!void {
    _ = userdata;
    return uring.setSockOpt(socket, opt, value);
}

fn vtShutdownSend(userdata: ?*anyopaque, socket: Handle) anyerror!void {
    _ = userdata;
    return uring.shutdownSend(socket);
}

fn vtShutdown(userdata: ?*anyopaque, socket: Handle, how: root.ShutdownHow) anyerror!void {
    _ = userdata;
    return uring.shutdownSocket(socket, how);
}

fn vtSendMsg(
    userdata: ?*anyopaque,
    socket: Handle,
    bufs: []const []const u8,
    hdr: []usize,
    scratch: *root.Scratch,
) anyerror!void {
    _ = hdr;
    // **不能同步 sendmsg**：socket 写不进去时会把整个循环线程卡住。
    // 正确做法与 `vtSend` 一致：等 EPOLLOUT，就绪后在 reap 里做那一次
    // 系统调用。
    const state = stateOf(userdata);
    const fd = fdOf(socket);
    try state.pending.append(state.alloc, .{
        .fd = fd,
        .events = linux.EPOLL.OUT,
        .kind = .sendmsg,
        .scratch = scratch,
        .msg_bufs = bufs,
    });
    try arm(state, fd, linux.EPOLL.OUT);
}

fn vtRecvMsg(
    userdata: ?*anyopaque,
    socket: Handle,
    bufs: []const []u8,
    hdr: []usize,
    scratch: *root.Scratch,
) anyerror!void {
    _ = hdr;
    // 理由同 `vtSendMsg`：绝不能同步 recvmsg。
    const state = stateOf(userdata);
    const fd = fdOf(socket);
    try state.pending.append(state.alloc, .{
        .fd = fd,
        .events = linux.EPOLL.IN,
        .kind = .recvmsg,
        .scratch = scratch,
        .msg_bufs = @ptrCast(bufs),
    });
    try arm(state, fd, linux.EPOLL.IN);
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

fn vtStatPath(userdata: ?*anyopaque, path: []const u8) anyerror!root.Stat {
    _ = userdata;
    const st = try uring.stat(path);
    return .{ .kind = @fromBackingInt(@intCast(@backingInt(st.kind))), .size = st.size, .mtime_ms = st.mtime_ms };
}

fn vtListDir(userdata: ?*anyopaque, path: []const u8, buf: []root.DirEntry) anyerror!usize {
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
fn vtOpenFile(userdata: ?*anyopaque, path: []const u8, mode: root.FileMode) anyerror!root.Handle {
    _ = userdata;
    return uring.openFile(path, mode);
}

fn vtReadFileHandle(userdata: ?*anyopaque, file: root.Handle, offset: u64, buf: []u8) anyerror!usize {
    _ = userdata;
    return uring.readFileHandle(file, offset, buf);
}

fn vtWriteFileHandle(userdata: ?*anyopaque, file: root.Handle, offset: u64, bytes: []const u8) anyerror!usize {
    _ = userdata;
    return uring.writeFileHandle(file, offset, bytes);
}

fn vtCloseFile(userdata: ?*anyopaque, file: root.Handle) void {
    _ = userdata;
    uring.closeFile(file);
}

// 句柄级元数据与同步：与 uring 后端共用同一套 syscall 实现。
fn vtStatFile(userdata: ?*anyopaque, file: root.Handle) anyerror!root.Stat {
    _ = userdata;
    const st = try uring.statFile(file);
    return .{ .kind = @fromBackingInt(@intCast(@backingInt(st.kind))), .size = st.size, .mtime_ms = st.mtime_ms };
}

fn vtSetFileSize(userdata: ?*anyopaque, file: root.Handle, size: u64) anyerror!void {
    _ = userdata;
    return uring.setFileSize(file, size);
}

fn vtSyncFile(userdata: ?*anyopaque, file: root.Handle) anyerror!void {
    _ = userdata;
    return uring.syncFile(file);
}

// 阶段 F：与 uring 后端共用同一套实现（同属 Linux）。
fn vtSetFilePermissions(userdata: ?*anyopaque, file: root.Handle, mode: u32) anyerror!void {
    _ = userdata;
    return uring.setFilePermissions(file, mode);
}

fn vtSetFileOwner(userdata: ?*anyopaque, file: root.Handle, uid: u32, gid: u32) anyerror!void {
    _ = userdata;
    return uring.setFileOwner(file, uid, gid);
}

fn vtSetFileTimestamps(userdata: ?*anyopaque, file: root.Handle, atime_ns: i64, mtime_ns: i64) anyerror!void {
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

fn vtOpenDir(userdata: ?*anyopaque, path: []const u8) anyerror!root.Handle {
    _ = userdata;
    return uring.openDir(path);
}

fn vtReadDirHandle(userdata: ?*anyopaque, dir: root.Handle, buf: []root.DirEntry) anyerror!usize {
    _ = userdata;
    return uring.readDirHandle(dir, buf);
}

fn vtCloseDir(userdata: ?*anyopaque, dir: root.Handle) void {
    _ = userdata;
    uring.closeDir(dir);
}

fn vtDeleteFile(userdata: ?*anyopaque, path: []const u8) anyerror!void {
    _ = userdata;
    uring.deleteFile(path);
}

fn vtAssociate(userdata: ?*anyopaque, socket: Handle, key: usize) anyerror!void {
    _ = userdata;
    _ = socket;
    _ = key;
}

fn vtSendFileTo(userdata: ?*anyopaque, socket: root.Handle, path: []const u8, offset: u64, count: usize) anyerror!usize {
    _ = userdata;
    return uring.vtSendFileTo(null, socket, path, offset, count);
}

fn vtCreateUnix(userdata: ?*anyopaque) anyerror!root.Handle {
    _ = userdata;
    return uring.vtCreateUnix(null);
}

fn vtBindUnix(userdata: ?*anyopaque, socket: root.Handle, path: []const u8) anyerror!void {
    _ = userdata;
    return uring.vtBindUnix(null, socket, path);
}

/// epoll 是就绪模型，没有「异步 connect」：非阻塞 `connect` 返回 EINPROGRESS
/// 后要等 `EPOLL.OUT`，由调用方通过 `WatchFd` 或 `NetConnect` 语义处理。
/// 这里直接做非阻塞 connect，立即连上（本机 UDS 常见）就返回，否则返回 null。
fn vtConnectUnix(userdata: ?*anyopaque, socket: root.Handle, path: []const u8, scratch: *root.Scratch) anyerror!?void {
    _ = userdata;
    var sa: linux.sockaddr.un = undefined;
    const len = try uring.buildUnixSockaddrPub(path, &sa);
    if (len > @sizeOf(root.Scratch)) return error.NameTooLong;
    @memcpy(std.mem.asBytes(scratch)[0..len], std.mem.asBytes(&sa)[0..len]);
    const rc = linux.connect(fdOf(socket), @ptrCast(@alignCast(scratch)), len);
    const rc_s = signed(rc);
    if (rc_s == 0) return {};
    if (rc_s == -@as(isize, @backingInt(linux.E.INPROGRESS))) return null;
    return error.ConnectFailed;
}

fn vtWatchFd(userdata: ?*anyopaque, fd: Handle, want: root.Ready, scratch: *root.Scratch) anyerror!?void {
    const state = stateOf(userdata);
    const raw = fdOf(fd);
    var events: u32 = 0;
    if (want.read) events |= linux.EPOLL.IN;
    if (want.write) events |= linux.EPOLL.OUT;
    if (events == 0) return error.NothingToWatch;
    try state.pending.append(state.alloc, .{
        .fd = raw,
        .events = events,
        // ONESHOT 由 `arm` 统一加；这里关心 ERR/HUP 也会被 `complete` 接受。
        .kind = .watch,
        .scratch = scratch,
    });
    try arm(state, raw, events);
    return null;
}

fn vtRecv(userdata: ?*anyopaque, socket: Handle, buffer: []u8, scratch: *root.Scratch) anyerror!?usize {
    const state = stateOf(userdata);
    const fd = fdOf(socket);
    try state.pending.append(state.alloc, .{
        .fd = fd,
        .events = linux.EPOLL.IN,
        .kind = .recv,
        .scratch = scratch,
        .buf = buffer,
    });
    try arm(state, fd, linux.EPOLL.IN);
    return null;
}

fn vtSend(userdata: ?*anyopaque, socket: Handle, bytes: []const u8, scratch: *root.Scratch) anyerror!?usize {
    const state = stateOf(userdata);
    const fd = fdOf(socket);
    // send() 需要非 const 缓冲区；循环保证这些字节在操作期间存活。
    try state.pending.append(state.alloc, .{
        .fd = fd,
        .events = linux.EPOLL.OUT,
        .kind = .send,
        .scratch = scratch,
        .buf = @constCast(bytes),
    });
    try arm(state, fd, linux.EPOLL.OUT);
    return null;
}

fn vtClose(userdata: ?*anyopaque, socket: Handle) void {
    const state = stateOf(userdata);
    evDelete(state, fdOf(socket));
    _ = linux.close(fdOf(socket));
}

/// 取消：按 `scratch` 找到待办，撤销注册，并合成一个失败完成包，
/// 保证循环一定能回收该节点。
fn vtCancel(userdata: ?*anyopaque, socket: Handle, scratch: *root.Scratch) void {
    _ = socket;
    const state = stateOf(userdata);
    var i: usize = 0;
    while (i < state.pending.items.len) : (i += 1) {
        const p = state.pending.items[i];
        if (p.scratch != scratch) continue;
        _ = state.pending.orderedRemove(i);
        evDelete(state, p.fd);
        state.cancelled.append(state.alloc, .{
            .scratch = scratch,
            .bytes = 0,
            .failed = true,
            .new_handle = INVALID_HANDLE,
        }) catch {};
        return;
    }
}

fn vtAccept(userdata: ?*anyopaque, listen: Handle, accept_socket: Handle, addr_buf: []u8, scratch: *root.Scratch) anyerror!?usize {
    const state = stateOf(userdata);
    const fd = fdOf(listen);
    // 新 fd 由内核分配；预先建好的 socket 属于 AcceptEx 习惯，这里不用。
    _ = linux.close(fdOf(accept_socket));
    try state.pending.append(state.alloc, .{
        .fd = fd,
        .events = linux.EPOLL.IN,
        .kind = .accept,
        .scratch = scratch,
        .buf = addr_buf,
    });
    try arm(state, fd, linux.EPOLL.IN);
    return null;
}

fn vtUpdateAccept(userdata: ?*anyopaque, listen: Handle, accept_socket: Handle) void {
    _ = userdata;
    _ = listen;
    _ = accept_socket;
}

fn vtConnect(userdata: ?*anyopaque, socket: Handle, address: net.IpAddress, scratch: *root.Scratch) anyerror!void {
    const state = stateOf(userdata);
    const fd = fdOf(socket);
    var storage: [128]u8 = undefined;
    const len = buildSockaddr(address, &storage);
    // 非阻塞连接预期返回 EINPROGRESS；就绪后用 SO_ERROR 取结果。
    _ = linux.connect(fd, @ptrCast(@alignCast(&storage)), len);
    try state.pending.append(state.alloc, .{
        .fd = fd,
        .events = linux.EPOLL.OUT,
        .kind = .connect,
        .scratch = scratch,
    });
    try arm(state, fd, linux.EPOLL.OUT);
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
    scratch: *root.Scratch,
) anyerror!void {
    _ = hdr;
    const state = stateOf(userdata);
    const fd = fdOf(socket);
    try state.pending.append(state.alloc, .{
        .fd = fd,
        .events = linux.EPOLL.IN,
        .kind = .udp_recv,
        .scratch = scratch,
        .buf = buf,
        .from = from,
    });
    try arm(state, fd, linux.EPOLL.IN);
}

fn vtUdpSend(
    userdata: ?*anyopaque,
    socket: Handle,
    buf: []const u8,
    to: net.IpAddress,
    hdr: []usize,
    scratch: *root.Scratch,
) anyerror!void {
    const state = stateOf(userdata);
    const fd = fdOf(socket);
    const len = buildSockaddr(to, @ptrCast(@alignCast(hdr.ptr)));
    try state.pending.append(state.alloc, .{
        .fd = fd,
        .events = linux.EPOLL.OUT,
        .kind = .udp_send,
        .scratch = scratch,
        .buf = @constCast(buf),
        .hdr = hdr,
        .hdr_len = len,
    });
    try arm(state, fd, linux.EPOLL.OUT);
}

fn vtWaitBatch(userdata: ?*anyopaque, timeout_ms: u32, refs: []root.Ref) anyerror!usize {
    const state = stateOf(userdata);
    var n: usize = 0;

    // 取消产生的合成完成包优先返回。
    while (n < refs.len and state.cancelled.items.len != 0) {
        refs[n] = state.cancelled.orderedRemove(0);
        n += 1;
    }
    if (n != 0) return n;

    if (state.events.items.len == 0) {
        const wait_forever = timeout_ms >= std.math.maxInt(u32) / 2;
        const pt: i32 = if (wait_forever) -1 else @intCast(timeout_ms);
        var batch: [MAX_EVENTS]linux.epoll_event = undefined;
        const got = linux.epoll_wait(state.ep, &batch, batch.len, pt);
        if (signed(got) < 0) return 0;
        try state.events.appendSlice(state.alloc, batch[0..@intCast(got)]);
    }
    while (n < refs.len and state.events.items.len != 0) {
        const ev = state.events.orderedRemove(0);
        if (ev.data.fd == state.efd) {
            // Work 唤醒：读掉计数，让循环去 drainWork。
            var buf: [8]u8 = undefined;
            _ = linux.read(state.efd, &buf, buf.len);
            continue;
        }
        if (complete(state, ev)) |r| {
            refs[n] = r;
            n += 1;
        }
    }
    return n;
}

/// 按 (fd, 方向) 找到待办并就地完成。
fn complete(state: *State, ev: linux.epoll_event) ?root.Ref {
    const fd = ev.data.fd;
    var i: usize = 0;
    while (i < state.pending.items.len) : (i += 1) {
        const p = state.pending.items[i];
        if (p.fd != fd) continue;
        // 只消费与就绪方向匹配的待办；方向不符的留给后续事件。
        if (ev.events & p.events == 0 and ev.events & (linux.EPOLL.ERR | linux.EPOLL.HUP) == 0) continue;
        _ = state.pending.orderedRemove(i);
        return finishOne(state, p, ev.events);
    }
    return null;
}

fn finishOne(state: *State, p: Pending, ev_events: u32) root.Ref {
    var res: isize = 0;
    switch (p.kind) {
        // std 的 linux 层没有裸 recv/send；用 recvfrom/sendto 配空地址等价实现。
        .recv => res = @bitCast(linux.recvfrom(p.fd, p.buf.ptr, p.buf.len, 0, null, null)),
        .send => res = @bitCast(linux.sendto(p.fd, p.buf.ptr, p.buf.len, 0, null, 0)),
        .accept => res = @bitCast(linux.accept(p.fd, null, null)),
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
            res = @intCast(linux.sendmsg(p.fd, &msg, linux.MSG.NOSIGNAL));
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
            res = @intCast(linux.recvmsg(p.fd, &msg, 0));
        },
        .watch => {
            // 不代收数据，只把内核给的方向位翻成 `Ready` 回填给调用方。
            var r: root.Ready = .{};
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

const vtable_storage: root.VTable = .{
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
    .waitBatch = vtWaitBatch,
    .notify = vtNotify,
};

/// 无配置入口，保留给旧调用点。
pub fn create(alloc: std.mem.Allocator) !root.Io {
    return createWith(alloc, .{});
}

/// 带配置的入口。当前这些后端不按 `queue_size` 缩放内部批量数组
/// （epoll / kqueue 的就绪数组和 IOCP 的 OVERLAPPED_ENTRY 数组仍是编译期
/// 定长），所以这里只接住参数、不改动行为。`Options` 的其余字段由 Loop
/// 层消费。将来要缩放时在这个函数里改即可，上层不用动。
pub fn createWith(alloc: std.mem.Allocator, opts: root.Options) !root.Io {
    _ = opts;
    return createBody(alloc);
}

fn createBody(alloc: std.mem.Allocator) !root.Io {
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

    state.* = .{ .alloc = alloc, .ep = epfd, .efd = efd };
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
    var l = root.Loop.init(try create(std.testing.allocator));
    defer l.deinit();

    const Ctx = struct {
        var fired: usize = 0;
        fn cb(lp: *root.Loop, c: *root.Completion) void {
            _ = c;
            fired += 1;
            lp.stop();
        }
    };
    var timer = root.Timer.init(20);
    timer.c.callback = &Ctx.cb;
    l.add(&timer.c);
    try l.run();
    try std.testing.expectEqual(@as(usize, 1), Ctx.fired);
}

test "epoll: accept + recv + send 全链路" {
    var l = root.Loop.init(try create(std.testing.allocator));
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
        var recv: root.NetRecv = undefined;

        fn onAccept(lp: *root.Loop, c: *root.Completion) void {
            const a: *root.NetAccept = @fieldParentPtr("c", c);
            accepted = a.getResult() catch {
                lp.stop();
                return;
            };
            recv = root.NetRecv.init(accepted, &buf);
            recv.c.callback = &onRecv;
            lp.add(&recv.c);
        }
        fn onRecv(lp: *root.Loop, c: *root.Completion) void {
            const r: *root.NetRecv = @fieldParentPtr("c", c);
            got = r.getResult() catch 0;
            lp.stop();
        }
    };

    var acc = root.NetAccept.init(listener, accept_sock);
    acc.c.callback = &Ctx.onAccept;
    l.add(&acc.c);
    try l.run();

    try std.testing.expectEqual(@as(usize, 5), Ctx.got);
    try std.testing.expectEqualStrings("hello", Ctx.buf[0..Ctx.got]);
    uring.closeSocket(Ctx.accepted);
}

test "epoll: Work 池任务经 eventfd 唤醒并完成回调" {
    var l = root.Loop.init(try create(std.testing.allocator));
    defer l.deinit();

    const Ctx = struct {
        var fired: usize = 0;
        fn onDone(lp: *root.Loop, c: *root.Completion) void {
            const w: *root.Work = @fieldParentPtr("c", c);
            _ = w;
            fired += 1;
            lp.stop();
        }
        fn run(w: *root.Work) void {
            _ = w;
        }
    };
    var w: root.Work = undefined;
    w = root.Work.init(&Ctx.run);
    w.c.callback = &Ctx.onDone;
    l.add(&w.c);
    try l.run();
    try std.testing.expectEqual(@as(usize, 1), Ctx.fired);
}

test "epoll: 异步 connect 完成" {
    var l = root.Loop.init(try create(std.testing.allocator));
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
        fn onConnect(lp: *root.Loop, c: *root.Completion) void {
            const cn: *root.NetConnect = @fieldParentPtr("c", c);
            _ = cn.getResult() catch {
                lp.stop();
                return;
            };
            ok = true;
            lp.stop();
        }
    };
    var con = root.NetConnect.init(client, bound);
    con.c.callback = &Ctx.onConnect;
    l.add(&con.c);
    try l.run();

    try std.testing.expect(Ctx.ok);
    const accepted = try uring.acceptSocket(listener);
    uring.closeSocket(accepted.socket);
}

test "epoll: 同一 fd 连续 recv，ONESHOT 重挂不丢事件" {
    var l = root.Loop.init(try create(std.testing.allocator));
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
        var recv: root.NetRecv = undefined;

        fn onAccept(lp: *root.Loop, c: *root.Completion) void {
            const a: *root.NetAccept = @fieldParentPtr("c", c);
            accepted = a.getResult() catch {
                lp.stop();
                return;
            };
            recv = root.NetRecv.init(accepted, buf[total..]);
            recv.c.callback = &onRecv;
            lp.add(&recv.c);
        }
        fn onRecv(lp: *root.Loop, c: *root.Completion) void {
            const r: *root.NetRecv = @fieldParentPtr("c", c);
            total += r.getResult() catch 0;
            rounds += 1;
            if (rounds == 2) {
                lp.stop();
                return;
            }
            // 同一 fd 再提交一次 recv：epoll 必须用 CTL_MOD 重新武装。
            recv = root.NetRecv.init(accepted, buf[total..]);
            recv.c.callback = &onRecv;
            lp.add(&recv.c);
        }
    };

    var acc = root.NetAccept.init(listener, accept_sock);
    acc.c.callback = &Ctx.onAccept;
    l.add(&acc.c);
    try l.run();

    try std.testing.expectEqual(@as(usize, 2), Ctx.rounds);
    try std.testing.expectEqual(@as(usize, 6), Ctx.total);
    uring.closeSocket(Ctx.accepted);
}

test "epoll: WatchFd 监视管道可读" {
    var l = root.Loop.init(try create(std.testing.allocator));
    defer l.deinit();

    var fds: [2]i32 = undefined;
    const rc = linux.pipe2(&fds, .{ .CLOEXEC = true });
    try std.testing.expect(@as(isize, @bitCast(rc)) >= 0);
    defer _ = linux.close(@intCast(fds[0]));
    defer _ = linux.close(@intCast(fds[1]));

    const Ctx = struct {
        var done = false;
        var got: root.Ready = .{};
        fn cb(lp: *root.Loop, c: *root.Completion) void {
            const w: *root.WatchFd = @fieldParentPtr("c", c);
            got = w.ready;
            done = true;
            lp.stop();
        }
    };

    var w = root.WatchFd.init(@intCast(fds[0]), .{ .read = true });
    var wd = root.Timer.init(5000);
    w.c.callback = &Ctx.cb;
    l.add(&w.c);
    l.watchdog(&w.c, &wd, 5000);

    try std.testing.expectEqual(@as(isize, 1), @as(isize, @bitCast(linux.write(@intCast(fds[1]), "x", 1))));

    try l.run();
    try std.testing.expect(Ctx.done);
    try std.testing.expect(Ctx.got.read);
    try std.testing.expect(!Ctx.got.write);
}
