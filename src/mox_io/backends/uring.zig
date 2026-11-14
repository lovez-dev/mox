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
const types = @import("../types.zig");
const io_mod = @import("../io.zig");
const completion = @import("../completion.zig");
const sys = @import("../sys.zig");
const file_mod = @import("../file.zig");
const loop_mod = @import("../loop.zig");
const net = std.Io.net;
const system = @import("linux_sys.zig");
pub const IOV_MAX = system.IOV_MAX;
pub const buildUnixSockaddrPub = system.buildUnixSockaddrPub;
const buildUnixSockaddr = system.buildUnixSockaddr;
pub const vtCreateUnix = system.vtCreateUnix;
pub const vtBindUnix = system.vtBindUnix;
const openSync = system.openSync;
pub const vtSendFileTo = system.vtSendFileTo;
const buildSockaddr = system.buildSockaddr;
pub const createSocket = system.createSocket;
pub const createTcpSocket = system.createTcpSocket;
pub const createUdpSocket = system.createUdpSocket;
pub const recvFromBlocking = system.recvFromBlocking;
pub const sendToBlocking = system.sendToBlocking;
pub const bindSocket = system.bindSocket;
pub const listenSocket = system.listenSocket;
pub const localAddress = system.localAddress;
pub const acceptSocket = system.acceptSocket;
pub const connectSocket = system.connectSocket;
pub const setReuseAddress = system.setReuseAddress;
pub const setSockOpt = system.setSockOpt;
pub const shutdownSend = system.shutdownSend;
pub const shutdownSocket = system.shutdownSocket;
pub const sendMsgBlocking = system.sendMsgBlocking;
pub const recvMsgBlocking = system.recvMsgBlocking;
pub const closeSocket = system.closeSocket;
pub const sendBlocking = system.sendBlocking;
pub const recvBlocking = system.recvBlocking;
pub const tickCount = system.tickCount;
pub const fileSize = system.fileSize;
pub const readFileInto = system.readFileInto;
pub const writeFileAll = system.writeFileAll;
pub const makeDir = system.makeDir;
pub const removeDir = system.removeDir;
pub const rename = system.rename;
pub const symLink = system.symLink;
pub const FileKind = system.FileKind;
pub const Stat = system.Stat;
pub const stat = system.stat;
pub const listDir = system.listDir;
pub const DirEntry = system.DirEntry;
pub const deleteFile = system.deleteFile;
pub const deleteFileChecked = system.deleteFileChecked;
pub const readFileAt = system.readFileAt;
pub const appendFile = system.appendFile;
pub const truncateFile = system.truncateFile;
pub const openFile = system.openFile;
pub const readFileHandle = system.readFileHandle;
pub const writeFileHandle = system.writeFileHandle;
pub const closeFile = system.closeFile;
pub const statFile = system.statFile;
pub const setFileSize = system.setFileSize;
pub const syncFile = system.syncFile;
pub const setFilePermissions = system.setFilePermissions;
pub const setFileOwner = system.setFileOwner;
pub const setFileTimestamps = system.setFileTimestamps;
pub const setPermissions = system.setPermissions;
pub const setOwner = system.setOwner;
pub const setTimestamps = system.setTimestamps;
pub const access = system.access;
pub const realPath = system.realPath;
pub const hardLink = system.hardLink;
pub const readLink = system.readLink;
pub const openDir = system.openDir;
pub const readDirHandle = system.readDirHandle;
pub const closeDir = system.closeDir;
const vtCreateSocket = system.vtCreateSocket;
const vtSetReuseAddress = system.vtSetReuseAddress;
const vtSetSockOpt = system.vtSetSockOpt;
const vtShutdownSend = system.vtShutdownSend;
const vtBind = system.vtBind;
const vtListen = system.vtListen;
const vtFileSize = system.vtFileSize;
const vtReadFileInto = system.vtReadFileInto;
const vtWriteFileAll = system.vtWriteFileAll;
const vtReadFileAt = system.vtReadFileAt;
const vtAppendFile = system.vtAppendFile;
const vtTruncateFile = system.vtTruncateFile;
const vtOpenFile = system.vtOpenFile;
const vtReadFileHandle = system.vtReadFileHandle;
const vtWriteFileHandle = system.vtWriteFileHandle;
const vtCloseFile = system.vtCloseFile;
const vtStatFile = system.vtStatFile;
const vtSetFileSize = system.vtSetFileSize;
const vtSyncFile = system.vtSyncFile;
const vtSetFilePermissions = system.vtSetFilePermissions;
const vtSetFileOwner = system.vtSetFileOwner;
const vtSetFileTimestamps = system.vtSetFileTimestamps;
const vtSetPermissions = system.vtSetPermissions;
const vtSetOwner = system.vtSetOwner;
const vtSetTimestamps = system.vtSetTimestamps;
const vtAccess = system.vtAccess;
const vtRealPath = system.vtRealPath;
const vtHardLink = system.vtHardLink;
const vtReadLink = system.vtReadLink;
const vtOpenDir = system.vtOpenDir;
const vtReadDirHandle = system.vtReadDirHandle;
const vtCloseDir = system.vtCloseDir;
const vtMakeDir = system.vtMakeDir;
const vtRemoveDir = system.vtRemoveDir;
const vtRename = system.vtRename;
const vtSymLink = system.vtSymLink;
const vtStatPath = system.vtStatPath;
const vtListDir = system.vtListDir;
const vtDeleteFile = system.vtDeleteFile;

const Handle = types.Handle;
const INVALID_HANDLE = types.INVALID_HANDLE;

const io_uring_sqe = linux.io_uring_sqe;
const io_uring_params = linux.io_uring_params;
const io_uring_cqe = linux.io_uring_cqe;

/// `create(alloc)` 无配置入口用的默认队列容量，与 `Options.queue_size` 一致。
const DEFAULT_QUEUE_SIZE: u16 = 256;

/// CQ 环相对 SQ 环的倍数。CQ 必须显著大于 SQ：`getSqe` 可能连续提交满
/// 一个 SQ 环，内核立刻产出同样多的完成包；CQ 与 SQ 等大时第一批就填满 CQ。
const CQ_MULTIPLIER: u32 = 8;

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
    /// SQ 环容量（格数）。`getSqe` 用它判断何时必须先 flush。
    sq_entries: u32,
    /// CQ 环容量（格数）。`getSqe` 用它判断何时该提前收割，避免 CQ 满丢包。
    cq_entries: u32,
    /// CQE 溢出暂存：`reapCq` 收满 `refs`、或 `getSqe` 为腾 CQ 空位而提前
    /// 收割时，完成包先搬到这里，下次 `waitBatch` 优先吐出。
    ///
    /// 容量取 CQ 环大小：一次最多腾空一个 CQ 环，不会溢出。**丢了就是回调
    /// 永不触发**，所以宁可放大也不缩。
    /// 配置下来的 SQ 环容量（格数）。CQ 环 = 它 × `CQ_MULTIPLIER`。
    queue_size: u16,

    /// CQE 溢出暂存：`reapCq` 收满 `refs`、或 `getSqe` 为腾 CQ 空位而提前
    /// 收割时，完成包先搬到这里，下次 `waitBatch` 优先吐出。容量 = CQ 环
    /// 大小，在 `createWith` 里按 `queue_size` 堆分配。
    ///
    /// 用环形缓冲（head/tail mod len）而不是移位数组：出队 O(1) 而非 O(n)，
    /// 在大批量提交导致频繁溢出时避免热路径上的线性移位。
    overflow: []types.Ref = undefined,
    overflow_head: usize = 0,
    overflow_tail: usize = 0,
    sqes: [*]io_uring_sqe,

    cq_head: *u32,
    cq_tail: *u32,
    cqes: [*]io_uring_cqe,
    cq_mask: u32,

    sq_pending: u32 = 0,
    /// 诊断计数器：`io_uring_enter` 的调用次数。批量提交是否真生效的唯一
    /// 黑盒证据——曾经每操作一次 eager flush，把它从 50101 修到 1051。
    /// 只做加法，不进任何热路径分支。
    enter_calls: u64 = 0,
    ref: types.Ref = undefined,

    /// 把 CQ 环腾空，完成包搬进 `overflow`。
    ///
    /// `getSqe` 在等 SQ 空位时调用它：CQ 满了内核就不产出完成包，也不推进
    /// SQ head，只等不腾就是死锁。
    fn overflowLen(self: *const State) usize {
        return self.overflow_tail -% self.overflow_head;
    }

    fn overflowPush(self: *State, ref: types.Ref) void {
        if (self.overflowLen() >= self.overflow.len) return; // 满了就丢（不应发生）
        self.overflow[self.overflow_tail % self.overflow.len] = ref;
        self.overflow_tail +%= 1;
    }

    fn overflowPop(self: *State) ?types.Ref {
        if (self.overflow_head == self.overflow_tail) return null;
        const ref = self.overflow[self.overflow_head % self.overflow.len];
        self.overflow_head +%= 1;
        return ref;
    }

    fn pumpCq(self: *State) void {
        while (peekCqe(self)) |cqe| {
            if (cqe.user_data != 0) {
                if (cqe.user_data & FILE_TAG != 0) {
                    const sp: *types.Scratch = @ptrFromInt(cqe.user_data & ~@as(u64, 7));
                    _ = linux.close(takeFd(sp));
                }
                self.overflowPush(fillRef(cqe));
            }
            advanceCq(self);
        }
    }
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
    if (signed(rc) < 0) return sys.fromSyscall(signed(rc));
    return rc;
}

fn cvtFd(rc: usize) !i32 {
    _ = try cvt(rc);
    return @intCast(rc);
}

// ---- 环的初始化 ------------------------------------------------------------

fn setup(state: *State) !void {
    var p: io_uring_params = std.mem.zeroes(io_uring_params);
    // CQ 环要能容下「SQ 满时一次 flush 的全部完成包」，否则内核会因 CQ 满
    // 而停止推进，`io_uring_enter` 阻塞，整个循环卡死。SQ 与 CQ 各 256 是
    // 不够的：一次 flush 提交 256 条，而之前可能已有未收割的完成包。
    // `cq_entries` 必须配 `IORING_SETUP_CQSIZE` 才生效——否则内核**静默忽略**
    // 它，CQ 仍是默认的 `sq_entries` 大小。实测漏掉这个标志时内核回填
    // `cq_entries=512`（= 2×SQ），一次 add 2000 个操作收割停在 512 再也不动。
    p.flags = linux.IORING_SETUP_CQSIZE;
    p.cq_entries = @as(u32, state.queue_size) * CQ_MULTIPLIER;
    const rc = linux.io_uring_setup(state.queue_size, &p);
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
    state.sq_entries = state.sq_mask + 1;
    state.sqes = @ptrCast(@alignCast(state.sqes_map.ptr));

    const cqb = state.cq_map.ptr;
    state.cq_head = @ptrCast(@alignCast(cqb + p.cq_off.head));
    state.cq_tail = @ptrCast(@alignCast(cqb + p.cq_off.tail));
    state.cqes = @ptrCast(@alignCast(cqb + p.cq_off.cqes));
    state.cq_mask = @as(*const u32, @ptrCast(@alignCast(cqb + p.cq_off.ring_mask))).*;
    state.cq_entries = state.cq_mask + 1;

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

/// 取一个 SQE 槽位。
///
/// **两道背压，缺一不可：**
///
/// 1. SQ 环空位（`tail - head < sq_entries`）。环只有 `queue_size` 格，`tail & mask`
///    绕回去会覆写内核还没读走的 SQE。
/// 2. CQ 环空位。CQ 满时内核**停止产生完成包**，连带不再推进 SQ head，于是
///    第 1 条永远等不到空位——死锁。所以这里必须主动收割 CQ。
///
/// 收割到的 `Ref` 进 `early` 队列，由 `waitBatch` 优先吐出。每个 `Ref` 背后
/// 都有一个等着回调的 `Completion`，丢了就是回调永不触发。
///
/// 这两条都是实测逼出来的：一次 `add` 2000 个操作，只做第 1 条时收割停在
/// CQ 容量（512）再也不动，其余操作既不完成也不报错。
/// 把排队的 SQE 交给内核。
///
/// **一次提交量不能超过 SQ 环容量**：`to_submit` 大于环内实际待提交条目时
/// 内核返回 `EINVAL`，那批 SQE 一个都没提交。曾无条件把 `sq_pending` 清零，
/// 超出的部分被当成「已提交」永久丢失。
fn flush(state: *State) void {
    while (state.sq_pending != 0) {
        const chunk = @min(state.sq_pending, state.sq_entries);
        state.enter_calls += 1;
        const rc = linux.io_uring_enter(state.fd, chunk, 0, 0, null);
        const rc_s = signed(rc);
        if (rc_s <= 0) return; // 失败或无进展：留着下次再试
        state.sq_pending -= @intCast(rc_s);
    }
}

fn getSqe(state: *State) *io_uring_sqe {
    // 不在这里提交：`add` 只往 SQ 环里排 SQE，真正提交交给 `waitBatch`
    // 开头的 `flush` 一次性完成。早期版本在这里 eager flush，导致每个操作
    // 各发一次 `io_uring_enter`——实测 25000 次往返产生 50101 次 enter，
    // 批量提交的优势被完全抵消（比 zio 慢 22%）。

    var spins: usize = 0;
    while (true) {
        const head = @atomicLoad(u32, state.sq_head, .acquire);
        const tail = @atomicLoad(u32, state.sq_tail, .monotonic);
        if (tail -% head < state.sq_entries) break;

        // SQ 满：内核还没读走槽位。必须真的把待提交的 SQE 推下去，
        // 否则下面的自旋永远等不到空位（`enter(0,0,GETEVENTS)` 不提交任何
        // SQE）。先 flush 腾出槽位，顺带收一次 CQ。
        flush(state);
        state.pumpCq();
        _ = linux.io_uring_enter(state.fd, 0, 0, linux.IORING_ENTER_GETEVENTS, null);

        spins += 1;
        if (spins > 10000) {
            // 极端情况（内核被饿死）：让出 CPU 再试，不做无限自旋。
            std.Thread.yield() catch {};
            spins = 0;
        }
    }

    const tail = @atomicLoad(u32, state.sq_tail, .monotonic);
    const index = tail & state.sq_mask;
    const sqe = &state.sqes[index];
    sqe.* = std.mem.zeroes(io_uring_sqe);
    state.sq_array[index] = index;
    @atomicStore(u32, state.sq_tail, tail +% 1, .release);
    state.sq_pending += 1;
    return sqe;
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
    alloc.free(state.overflow);
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

fn vtRecv(userdata: ?*anyopaque, socket: Handle, buffer: []u8, scratch: *types.Scratch) anyerror!?usize {
    const state = stateOf(userdata);
    const sqe = getSqe(state);
    sqe.prep_recv(fdOf(socket), buffer, 0);
    sqe.user_data = @intFromPtr(scratch);
    return null;
}

fn vtSend(userdata: ?*anyopaque, socket: Handle, bytes: []const u8, scratch: *types.Scratch) anyerror!?usize {
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
    scratch: *types.Scratch,
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
    scratch: *types.Scratch,
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

/// 分散聚合 I/O 的后端私有状态：`msghdr` + iovec 数组。
///
/// iovec 数组长度取 32：够 HTTP/2 帧头 + 若干段载荷，且与
/// `MSG_HDR_WORDS` 的预算对得上（见下方 comptime 断言）。
const SendMsgHdr = extern struct {
    msg: linux.msghdr_const,
    iov: [IOV_MAX]std.posix.iovec_const,
};

const RecvMsgHdr = extern struct {
    msg: linux.msghdr,
    iov: [IOV_MAX]std.posix.iovec,
};

comptime {
    if (@sizeOf(SendMsgHdr) > completion.MSG_HDR_WORDS * @sizeOf(usize))
        @compileError("SendMsgHdr 超出 hdr 预算");
    if (@sizeOf(RecvMsgHdr) > completion.MSG_HDR_WORDS * @sizeOf(usize))
        @compileError("RecvMsgHdr 超出 hdr 预算");
}

fn vtSendMsg(
    userdata: ?*anyopaque,
    socket: Handle,
    bufs: []const []const u8,
    hdr: []usize,
    scratch: *types.Scratch,
) anyerror!void {
    if (bufs.len == 0) return error.NoBuffers;
    if (bufs.len > IOV_MAX) return error.TooManyBuffers;
    const state = stateOf(userdata);
    const h = udpHdr(SendMsgHdr, hdr);
    for (bufs, 0..) |b, i| h.iov[i] = .{ .base = b.ptr, .len = b.len };
    h.msg = .{
        .name = null,
        .namelen = 0,
        .iov = &h.iov,
        .iovlen = @intCast(bufs.len),
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    const sqe = getSqe(state);
    // 带 MSG_NOSIGNAL：与 `vtSend` 同理，写已半关闭的连接不能把进程杀掉。
    sqe.prep_sendmsg(fdOf(socket), &h.msg, linux.MSG.NOSIGNAL);
    sqe.user_data = @intFromPtr(scratch);
}

fn vtRecvMsg(
    userdata: ?*anyopaque,
    socket: Handle,
    bufs: []const []u8,
    hdr: []usize,
    scratch: *types.Scratch,
) anyerror!void {
    if (bufs.len == 0) return error.NoBuffers;
    if (bufs.len > IOV_MAX) return error.TooManyBuffers;
    const state = stateOf(userdata);
    const h = udpHdr(RecvMsgHdr, hdr);
    for (bufs, 0..) |b, i| h.iov[i] = .{ .base = b.ptr, .len = b.len };
    h.msg = .{
        .name = null,
        .namelen = 0,
        .iov = &h.iov,
        .iovlen = @intCast(bufs.len),
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    const sqe = getSqe(state);
    sqe.prep_recvmsg(fdOf(socket), &h.msg, 0);
    sqe.user_data = @intFromPtr(scratch);
}

fn vtShutdown(userdata: ?*anyopaque, socket: Handle, how: types.ShutdownHow) anyerror!void {
    _ = userdata;
    const flag: i32 = switch (how) {
        .read => linux.SHUT.RD,
        .write => linux.SHUT.WR,
        .both => linux.SHUT.RDWR,
    };
    _ = try cvt(linux.shutdown(fdOf(socket), flag));
}

fn vtClose(userdata: ?*anyopaque, socket: Handle) void {
    _ = userdata;
    _ = linux.close(fdOf(socket));
}

/// 与 `vtClose` 相同的动作，但把 `close(2)` 的 errno 映射成具体错误。
/// `EBADF` 说明句柄已失效（重复关闭 / 被别人关掉），其余归 `CloseFailed`。
fn vtCloseChecked(userdata: ?*anyopaque, socket: Handle) anyerror!void {
    _ = userdata;
    const rc = linux.close(fdOf(socket));
    const rcs = signed(rc);
    if (rcs < 0) return switch (-rcs) {
        @as(isize, @intCast(@backingInt(linux.E.BADF))) => error.NotOpen,
        else => error.CloseFailed,
    };
}

/// 按 user_data 取消一个已提交的 SQE。取消请求自身的 user_data 为 0，
/// `reapCq` 会跳过它的 CQE；原操作随后收到 `-ECANCELED` 完成包。
///
/// `socket == INVALID_HANDLE` 表示该节点不经过 io_uring（`timer` / `work`），
/// 提交 cancel SQE 只会得到 `ENOENT` 再被 `user_data == 0` 路径丢弃，
/// 白白多一次 `io_uring_enter`。直接返回即可。
fn vtCancel(userdata: ?*anyopaque, socket: types.Handle, scratch: *types.Scratch) void {
    if (socket == types.INVALID_HANDLE) return;
    const state = stateOf(userdata);
    const sqe = getSqe(state);
    sqe.prep_cancel(@intFromPtr(scratch), 0);
    sqe.user_data = 0;
    flush(state);
}

fn vtAccept(userdata: ?*anyopaque, listen: Handle, accept_socket: Handle, addr_buf: []u8, scratch: *types.Scratch) anyerror!?usize {
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

fn vtConnect(userdata: ?*anyopaque, socket: Handle, address: net.IpAddress, scratch: *types.Scratch) anyerror!void {
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
fn vtWaitBatch(userdata: ?*anyopaque, timeout_ms: u32, refs: []types.Ref) anyerror!usize {
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
/// 收割 CQE。**即使 `refs` 装满了也必须继续 `advanceCq`**——CQE 留在环里
/// 会让 CQ 逐渐占满，内核随即停止推进，`io_uring_enter` 阻塞，整个循环卡死
/// （实测一次性提交 600 个操作时，只按 `refs.len` 截断会导致 74~82 个操作
/// 永远收不到完成包）。
///
/// 溢出的 CQE 不丢：`Ref` 承载的是 `*Scratch`，而 `Scratch` 属于调用方的
/// 节点，可以安全地在下一次 `waitBatch` 里再收割。这里只是把环腾空。
fn reapCq(state: *State, refs: []types.Ref) usize {
    var n: usize = 0;

    // 先把上次溢出的搬出来（环形缓冲 O(1) 出队）。
    while (n < refs.len) {
        refs[n] = state.overflowPop() orelse break;
        n += 1;
    }
    if (n == refs.len) return n;

    while (peekCqe(state)) |cqe| {
        if (cqe.user_data != 0) {
            if (cqe.user_data & FILE_TAG != 0) {
                const sp: *types.Scratch = @ptrFromInt(cqe.user_data & ~@as(u64, 7));
                _ = linux.close(takeFd(sp));
            }
            const ref = fillRef(cqe);
            if (n < refs.len) {
                refs[n] = ref;
                n += 1;
            } else {
                // 环必须腾空（否则 CQ 满 → 内核停推 → 循环卡死），溢出存起来。
                state.overflowPush(ref);
            }
        }
        advanceCq(state);
    }
    return n;
}

fn fillRef(cqe: *const linux.io_uring_cqe) types.Ref {
    const tagged = cqe.user_data;
    const is_accept = tagged & 1 != 0;
    const is_watch = tagged & 2 != 0;
    // 文件 I/O 的 `res` 直接就是读写字节数，不需要像 `POLL_ADD` 那样翻译。
    const res = cqe.res;
    var bytes: usize = if (res >= 0) @intCast(res) else 0;
    if (is_watch and res >= 0) {
        // `POLL_ADD` 的 `res` 是 poll 掩码，与 `Ready` 位布局不同，必须翻译。
        var r: types.Ready = .{};
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
        .new_handle = if (is_accept and res >= 0) @intCast(res) else types.INVALID_HANDLE,
    };
}

fn vtWatchFd(userdata: ?*anyopaque, fd: Handle, want: types.Ready, scratch: *types.Scratch) anyerror!?void {
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
pub fn vtConnectUnix(userdata: ?*anyopaque, socket: types.Handle, path: []const u8, scratch: *types.Scratch) anyerror!?void {
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
    if (len > @sizeOf(types.Scratch)) return error.NameTooLong;
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
/// 把 fd 记进 `Scratch` 前 4 字节，供 reap 时同步 close。
fn stashFd(scratch: *types.Scratch, fd: linux.fd_t) void {
    std.mem.writeInt(u32, scratch.bytes[0..4], @bitCast(fd), .little);
}

fn takeFd(scratch: *types.Scratch) linux.fd_t {
    return @bitCast(std.mem.readInt(u32, scratch.bytes[0..4], .little));
}

fn vtReadFileAsync(
    userdata: ?*anyopaque,
    path: [*:0]const u8,
    offset: u64,
    buf: []u8,
    scratch: *types.Scratch,
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
    scratch: *types.Scratch,
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

// ---- 零拷贝文件→socket ----------------------------------------------------
//
// Linux 的 `sendfile(2)` 把页缓存直接送进 socket 缓冲，不经用户态。
// 一次调用最多发 `0x7ffff000` 字节（内核单次上限），超出要循环。

fn vtNotify(userdata: ?*anyopaque) void {
    const state = stateOf(userdata);
    var one: u64 = 1;
    _ = linux.write(state.efd, std.mem.asBytes(&one), 8);
}

// ---- 套接字 / 文件辅助操作（经 VTable 暴露给上层） ------------------------

const blocking_net = @import("blocking_net.zig").adapt(system);

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
    .readFileAsync = vtReadFileAsync,
    .writeFileAsync = vtWriteFileAsync,
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

/// 带配置的入口：`queue_size` 决定 SQ 环大小，CQ 环与溢出队列随之缩放。
pub fn createWith(alloc: std.mem.Allocator, opts: io_mod.Options) !io_mod.Io {
    const qs = opts.queue_size;
    const state = try alloc.create(State);
    errdefer alloc.destroy(state);
    const overflow = try alloc.alloc(types.Ref, @as(usize, qs) * CQ_MULTIPLIER);
    errdefer alloc.free(overflow);
    state.* = .{
        .alloc = alloc,
        .queue_size = qs,
        .overflow = overflow,
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
        .sq_entries = 0,
        .cq_entries = 0,
        .overflow_head = 0,
        .overflow_tail = 0,
        .sqes = undefined,
        .cq_head = undefined,
        .cq_tail = undefined,
        .cqes = undefined,
        .cq_mask = 0,
    };
    try setup(state);
    return .{ .userdata = state, .vtable = &vtable_storage };
}

// ---- 测试（在 Linux 运行；已在 WSL 验证） ----------------------------------

/// 这些测试只验 io_uring 后端本身，必须真的用到内核的 io_uring。
/// 在 `io_uring_disabled=1` 或旧内核上 `create` 会失败——那不是 mox 的
/// 缺陷，而是环境不支持，此时跳过。其它错误仍然照常抛出。
fn testLoop() !?loop_mod.Loop {
    const io_value = create(std.testing.allocator) catch |e| switch (e) {
        error.SetupFailed => return null,
        else => return e,
    };
    return loop_mod.Loop.init(io_value);
}

test "io_uring: a timer fires through the loop" {
    const maybe_loop = try testLoop();
    if (maybe_loop == null) return; // 本机没有 io_uring，跳过
    var l = maybe_loop.?;
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

    try l.associate(listener, 0);
    var acc = completion.NetAccept.init(listener, accept_sock);
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

    const Item = struct { work: completion.Work, value: u32 = 0 };
    const Ctx = struct {
        var done = false;
        fn workFn(w: *completion.Work) void {
            const self: *Item = @fieldParentPtr("work", w);
            self.value = 42;
        }
        fn done_cb(lp: *loop_mod.Loop, c: *completion.Completion) void {
            _ = c;
            done = true;
            lp.stop();
        }
    };
    var item: Item = .{ .work = completion.Work.init(&Ctx.workFn) };
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
        fn cb(lp: *loop_mod.Loop, c: *completion.Completion) void {
            const nc: *completion.NetConnect = @fieldParentPtr("c", c);
            nc.getResult() catch {
                lp.stop();
                return;
            };
            ok = true;
            lp.stop();
        }
    };
    var conn = completion.NetConnect.init(client, bound);
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
        fn cb(lp: *loop_mod.Loop, c: *completion.Completion) void {
            _ = c;
            ok = true;
            lp.stop();
        }
    };
    var buf: [64]u8 = undefined;
    var rf = file_mod.ReadFile.init(l.io, path, &buf, null);
    rf.work.c.callback = &Ctx.cb;
    l.add(&rf.work.c);
    try l.run();

    try std.testing.expect(Ctx.ok);
    try std.testing.expectEqualStrings("static-asset-body", try rf.getResult());
}

pub fn ringSizes(userdata: ?*anyopaque) [2]u32 {
    const state = stateOf(userdata);
    return .{ state.sq_entries, state.cq_entries };
}

pub fn enterCalls(userdata: ?*anyopaque) u64 {
    return stateOf(userdata).enter_calls;
}
