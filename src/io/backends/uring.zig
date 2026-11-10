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
    // `MSG_NOSIGNAL` 不可省：对端已关闭时内核默认投递 SIGPIPE，直接把整个进程
    // 杀掉（实测：write 到半关闭连接，第二次写就死）。带上它才变成可处理的 EPIPE。
    sqe.prep_send(fdOf(socket), bytes, linux.MSG.NOSIGNAL);
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
            // 文件 I/O 完成：同步关掉 openat 开的 fd（纳秒级，不必异步）。
            if (cqe.user_data & FILE_TAG != 0) {
                const sp: *root.Scratch = @ptrFromInt(cqe.user_data & ~@as(u64, 7));
                _ = linux.close(takeFd(sp));
            }
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
    const is_watch = tagged & 2 != 0;
    // 文件 I/O 的 `res` 直接就是读写字节数，不需要像 `POLL_ADD` 那样翻译。
    const res = cqe.res;
    var bytes: usize = if (res >= 0) @intCast(res) else 0;
    if (is_watch and res >= 0) {
        // `POLL_ADD` 的 `res` 是 poll 掩码，与 `Ready` 位布局不同，必须翻译。
        var r: root.Ready = .{};
        if (res & std.posix.POLL.IN != 0) r.read = true;
        if (res & std.posix.POLL.OUT != 0) r.write = true;
        if (res & std.posix.POLL.ERR != 0) r.failed = true;
        if (res & std.posix.POLL.HUP != 0) r.hangup = true;
        if (!r.any()) r.failed = true;
        bytes = r.bits();
    }
    return .{
        .scratch = @ptrFromInt(tagged & ~@as(u64, 7)),
        .bytes = bytes,
        .failed = res < 0,
        .new_handle = if (is_accept and res >= 0) @intCast(res) else root.INVALID_HANDLE,
    };
}

fn vtWatchFd(userdata: ?*anyopaque, fd: Handle, want: root.Ready, scratch: *root.Scratch) anyerror!?void {
    const state = stateOf(userdata);
    var mask: u32 = 0;
    if (want.read) mask |= std.posix.POLL.IN;
    if (want.write) mask |= std.posix.POLL.OUT;
    if (mask == 0) return error.NothingToWatch;
    const sqe = getSqe(state);
    // `POLL_ADD` 是「就绪即完成」的 SQE，天然符合 `WatchFd` 的一次性语义。
    // CQE 的 `res` 就是就绪掩码（`POLL.IN` / `POLL.OUT` / `POLL.ERR` / `POLL.HUP`），
    // 正好在 `fillRef` 里作为 `bytes` 回传，与 epoll / kqueue 形状一致。
    sqe.prep_poll_add(fdOf(fd), mask);
    // bit0 已被 accept 占用；watch 用 bit1 标记，`fillRef` 据此把 POLL 掩码
    // 翻译成 `Ready` 位布局（两者数值不同，不能直接透传）。
    sqe.user_data = @intFromPtr(scratch) | 2;
    return null;
}

// ---- Unix domain socket ---------------------------------------------------

/// 把路径编成 `sockaddr_un`。返回长度（含 NUL，内核要求）。
/// 路径超长（`sun_path` 108 字节）直接报错，不截断——截断会连到别的 socket。
pub fn buildUnixSockaddrPub(path: []const u8, storage: *linux.sockaddr.un) !linux.socklen_t {
    return buildUnixSockaddr(path, storage);
}

fn buildUnixSockaddr(path: []const u8, storage: *linux.sockaddr.un) !linux.socklen_t {
    // 留一个字节给 NUL。
    if (path.len >= storage.path.len) return error.NameTooLong;
    if (path.len == 0) return error.InvalidPath;
    storage.family = linux.AF.UNIX;
    @memcpy(storage.path[0..path.len], path);
    storage.path[path.len] = 0;
    // 长度按「结构头 + 路径 + NUL」算，不传整个 108 字节，否则内核会读到
    // 缓冲区里的垃圾字节。
    return @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1);
}

pub fn vtCreateUnix(userdata: ?*anyopaque) anyerror!root.Handle {
    _ = userdata;
    return createSocket(linux.AF.UNIX, linux.SOCK.STREAM, 0);
}

pub fn vtBindUnix(userdata: ?*anyopaque, socket: root.Handle, path: []const u8) anyerror!void {
    _ = userdata;
    var sa: linux.sockaddr.un = undefined;
    const len = try buildUnixSockaddr(path, &sa);
    const rc_s = signed(linux.bind(fdOf(socket), @ptrCast(&sa), len));
    if (rc_s < 0) {
        if (rc_s == -@as(isize, @backingInt(linux.E.ADDRINUSE))) return error.PathAlreadyExists;
        return error.BindFailed;
    }
}

pub fn vtConnectUnix(userdata: ?*anyopaque, socket: root.Handle, path: []const u8, scratch: *root.Scratch) anyerror!?void {
    const state = stateOf(userdata);
    var sa: linux.sockaddr.un = undefined;
    const len = try buildUnixSockaddr(path, &sa);
    // UDS 的 `sockaddr_un` 必须活到内核读完，不能放栈上。`Scratch` 只有
    // 64 字节，扣掉结构头（2 字节 family）后路径上限约 62 字节。
    //
    // 这是**刻意的限制**而不是疏忽：要支持更长的路径得给 `UnixConnect`
    // 节点加一块专用缓冲（像 `UdpRecv.hdr` 那样），代价是节点变大。当前
    // 62 字节覆盖 `/tmp/xxx.sock`、`/var/run/xxx.sock` 这类常见路径；超出
    // 时明确报 `NameTooLong`，而不是悄悄截断连到别的 socket。
    if (len > @sizeOf(root.Scratch)) return error.NameTooLong;
    @memcpy(std.mem.asBytes(scratch)[0..len], std.mem.asBytes(&sa)[0..len]);
    const sqe = getSqe(state);
    sqe.prep_connect(fdOf(socket), @ptrCast(@alignCast(scratch)), len);
    sqe.user_data = @intFromPtr(scratch);
    return null;
}

// ---- 原生异步文件 I/O（io_uring 独有） ------------------------------------
//
// 设计取舍：`openat` 与 `close` 同步做，只有 `read` / `write` 异步。
//
// 为什么 openat 不异步？io_uring 的 `IOSQE_IO_LINK` **不会**把前一条的返回值
// 传给后一条的 fd 字段——fd 必须是提交时已知的具体值。（曾按「链内传递」
// 实现，read 拿 -1 直接失败，实测证伪。）
//
// 为什么 close 不链在 read 后面？实测链式 close 的 CQE 回 `-125`
// （ECANCELED），fd 反而泄漏。`open` / `close` 都是元数据操作，纳秒到微秒级，
// 留在同步侧没有可观测代价；真正慢的是 read/write 的数据传输，那部分是真异步。
//
// fd 的去向：提交时把 fd 写进 `Scratch` 的前 4 字节（`Scratch` 只在这一处用
// 前 4 字节，TCP/UDP 路径用整块装 sockaddr，互不干扰），reap 时按标记位取出
// 并同步 close。

/// 文件 I/O 的 CQE 标记位（bit2）。TCP accept 用 bit0、WatchFd 用 bit1。
const FILE_TAG: u64 = 4;

/// 同步 `openat`，失败翻译成 `error`。
fn openSync(path: [*:0]const u8, flags: linux.O, mode: linux.mode_t) !linux.fd_t {
    const rc = linux.openat(linux.AT.FDCWD, path, flags, mode);
    const rc_s = signed(rc);
    if (rc_s < 0) return switch (-rc_s) {
        @backingInt(linux.E.NOENT) => error.FileNotFound,
        @backingInt(linux.E.ACCES) => error.AccessDenied,
        @backingInt(linux.E.ISDIR) => error.IsDir,
        @backingInt(linux.E.NAMETOOLONG) => error.NameTooLong,
        else => error.OpenFailed,
    };
    return @intCast(rc_s);
}

/// 把 fd 记进 `Scratch` 前 4 字节，供 reap 时同步 close。
fn stashFd(scratch: *root.Scratch, fd: linux.fd_t) void {
    std.mem.writeInt(u32, scratch.bytes[0..4], @bitCast(fd), .little);
}

fn takeFd(scratch: *root.Scratch) linux.fd_t {
    return @bitCast(std.mem.readInt(u32, scratch.bytes[0..4], .little));
}

fn vtReadFileAsync(
    userdata: ?*anyopaque,
    path: [*:0]const u8,
    offset: u64,
    buf: []u8,
    scratch: *root.Scratch,
) anyerror!?void {
    const state = stateOf(userdata);
    const fd = try openSync(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    errdefer _ = linux.close(fd);
    stashFd(scratch, fd);

    const sqe = getSqe(state);
    sqe.prep_read(fd, buf, offset);
    sqe.user_data = @intFromPtr(scratch) | FILE_TAG;
    return null;
}

fn vtWriteFileAsync(
    userdata: ?*anyopaque,
    path: [*:0]const u8,
    offset: u64,
    bytes: []const u8,
    scratch: *root.Scratch,
) anyerror!?void {
    const state = stateOf(userdata);
    const fd = try openSync(
        path,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
        0o644,
    );
    errdefer _ = linux.close(fd);
    stashFd(scratch, fd);

    const sqe = getSqe(state);
    sqe.prep_write(fd, bytes, offset);
    sqe.user_data = @intFromPtr(scratch) | FILE_TAG;
    return null;
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

fn vtStatPath(userdata: ?*anyopaque, path: []const u8) anyerror!root.Stat {
    _ = userdata;
    const st = try stat(path);
    return .{ .kind = @fromBackingInt(@intCast(@backingInt(st.kind))), .size = st.size, .mtime_ms = st.mtime_ms };
}

fn vtListDir(userdata: ?*anyopaque, path: []const u8, buf: []root.DirEntry) anyerror!usize {
    _ = userdata;
    return listDir(path, @ptrCast(buf));
}

fn vtDeleteFile(userdata: ?*anyopaque, path: []const u8) anyerror!void {
    _ = userdata;
    deleteFile(path);
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
    .readFileAt = vtReadFileAt,
    .appendFile = vtAppendFile,
    .truncateFile = vtTruncateFile,
    .deleteFile = vtDeleteFile,
    .makeDir = vtMakeDir,
    .removeDir = vtRemoveDir,
    .rename = vtRename,
    .symLink = vtSymLink,
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
    .readFileAsync = vtReadFileAsync,
    .writeFileAsync = vtWriteFileAsync,
    .createUnix = vtCreateUnix,
    .bindUnix = vtBindUnix,
    .connectUnix = vtConnectUnix,
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
    while (off < bytes.len) {
        // 走 `sendto` 而非 `write`，只为能带 `MSG_NOSIGNAL`（见 `vtSend` 的注释）。
        off += try cvt(linux.sendto(fdOf(h), bytes.ptr + off, bytes.len - off, linux.MSG.NOSIGNAL, null, 0));
    }
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

// ---- 目录与元数据（同样在 `Work` 池线程中执行） --------------------------

/// 路径转 NUL 结尾的定长缓冲。路径超长直接报错，不截断——截断会静默
/// 操作到别的文件，比失败更糟。
fn pathZ(path: []const u8, buf: []u8) ![*:0]const u8 {
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

/// 创建目录（含所有缺失的父目录，等价 `mkdir -p`）。
/// `mode` 受进程 umask 影响，与 `mkdir(1)` 一致。
pub fn makeDir(path: []const u8, mode: u32) !void {
    if (path.len == 0) return error.InvalidPath;
    var buf: [1024]u8 = undefined;
    var i: usize = 0;
    // 逐级创建：遇到 '/' 就尝试建前缀，已存在（EEXIST）视为正常。
    while (i <= path.len) : (i += 1) {
        if (i != path.len and path[i] != '/') continue;
        if (i == 0) continue;
        const prefix = try pathZ(path[0..i], &buf);
        const rc = linux.mkdirat(linux.AT.FDCWD, prefix, @intCast(mode));
        const rc_s: isize = signed(rc);
        // EEXIST 不算失败；其他错误上报。
        if (rc_s < 0 and rc_s != -@as(isize, @backingInt(linux.E.EXIST))) return error.MakeDirFailed;
    }
    return;
}

/// 删除空目录。非空时返回 `error.DirNotEmpty`（不递归，避免误删）。
pub fn removeDir(path: []const u8) !void {
    var buf: [1024]u8 = undefined;
    const p = try pathZ(path, &buf);
    // `AT.REMOVEDIR` 让 unlinkat 走 rmdir 语义。
    const rc = linux.unlinkat(linux.AT.FDCWD, p, linux.AT.REMOVEDIR);
    const rc_s: isize = signed(rc);
    if (rc_s == 0) return;
    if (rc_s == -@as(isize, @backingInt(linux.E.NOTEMPTY))) return error.DirNotEmpty;
    if (rc_s == -@as(isize, @backingInt(linux.E.NOENT))) return error.FileNotFound;
    return error.RemoveDirFailed;
}

/// 重命名 / 移动。跨设备时内核返回 `EXDEV`，这里如实上报而不是偷偷
/// 退化成「复制 + 删除」——那会在中途失败时留下半个文件。
pub fn rename(old_path: []const u8, new_path: []const u8) !void {
    var obuf: [1024]u8 = undefined;
    var nbuf: [1024]u8 = undefined;
    const o = try pathZ(old_path, &obuf);
    const n = try pathZ(new_path, &nbuf);
    const rc = linux.renameat(linux.AT.FDCWD, o, linux.AT.FDCWD, n);
    const rc_s: isize = signed(rc);
    if (rc_s == 0) return;
    if (rc_s == -@as(isize, @backingInt(linux.E.XDEV))) return error.CrossDevice;
    if (rc_s == -@as(isize, @backingInt(linux.E.NOENT))) return error.FileNotFound;
    return error.RenameFailed;
}

/// 创建符号链接：`target` 是链接指向的路径（可以是相对路径），`link_path`
/// 是要创建的链接本身。
pub fn symLink(target: []const u8, link_path: []const u8) !void {
    var tbuf: [1024]u8 = undefined;
    var lbuf: [1024]u8 = undefined;
    const t = try pathZ(target, &tbuf);
    const l = try pathZ(link_path, &lbuf);
    const rc = linux.symlinkat(t, linux.AT.FDCWD, l);
    const rc_s: isize = signed(rc);
    if (rc_s == 0) return;
    if (rc_s == -@as(isize, @backingInt(linux.E.EXIST))) return error.PathAlreadyExists;
    return error.SymLinkFailed;
}

/// 文件类型。与 `std.fs.File.Kind` 的常用子集对齐，够静态服务判断
/// 「是不是普通文件」用。
pub const FileKind = enum { file, directory, sym_link, other };

/// 路径元数据。`mtime_ms` 是 Unix 毫秒，便于直接做 `If-Modified-Since`。
pub const Stat = struct {
    kind: FileKind,
    size: u64,
    /// 最后修改时间（Unix 毫秒）。
    mtime_ms: i64,
};

/// 取路径元数据。**跟随符号链接**（与 `stat(1)` 一致）；要拿链接本身用
/// `AT.SYMLINK_NOFOLLOW` 的变体，这里不提供。
pub fn stat(path: []const u8) !Stat {
    var buf: [1024]u8 = undefined;
    const p = try pathZ(path, &buf);
    var stx: linux.Statx = std.mem.zeroes(linux.Statx);
    // 0.17 的 std 只绑了 `statx`（没有 `fstatat` 包装）。掩码要显式要
    // TYPE / SIZE / MTIME 三项；内核可能回填不了全部，故按 `stx.mask` 判断。
    const mask = linux.STATX{
        .TYPE = true,
        .MODE = true,
        .SIZE = true,
        .MTIME = true,
    };
    const rc_s = signed(linux.statx(linux.AT.FDCWD, p, 0, mask, &stx));
    if (rc_s < 0) {
        if (rc_s == -@as(isize, @backingInt(linux.E.NOENT))) return error.FileNotFound;
        return error.StatFailed;
    }
    const kind: FileKind = switch (stx.mode & linux.S.IFMT) {
        linux.S.IFREG => .file,
        linux.S.IFDIR => .directory,
        linux.S.IFLNK => .sym_link,
        else => .other,
    };
    // 内核没回填 mtime 时给 0，调用方据此认为「未知」，而不是假装 1970。
    const mtime_ms: i64 = if (stx.mask.MTIME)
        stx.mtime.sec * 1000 + @divTrunc(@as(i64, stx.mtime.nsec), 1_000_000)
    else
        0;
    return .{
        .kind = kind,
        .size = if (stx.mask.SIZE) stx.size else 0,
        .mtime_ms = mtime_ms,
    };
}

/// 列目录项。`buf` 由调用方提供，返回**条目名切片**（不含路径前缀），
/// 超出缓冲时截断到能放下的部分——调用方据返回值判断是否还有剩余。
///
/// 不排序、不含 `.` 与 `..`：排序是策略，交给调用方。
pub fn listDir(path: []const u8, buf: []DirEntry) !usize {
    var pbuf: [1024]u8 = undefined;
    const p = try pathZ(path, &pbuf);
    const fd = try std.posix.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    defer _ = linux.close(fd);

    var raw: [4096]u8 = undefined;
    var count: usize = 0;
    while (true) {
        const rc = linux.getdents64(fd, &raw, raw.len);
        const rc_s: isize = signed(rc);
        if (rc_s <= 0) break;
        const got: usize = @intCast(rc_s);
        var off: usize = 0;
        while (off < got) {
            // `linux.dirent64` 的 d_name 是柔性数组，手工按偏移取。
            const ent: *align(1) const linux.dirent64 = @ptrCast(raw[off..].ptr);
            const rec_len: usize = ent.reclen;
            if (rec_len == 0 or off + rec_len > got) break;
            const name_ptr = raw[off + @offsetOf(linux.dirent64, "name") .. off + rec_len];
            const name = std.mem.sliceTo(name_ptr, 0);
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                if (count >= buf.len) return count; // 缓冲满，截断
                if (name.len <= buf[count].name.len) {
                    @memcpy(buf[count].name[0..name.len], name);
                    buf[count].len = name.len;
                    buf[count].is_dir = ent.type == linux.DT.DIR;
                    count += 1;
                }
            }
            off += rec_len;
        }
    }
    _ = p;
    return count;
}

/// `listDir` 的条目。名字定长，避免调用方管内存；超长名字被跳过
/// （`NAME_MAX` 通常 255，这里给 256）。
pub const DirEntry = struct {
    name: [256]u8 = undefined,
    len: usize = 0,
    is_dir: bool = false,

    pub fn slice(self: *const DirEntry) []const u8 {
        return self.name[0..self.len];
    }
};

pub fn deleteFile(path: []const u8) void {
    var buf: [1024]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = linux.unlinkat(linux.AT.FDCWD, buf[0..path.len :0], 0);
}

/// 从 `offset` 处读入 `buf`，返回实际读到的字节数（文件尾会短读）。
/// 与 `readFileInto` 的区别是支持随机访问，是分段读大文件的基础。
pub fn readFileAt(path: []const u8, offset: u64, buf: []u8) !usize {
    const fd = try std.posix.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = linux.close(fd);
    _ = try cvt(linux.lseek(fd, @intCast(offset), linux.SEEK.SET));
    var total: usize = 0;
    while (total < buf.len) {
        const n = try cvt(linux.read(fd, buf.ptr + total, buf.len - total));
        if (n == 0) break;
        total += n;
    }
    return total;
}

/// 在文件末尾追加 `bytes`；文件不存在时创建。只做追加，不动既有内容。
pub fn appendFile(path: []const u8, bytes: []const u8) !void {
    const fd = try std.posix.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
    defer _ = linux.close(fd);
    var off: usize = 0;
    while (off < bytes.len) {
        off += try cvt(linux.write(fd, bytes.ptr + off, bytes.len - off));
    }
}

/// 把文件截断到 `size` 字节。
pub fn truncateFile(path: []const u8, size: u64) !void {
    const fd = try std.posix.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .WRONLY }, 0);
    defer _ = linux.close(fd);
    _ = try cvt(linux.ftruncate(fd, @intCast(size)));
}

// ---- 测试（在 Linux 运行；已在 WSL 验证） ----------------------------------

/// 这些测试只验 io_uring 后端本身，必须真的用到内核的 io_uring。
/// 在 `io_uring_disabled=1` 或旧内核上 `create` 会失败——那不是 mox 的
/// 缺陷，而是环境不支持，此时跳过。其它错误仍然照常抛出。
fn testLoop() !?root.Loop {
    const io_value = create(std.testing.allocator) catch |e| switch (e) {
        error.SetupFailed => return null,
        else => return e,
    };
    return root.Loop.init(io_value);
}

test "io_uring: a timer fires through the loop" {
    const maybe_loop = try testLoop();
    if (maybe_loop == null) return; // 本机没有 io_uring，跳过
    var l = maybe_loop.?;
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
    const maybe_loop = try testLoop();
    if (maybe_loop == null) return; // 本机没有 io_uring，跳过
    var l = maybe_loop.?;
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
    const maybe_loop = try testLoop();
    if (maybe_loop == null) return; // 本机没有 io_uring，跳过
    var l = maybe_loop.?;
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
    const maybe_loop = try testLoop();
    if (maybe_loop == null) return; // 本机没有 io_uring，跳过
    var l = maybe_loop.?;
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
    const maybe_loop = try testLoop();
    if (maybe_loop == null) return; // 本机没有 io_uring，跳过
    var l = maybe_loop.?;
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
