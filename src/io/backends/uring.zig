//! `mox_io` 的 Linux `io_uring` 后端。
//!
//! 全手写：环本身（SQ/CQ 共享内存环、SQE 准备、CQE 回收）
//! 直接基于裸系统调用实现。只有系统调用包装与 ABI 结构布局
//! 取自操作系统接口；事件循环、提交策略与 VTable 接线
//! 都是 mox 自己的。
//!
//! 策略：SQE 懒入队，由 `wait` 统一刷出，随后阻塞在
//! 环 fd（外加用于 `Work` 通知的 eventfd）的 `poll(2)` 上。
//! 环 fd 可 poll：恰在有 CQE 可取时报告可读，因此
//! 无需 `IORING_OP_TIMEOUT` 就白得了超时支持。

const std = @import("std");
const linux = std.os.linux;
const root = @import("../io.zig");
const net = std.Io.net;

const Handle = root.Handle;
const INVALID_HANDLE = root.INVALID_HANDLE;

const io_uring_sqe = linux.io_uring_sqe;
const io_uring_params = linux.io_uring_params;
const io_uring_cqe = linux.io_uring_cqe;

const ENTRIES = 256;

const MapSlice = []align(std.heap.page_size_min) u8;

const State = struct {
    alloc: std.mem.Allocator,
    fd: i32,
    efd: i32,

    sq_map: MapSlice,
    cq_map: MapSlice,
    sqes_map: MapSlice,
    single_mmap: bool,

    sq_head: *u32,
    sq_tail: *u32,
    sq_array: [*]u32,
    sq_mask: u32,
    sqes: [*]io_uring_sqe,

    cq_head: *u32,
    cq_tail: *u32,
    cqes: [*]io_uring_cqe,
    cq_mask: u32,

    sq_pending: u32 = 0,
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

/// io_uring / 系统调用返回 `usize`，错误以 `-errno` 编码。
fn cvt(rc: usize) !usize {
    if (signed(rc) < 0) return error.SyscallFailed;
    return rc;
}

fn cvtFd(rc: usize) !i32 {
    _ = try cvt(rc);
    return @intCast(rc);
}

// ---- 环的初始化 ------------------------------------------------------------

fn setup(state: *State) !void {
    var p: io_uring_params = std.mem.zeroes(io_uring_params);
    const rc = linux.io_uring_setup(ENTRIES, &p);
    if (signed(rc) < 0) return error.SetupFailed;
    state.fd = @intCast(rc);

    const sq_ring_sz = p.sq_off.array + p.sq_entries * @sizeOf(u32);
    const cq_ring_sz = p.cq_off.cqes + p.cq_entries * @sizeOf(io_uring_cqe);
    const prot: std.posix.PROT = .{ .READ = true, .WRITE = true };
    const map_flags: std.posix.MAP = .{ .TYPE = .SHARED };

    if (p.features & linux.IORING_FEAT_SINGLE_MMAP != 0) {
        const sz = @max(sq_ring_sz, cq_ring_sz);
        const m = try std.posix.mmap(null, sz, prot, map_flags, state.fd, linux.IORING_OFF_SQ_RING);
        state.sq_map = m;
        state.cq_map = m;
        state.single_mmap = true;
    } else {
        state.sq_map = try std.posix.mmap(null, sq_ring_sz, prot, map_flags, state.fd, linux.IORING_OFF_SQ_RING);
        state.cq_map = try std.posix.mmap(null, cq_ring_sz, prot, map_flags, state.fd, linux.IORING_OFF_CQ_RING);
        state.single_mmap = false;
    }
    const sqes_sz = p.sq_entries * @sizeOf(io_uring_sqe);
    state.sqes_map = try std.posix.mmap(null, sqes_sz, prot, map_flags, state.fd, linux.IORING_OFF_SQES);

    const sqb = state.sq_map.ptr;
    state.sq_head = @ptrCast(@alignCast(sqb + p.sq_off.head));
    state.sq_tail = @ptrCast(@alignCast(sqb + p.sq_off.tail));
    state.sq_array = @ptrCast(@alignCast(sqb + p.sq_off.array));
    state.sq_mask = @as(*const u32, @ptrCast(@alignCast(sqb + p.sq_off.ring_mask))).*;
    state.sqes = @ptrCast(@alignCast(state.sqes_map.ptr));

    const cqb = state.cq_map.ptr;
    state.cq_head = @ptrCast(@alignCast(cqb + p.cq_off.head));
    state.cq_tail = @ptrCast(@alignCast(cqb + p.cq_off.tail));
    state.cqes = @ptrCast(@alignCast(cqb + p.cq_off.cqes));
    state.cq_mask = @as(*const u32, @ptrCast(@alignCast(cqb + p.cq_off.ring_mask))).*;

    const efd = linux.eventfd(0, 0);
    if (signed(efd) < 0) return error.EventfdFailed;
    state.efd = @intCast(efd);
}

fn teardown(state: *State) void {
    if (state.single_mmap) {
        std.posix.munmap(state.sq_map);
    } else {
        std.posix.munmap(state.sq_map);
        std.posix.munmap(state.cq_map);
    }
    std.posix.munmap(state.sqes_map);
    _ = linux.close(state.efd);
    _ = linux.close(state.fd);
}

// ---- SQE 提交 --------------------------------------------------------------

fn getSqe(state: *State) *io_uring_sqe {
    const tail = @atomicLoad(u32, state.sq_tail, .monotonic);
    const index = tail & state.sq_mask;
    const sqe = &state.sqes[index];
    sqe.* = std.mem.zeroes(io_uring_sqe);
    state.sq_array[index] = index;
    @atomicStore(u32, state.sq_tail, tail +% 1, .release);
    state.sq_pending += 1;
    return sqe;
}

fn flush(state: *State) void {
    if (state.sq_pending == 0) return;
    const rc = linux.io_uring_enter(state.fd, state.sq_pending, 0, 0, null);
    state.sq_pending = 0;
    if (signed(rc) < 0) {} // best-effort; a later poll will surface errors
}

fn peekCqe(state: *State) ?*io_uring_cqe {
    const head = @atomicLoad(u32, state.cq_head, .monotonic);
    const tail = @atomicLoad(u32, state.cq_tail, .acquire);
    if (head == tail) return null;
    return &state.cqes[head & state.cq_mask];
}

fn advanceCq(state: *State) void {
    const head = @atomicLoad(u32, state.cq_head, .monotonic);
    @atomicStore(u32, state.cq_head, head +% 1, .release);
}

// ---- VTable 实现 -----------------------------------------------------------

fn vtDeinit(userdata: ?*anyopaque) void {
    const state = stateOf(userdata);
    const alloc = state.alloc;
    teardown(state);
    alloc.destroy(state);
}

fn vtNow(userdata: ?*anyopaque) u64 {
    _ = userdata;
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

fn vtAssociate(userdata: ?*anyopaque, socket: Handle, key: usize) anyerror!void {
    _ = userdata;
    _ = socket;
    _ = key;
    // io_uring 无需注册：任何 fd 都能直接用。
}

fn vtRecv(userdata: ?*anyopaque, socket: Handle, buffer: []u8, scratch: *root.Scratch) anyerror!?usize {
    const state = stateOf(userdata);
    const sqe = getSqe(state);
    sqe.prep_recv(fdOf(socket), buffer, 0);
    sqe.user_data = @intFromPtr(scratch);
    return null;
}

fn vtSend(userdata: ?*anyopaque, socket: Handle, bytes: []const u8, scratch: *root.Scratch) anyerror!?usize {
    const state = stateOf(userdata);
    const sqe = getSqe(state);
    sqe.prep_send(fdOf(socket), bytes, 0);
    sqe.user_data = @intFromPtr(scratch);
    return null;
}

/// 异步 UDP 接收的后端私有状态。内核要一路读这张 `msghdr`，所以它必须住在
/// 调用方节点里（`hdr`），不能放栈上；也塞不进 64 字节的 `Scratch`。
const UdpRecvHdr = extern struct {
    msg: linux.msghdr,
    iov: [1]std.posix.iovec,
};

/// 异步 UDP 发送的状态，额外需要 sockaddr 存储（`buildSockaddr` 写在这里）。
const UdpSendHdr = extern struct {
    msg: linux.msghdr_const,
    iov: [1]std.posix.iovec_const,
    addr: [128]u8 align(8),
};

comptime {
    // 节点侧的 `hdr` 是 32 个 usize；超出就是我们的存储预算算错了，编译期拦下。
    if (@sizeOf(UdpRecvHdr) > 32 * @sizeOf(usize)) @compileError("UdpRecvHdr 超出 hdr 预算");
    if (@sizeOf(UdpSendHdr) > 32 * @sizeOf(usize)) @compileError("UdpSendHdr 超出 hdr 预算");
}

fn udpHdr(comptime T: type, hdr: []usize) *T {
    std.debug.assert(hdr.len * @sizeOf(usize) >= @sizeOf(T));
    return @ptrCast(@alignCast(hdr.ptr));
}

fn vtUdpRecv(
    userdata: ?*anyopaque,
    socket: Handle,
    buf: []u8,
    from: []u8,
    hdr: []usize,
    scratch: *root.Scratch,
) anyerror!void {
    const state = stateOf(userdata);
    const h = udpHdr(UdpRecvHdr, hdr);
    h.iov = .{.{ .base = buf.ptr, .len = buf.len }};
    h.msg = .{
        .name = @ptrCast(@alignCast(from.ptr)),
        .namelen = @intCast(from.len),
        .iov = &h.iov,
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    const sqe = getSqe(state);
    sqe.prep_recvmsg(fdOf(socket), &h.msg, 0);
    sqe.user_data = @intFromPtr(scratch);
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
    const h = udpHdr(UdpSendHdr, hdr);
    const len = buildSockaddr(to, &h.addr);
    h.iov = .{.{ .base = buf.ptr, .len = buf.len }};
    h.msg = .{
        .name = @ptrCast(@alignCast(&h.addr)),
        .namelen = len,
        .iov = &h.iov,
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    const sqe = getSqe(state);
    sqe.prep_sendmsg(fdOf(socket), &h.msg, 0);
    sqe.user_data = @intFromPtr(scratch);
}

fn vtClose(userdata: ?*anyopaque, socket: Handle) void {
    _ = userdata;
    _ = linux.close(fdOf(socket));
}

/// 按 user_data 取消一个已提交的 SQE。取消请求自身的 user_data 为 0，
/// `vtWait` 会跳过它的 CQE；原操作随后收到 `-ECANCELED` 完成包。
fn vtCancel(userdata: ?*anyopaque, socket: root.Handle, scratch: *root.Scratch) void {
    _ = socket;
    const state = stateOf(userdata);
    const sqe = getSqe(state);
    sqe.prep_cancel(@intFromPtr(scratch), 0);
    sqe.user_data = 0;
    flush(state);
}

fn vtAccept(userdata: ?*anyopaque, listen: Handle, accept_socket: Handle, addr_buf: []u8, scratch: *root.Scratch) anyerror!?usize {
    const state = stateOf(userdata);
    // 新 fd 由内核分配；预先建好的 socket（属于
    // AcceptEx 习惯，`server.zig` 刻意保持通用）在此不用。
    _ = linux.close(fdOf(accept_socket));

    // `addrlen` 必须存活到完成，暂存在 scratch 里。
    const addrlen: *linux.socklen_t = @ptrCast(@alignCast(&scratch.bytes));
    addrlen.* = @intCast(addr_buf.len);
    const sqe = getSqe(state);
    sqe.prep_accept(fdOf(listen), @ptrCast(@alignCast(addr_buf.ptr)), addrlen, 0);
    // Scratch 按 8 字节对齐，故 bit 0 空闲：给 accept 的 CQE 打标签，让 `toRef`
    // 无需认识 `Completion` 就能上报内核分配的 fd。
    sqe.user_data = @intFromPtr(scratch) | 1;
    return null;
}

fn vtUpdateAccept(userdata: ?*anyopaque, listen: Handle, accept_socket: Handle) void {
    _ = userdata;
    _ = listen;
    _ = accept_socket;
}

fn vtConnect(userdata: ?*anyopaque, socket: Handle, address: net.IpAddress, scratch: *root.Scratch) anyerror!void {
    const state = stateOf(userdata);
    const len = buildSockaddr(address, &scratch.bytes);
    const sa: *const linux.sockaddr = @ptrCast(@alignCast(&scratch.bytes));
    const sqe = getSqe(state);
    sqe.prep_connect(fdOf(socket), sa, len);
    sqe.user_data = @intFromPtr(scratch);
}

fn vtUpdateConnect(userdata: ?*anyopaque, socket: Handle) void {
    _ = userdata;
    _ = socket;
}

/// 一次 `poll` / 一次 CQ 扫描收走所有已就绪的完成包。
/// `user_data == 0` 是取消请求自身的 CQE，直接跳过。
fn vtWaitBatch(userdata: ?*anyopaque, timeout_ms: u32, refs: []root.Ref) anyerror!usize {
    const state = stateOf(userdata);
    flush(state);

    var n = reapCq(state, refs);
    if (n != 0) return n;

    const wait_forever = timeout_ms >= std.math.maxInt(u32) / 2;
    const pt: i32 = if (wait_forever) -1 else @intCast(timeout_ms);

    var fds = [_]std.posix.pollfd{
        .{ .fd = state.fd, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = state.efd, .events = std.posix.POLL.IN, .revents = 0 },
    };
    _ = std.posix.poll(&fds, pt) catch return 0;

    if (fds[1].revents & std.posix.POLL.IN != 0) {
        var buf: [8]u8 = undefined;
        _ = linux.read(state.efd, &buf, buf.len);
    }
    n = reapCq(state, refs);
    return n;
}

/// 扫 CQ 环，最多填 `refs.len` 个；跳过取消请求的哨兵 CQE。
fn reapCq(state: *State, refs: []root.Ref) usize {
    var n: usize = 0;
    while (n < refs.len) {
        const cqe = peekCqe(state) orelse break;
        if (cqe.user_data != 0) {
            refs[n] = fillRef(cqe);
            n += 1;
        }
        advanceCq(state);
    }
    return n;
}

fn fillRef(cqe: *const linux.io_uring_cqe) root.Ref {
    const tagged = cqe.user_data;
    const is_accept = tagged & 1 != 0;
    const res = cqe.res;
    return .{
        .scratch = @ptrFromInt(tagged & ~@as(u64, 1)),
        .bytes = if (res >= 0) @intCast(res) else 0,
        .failed = res < 0,
        .new_handle = if (is_accept and res >= 0) @intCast(res) else root.INVALID_HANDLE,
    };
}

fn vtNotify(userdata: ?*anyopaque) void {
    const state = stateOf(userdata);
    var one: u64 = 1;
    _ = linux.write(state.efd, std.mem.asBytes(&one), 8);
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
    state.* = .{
        .alloc = alloc,
        .fd = -1,
        .efd = -1,
        .sq_map = undefined,
        .cq_map = undefined,
        .sqes_map = undefined,
        .single_mmap = false,
        .sq_head = undefined,
        .sq_tail = undefined,
        .sq_array = undefined,
        .sq_mask = 0,
        .sqes = undefined,
        .cq_head = undefined,
        .cq_tail = undefined,
        .cqes = undefined,
        .cq_mask = 0,
    };
    try setup(state);
    return .{ .userdata = state, .vtable = &vtable_storage };
}

// ---- sockaddr 编组 ---------------------------------------------------------

/// 把 `address` 以 `sockaddr` 形式写入 `storage`，返回其长度。
fn buildSockaddr(address: net.IpAddress, storage: []u8) linux.socklen_t {
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

fn fromSockaddr(storage: *const [128]u8) net.IpAddress {
    const family = @as(*align(1) const linux.sa_family_t, @ptrCast(storage)).*;
    if (family == linux.AF.INET) {
        const sa: *align(1) const linux.sockaddr.in = @ptrCast(storage);
        return .{ .ip4 = .{ .bytes = @bitCast(sa.addr), .port = std.mem.bigToNative(u16, sa.port) } };
    }
    const sa: *align(1) const linux.sockaddr.in6 = @ptrCast(storage);
    return .{ .ip6 = .{ .bytes = sa.addr, .port = std.mem.bigToNative(u16, sa.port) } };
}

// ---- 平台套接字辅助函数（与 Windows 侧对齐） -------------------------------

pub fn createSocket(domain: u32, kind: u32, protocol: u32) !Handle {
    return @intCast(try cvtFd(linux.socket(domain, kind, protocol)));
}

pub fn createTcpSocket(address: net.IpAddress) !Handle {
    const domain: u32 = switch (address) {
        .ip4 => linux.AF.INET,
        .ip6 => linux.AF.INET6,
    };
    return createSocket(domain, linux.SOCK.STREAM, linux.IPPROTO.TCP);
}

/// UDP 能力用的阻塞数据报 helper；在 `Work` 池线程里调用。
pub fn createUdpSocket(address: net.IpAddress) !Handle {
    const domain: u32 = switch (address) {
        .ip4 => linux.AF.INET,
        .ip6 => linux.AF.INET6,
    };
    return createSocket(domain, linux.SOCK.DGRAM, linux.IPPROTO.UDP);
}

pub fn recvFromBlocking(h: Handle, buf: []u8, from: []u8) !usize {
    var len: linux.socklen_t = @intCast(from.len);
    const sa: *linux.sockaddr = @ptrCast(@alignCast(from.ptr));
    return cvt(linux.recvfrom(fdOf(h), buf.ptr, buf.len, 0, sa, &len));
}

pub fn sendToBlocking(h: Handle, buf: []const u8, address: net.IpAddress) !usize {
    var storage: [128]u8 = undefined;
    const len = buildSockaddr(address, &storage);
    const sa: *const linux.sockaddr = @ptrCast(@alignCast(&storage));
    return cvt(linux.sendto(fdOf(h), buf.ptr, buf.len, 0, sa, len));
}

pub fn bindSocket(h: Handle, address: net.IpAddress) !void {
    var storage: [128]u8 = undefined;
    const len = buildSockaddr(address, &storage);
    const sa: *const linux.sockaddr = @ptrCast(@alignCast(&storage));
    _ = try cvt(linux.bind(fdOf(h), sa, len));
}

pub fn listenSocket(h: Handle, backlog: c_int) !void {
    _ = try cvt(linux.listen(fdOf(h), @intCast(backlog)));
}

pub fn localAddress(h: Handle) !net.IpAddress {
    var storage: [128]u8 = undefined;
    var len: linux.socklen_t = storage.len;
    const sa: *linux.sockaddr = @ptrCast(@alignCast(&storage));
    _ = try cvt(linux.getsockname(fdOf(h), sa, &len));
    return fromSockaddr(&storage);
}

pub fn acceptSocket(h: Handle) !struct { socket: Handle, address: net.IpAddress } {
    var storage: [128]u8 = undefined;
    var len: linux.socklen_t = storage.len;
    const sa: *linux.sockaddr = @ptrCast(@alignCast(&storage));
    const cfd = try cvtFd(linux.accept(fdOf(h), sa, &len));
    return .{ .socket = @intCast(cfd), .address = fromSockaddr(&storage) };
}

pub fn connectSocket(h: Handle, address: net.IpAddress) !void {
    var storage: [128]u8 = undefined;
    const len = buildSockaddr(address, &storage);
    const sa: *const linux.sockaddr = @ptrCast(@alignCast(&storage));
    _ = try cvt(linux.connect(fdOf(h), @ptrCast(sa), len));
}

pub fn setReuseAddress(h: Handle, on: bool) !void {
    const v: c_int = if (on) 1 else 0;
    try std.posix.setsockopt(fdOf(h), linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&v));
}

/// 语义选项 → Linux `setsockopt`。`SOL.SOCKET` / `IPPROTO.TCP` 的常量在
/// `std.os.linux` 里已经齐备，这里只做映射，不重复定义数值。
pub fn setSockOpt(h: Handle, opt: root.SockOpt, value: u32) !void {
    const v: c_int = @intCast(value);
    const bytes = std.mem.asBytes(&v);
    const fd = fdOf(h);
    switch (opt) {
        .tcp_nodelay => try std.posix.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, bytes),
        .keepalive_idle => try std.posix.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.KEEPIDLE, bytes),
        .recv_buf => try std.posix.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVBUF, bytes),
        .send_buf => try std.posix.setsockopt(fd, linux.SOL.SOCKET, linux.SO.SNDBUF, bytes),
    }
}

/// 只关发送方向。调用后对端仍能读到我们已经发出的全部数据，是优雅收尾。
pub fn shutdownSend(h: Handle) !void {
    _ = try cvt(linux.shutdown(fdOf(h), linux.SHUT.WR));
}

pub fn closeSocket(h: Handle) void {
    _ = linux.close(fdOf(h));
}

pub fn sendBlocking(h: Handle, bytes: []const u8) !usize {
    var off: usize = 0;
    while (off < bytes.len) off += try cvt(linux.write(fdOf(h), bytes.ptr + off, bytes.len - off));
    return off;
}

/// 阻塞接收，仅用于测试 / benchmark 的客户端线程。
pub fn recvBlocking(h: Handle, buf: []u8) !usize {
    return cvt(linux.read(fdOf(h), buf.ptr, buf.len));
}

pub fn tickCount() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

// ---- 扁平文件 I/O（在 `Work` 池线程中执行） --------------------------------

pub fn fileSize(path: []const u8) !u64 {
    const fd = try std.posix.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = linux.close(fd);
    const end = try cvt(linux.lseek(fd, 0, linux.SEEK.END));
    return @intCast(end);
}

pub fn readFileInto(path: []const u8, buf: []u8) !usize {
    const fd = try std.posix.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = linux.close(fd);
    var total: usize = 0;
    while (total < buf.len) {
        const n = try cvt(linux.read(fd, buf.ptr + total, buf.len - total));
        if (n == 0) break;
        total += n;
    }
    return total;
}

pub fn writeFileAll(path: []const u8, bytes: []const u8) !void {
    const fd = try std.posix.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    defer _ = linux.close(fd);
    var off: usize = 0;
    while (off < bytes.len) {
        off += try cvt(linux.write(fd, bytes.ptr + off, bytes.len - off));
    }
}

pub fn deleteFile(path: []const u8) void {
    var buf: [1024]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = linux.unlinkat(linux.AT.FDCWD, buf[0..path.len :0], 0);
}

// ---- 测试（在 Linux 运行；已在 WSL 验证） ----------------------------------

test "io_uring: a timer fires through the loop" {
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

test "io_uring: accept, receive and send through the loop" {
    var l = root.Loop.init(try create(std.testing.allocator));
    defer l.deinit();

    const bind_addr = try net.IpAddress.parse("127.0.0.1", 0);
    const listener = try createTcpSocket(bind_addr);
    defer closeSocket(listener);
    try setReuseAddress(listener, true);
    try bindSocket(listener, bind_addr);
    const bound = try localAddress(listener);
    try listenSocket(listener, 16);

    const accept_sock = try createTcpSocket(bind_addr);
    defer closeSocket(accept_sock);

    const Client = struct {
        fn run(addr: net.IpAddress) void {
            const c = createTcpSocket(addr) catch return;
            defer closeSocket(c);
            connectSocket(c, addr) catch return;
            _ = linux.write(fdOf(c), "hello", 5);
        }
    };
    const t = try std.Thread.spawn(.{}, Client.run, .{bound});

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

    try l.associate(listener, 0);
    var acc = root.NetAccept.init(listener, accept_sock);
    acc.c.callback = &Ctx.onAccept;
    l.add(&acc.c);
    try l.run();

    t.join();
    if (Ctx.accepted != INVALID_HANDLE) closeSocket(Ctx.accepted);
    try std.testing.expectEqualStrings("hello", Ctx.buf[0..Ctx.got]);
}

test "io_uring: a Work item runs on the pool and completes on the loop" {
    var l = root.Loop.init(try create(std.testing.allocator));
    defer l.deinit();

    const Item = struct { work: root.Work, value: u32 = 0 };
    const Ctx = struct {
        var done = false;
        fn workFn(w: *root.Work) void {
            const self: *Item = @fieldParentPtr("work", w);
            self.value = 42;
        }
        fn done_cb(lp: *root.Loop, c: *root.Completion) void {
            _ = c;
            done = true;
            lp.stop();
        }
    };
    var item: Item = .{ .work = root.Work.init(&Ctx.workFn) };
    item.work.c.callback = &Ctx.done_cb;
    l.add(&item.work.c);
    try l.run();

    try std.testing.expect(Ctx.done);
    try std.testing.expectEqual(@as(u32, 42), item.value);
}

test "io_uring: an async connect completes through the loop" {
    var l = root.Loop.init(try create(std.testing.allocator));
    defer l.deinit();

    const bind_addr = try net.IpAddress.parse("127.0.0.1", 0);
    const listener = try createTcpSocket(bind_addr);
    defer closeSocket(listener);
    try setReuseAddress(listener, true);
    try bindSocket(listener, bind_addr);
    const bound = try localAddress(listener);
    try listenSocket(listener, 16);

    const Acceptor = struct {
        fn run(h: Handle) void {
            const peer = acceptSocket(h) catch return;
            closeSocket(peer.socket);
        }
    };
    const t = try std.Thread.spawn(.{}, Acceptor.run, .{listener});

    const client = try createTcpSocket(bound);
    defer closeSocket(client);

    const Ctx = struct {
        var ok = false;
        fn cb(lp: *root.Loop, c: *root.Completion) void {
            const nc: *root.NetConnect = @fieldParentPtr("c", c);
            nc.getResult() catch {
                lp.stop();
                return;
            };
            ok = true;
            lp.stop();
        }
    };
    var conn = root.NetConnect.init(client, bound);
    conn.c.callback = &Ctx.cb;
    l.add(&conn.c);
    try l.run();

    t.join();
    try std.testing.expect(Ctx.ok);
}

test "io_uring: ReadFile reads a file off the loop thread" {
    var l = root.Loop.init(try create(std.testing.allocator));
    defer l.deinit();

    const path = "zig-cache-mox-uring-readfile.txt";
    try writeFileAll(path, "static-asset-body");
    defer deleteFile(path);

    const Ctx = struct {
        var ok = false;
        fn cb(lp: *root.Loop, c: *root.Completion) void {
            _ = c;
            ok = true;
            lp.stop();
        }
    };
    var buf: [64]u8 = undefined;
    var rf = root.ReadFile.init(l.io, path, &buf, null);
    rf.work.c.callback = &Ctx.cb;
    l.add(&rf.work.c);
    try l.run();

    try std.testing.expect(Ctx.ok);
    try std.testing.expectEqualStrings("static-asset-body", try rf.getResult());
}
