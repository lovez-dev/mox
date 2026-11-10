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
const root = @import("../io.zig");
const net = std.Io.net;

const Handle = root.Handle;
const INVALID_HANDLE = root.INVALID_HANDLE;

const Kind = enum { recv, send, accept, connect, udp_recv, udp_send };

/// `EVFILT_USER` 唤醒源的 ident。固定值即可，只要不与真实 fd 冲突；
/// 真实 fd 从 3 起，用 1 是安全的。
const NOTIFY_IDENT = 1;

const Pending = struct {
    ident: usize,
    filter: i16,
    kind: Kind,
    scratch: *root.Scratch,
    buf: []u8 = &.{},
    /// `udp_recv` 的源地址缓冲：指向调用方节点，随节点一起存活。
    from: []u8 = &.{},
    /// `udp_send` 的 sockaddr 存储：编在调用方节点的 `hdr` 里，这里只留指针和长度。
    hdr: []usize = &.{},
    hdr_len: c.socklen_t = 0,
};

const State = struct {
    alloc: std.mem.Allocator,
    kq: i32,
    pending: std.ArrayListUnmanaged(Pending) = .empty,
    events: std.ArrayListUnmanaged(c.Kevent) = .empty,
    /// 被取消的操作：立即合成一个完成包，让循环能回收节点。
    cancelled: std.ArrayListUnmanaged(root.Ref) = .empty,
    ref: root.Ref = undefined,
};

fn stateOf(userdata: ?*anyopaque) *State {
    return @ptrCast(@alignCast(userdata.?));
}

fn fdOf(h: Handle) c.fd_t {
    return @intCast(h);
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
    state.pending.deinit(alloc);
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

fn vtRecv(userdata: ?*anyopaque, socket: Handle, buffer: []u8, scratch: *root.Scratch) anyerror!?usize {
    const state = stateOf(userdata);
    try state.pending.append(state.alloc, .{
        .ident = socket,
        .filter = c.EVFILT.READ,
        .kind = .recv,
        .scratch = scratch,
        .buf = buffer,
    });
    try evAdd(state, socket, c.EVFILT.READ, c.EV.ONESHOT);
    return null;
}

fn vtSend(userdata: ?*anyopaque, socket: Handle, bytes: []const u8, scratch: *root.Scratch) anyerror!?usize {
    const state = stateOf(userdata);
    // send() 需要非 const 缓冲区；循环保证这些字节在操作期间存活。
    try state.pending.append(state.alloc, .{
        .ident = socket,
        .filter = c.EVFILT.WRITE,
        .kind = .send,
        .scratch = scratch,
        .buf = @constCast(bytes),
    });
    try evAdd(state, socket, c.EVFILT.WRITE, c.EV.ONESHOT);
    return null;
}

fn vtClose(userdata: ?*anyopaque, socket: Handle) void {
    _ = userdata;
    _ = c.close(fdOf(socket));
}

/// 取消：按 `scratch` 找到待办，撤销已注册的 oneshot 事件，
/// 并合成一个失败完成包，保证循环一定能回收该节点。
fn vtCancel(userdata: ?*anyopaque, socket: root.Handle, scratch: *root.Scratch) void {
    _ = socket;
    const state = stateOf(userdata);
    var i: usize = 0;
    while (i < state.pending.items.len) : (i += 1) {
        const p = state.pending.items[i];
        if (p.scratch != scratch) continue;
        _ = state.pending.orderedRemove(i);
        evDelete(state, p.ident, p.filter);
        state.cancelled.append(state.alloc, .{
            .scratch = scratch,
            .bytes = 0,
            .failed = true,
            .new_handle = root.INVALID_HANDLE,
        }) catch {};
        return;
    }
}

fn vtAccept(userdata: ?*anyopaque, listen: Handle, accept_socket: Handle, addr_buf: []u8, scratch: *root.Scratch) anyerror!?usize {
    const state = stateOf(userdata);
    _ = c.close(fdOf(accept_socket)); // kernel allocates the fd for us
    try state.pending.append(state.alloc, .{
        .ident = listen,
        .filter = c.EVFILT.READ,
        .kind = .accept,
        .scratch = scratch,
        .buf = addr_buf,
    });
    try evAdd(state, listen, c.EVFILT.READ, c.EV.ONESHOT);
    return null;
}

fn vtUpdateAccept(userdata: ?*anyopaque, listen: Handle, accept_socket: Handle) void {
    _ = userdata;
    _ = listen;
    _ = accept_socket;
}

fn vtConnect(userdata: ?*anyopaque, socket: Handle, address: net.IpAddress, scratch: *root.Scratch) anyerror!void {
    const state = stateOf(userdata);
    var storage: [128]u8 = undefined;
    const len = buildSockaddr(address, &storage);
    _ = c.connect(fdOf(socket), @ptrCast(@alignCast(&storage)), len); // EINPROGRESS expected
    try state.pending.append(state.alloc, .{
        .ident = socket,
        .filter = c.EVFILT.WRITE,
        .kind = .connect,
        .scratch = scratch,
    });
    try evAdd(state, socket, c.EVFILT.WRITE, c.EV.ONESHOT);
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
    scratch: *root.Scratch,
) anyerror!void {
    _ = hdr;
    const state = stateOf(userdata);
    try state.pending.append(state.alloc, .{
        .ident = socket,
        .filter = c.EVFILT.READ,
        .kind = .udp_recv,
        .scratch = scratch,
        .buf = buf,
        .from = from,
    });
    try evAdd(state, socket, c.EVFILT.READ, c.EV.ONESHOT);
}

/// UDP 数据报发送：`sendto` 的 sockaddr 必须活到事件被处理，所以编进调用方
/// 节点自带的 `hdr`（后端私有存储）而不是栈上临时量。
fn vtUdpSend(
    userdata: ?*anyopaque,
    socket: Handle,
    buf: []const u8,
    to: net.IpAddress,
    hdr: []usize,
    scratch: *root.Scratch,
) anyerror!void {
    const state = stateOf(userdata);
    if (hdr.len * @sizeOf(usize) < 128) return error.BufferTooSmall;
    const store: *[128]u8 = @ptrCast(@alignCast(hdr.ptr));
    const len = buildSockaddr(to, store);
    try state.pending.append(state.alloc, .{
        .ident = socket,
        .filter = c.EVFILT.WRITE,
        .kind = .udp_send,
        .scratch = scratch,
        .buf = @constCast(buf),
        .hdr = hdr,
        .hdr_len = len,
    });
    try evAdd(state, socket, c.EVFILT.WRITE, c.EV.ONESHOT);
}

/// 一次 `kevent` 收集最多 64 个事件，逐个转成完成包后批量返回。
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

fn complete(state: *State, ev: c.Kevent) ?root.Ref {
    var i: usize = 0;
    while (i < state.pending.items.len) : (i += 1) {
        const p = state.pending.items[i];
        if (p.ident != ev.ident or p.filter != ev.filter) continue;
        _ = state.pending.orderedRemove(i);
        return finishOne(state, p);
    }
    return null;
}

fn finishOne(state: *State, p: Pending) root.Ref {
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
        .new_handle = if (p.kind == .accept and res >= 0) @intCast(res) else root.INVALID_HANDLE,
    };
    return state.ref;
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

fn vtCreateSocket(userdata: ?*anyopaque, address: net.IpAddress) anyerror!root.Handle {
    _ = userdata;
    return try createTcpSocket(address);
}

fn vtSetReuseAddress(userdata: ?*anyopaque, socket: root.Handle, on: bool) anyerror!void {
    _ = userdata;
    try setReuseAddress(socket, on);
}

fn vtSetSockOpt(userdata: ?*anyopaque, socket: root.Handle, opt: root.SockOpt, value: u32) anyerror!void {
    _ = userdata;
    try setSockOpt(socket, opt, value);
}

fn vtShutdownSend(userdata: ?*anyopaque, socket: root.Handle) anyerror!void {
    _ = userdata;
    try shutdownSend(socket);
}

fn vtBind(userdata: ?*anyopaque, socket: root.Handle, address: net.IpAddress) anyerror!void {
    _ = userdata;
    try bindSocket(socket, address);
}

fn vtListen(userdata: ?*anyopaque, socket: root.Handle, backlog: c_int) anyerror!void {
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

const vtable_storage: root.VTable = .{
    .deinit = vtDeinit,
    .now = vtNow,
    .createSocket = vtCreateSocket,
    .setReuseAddress = vtSetReuseAddress,
    .setSockOpt = vtSetSockOpt,
    .shutdownSend = vtShutdownSend,
    .bind = vtBind,
    .listen = vtListen,
    .fileSize = vtFileSize,
    .readFileInto = vtReadFileInto,
    .writeFileAll = vtWriteFileAll,
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
    .close = vtClose,
    .waitBatch = vtWaitBatch,
    .notify = vtNotify,
};

pub fn create(alloc: std.mem.Allocator) !root.Io {
    const state = try alloc.create(State);
    errdefer alloc.destroy(state);
    const kq = c.kqueue();
    if (kq < 0) return error.KqueueFailed;
    state.* = .{ .alloc = alloc, .kq = kq };
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
    if (c.kevent(kq, &reg, 1, undefined, 0, null) < 0) return error.KqueueFailed;
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
pub fn setSockOpt(h: Handle, opt: root.SockOpt, value: u32) !void {
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

pub fn deleteFile(path: []const u8) void {
    var zbuf: [1024]u8 = undefined;
    const z = zpath(path, &zbuf) catch return;
    _ = c.unlink(z.ptr);
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
