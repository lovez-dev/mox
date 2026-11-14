//! UDP 可选能力：通过 `Io.capability` 接入，不改动核心 `VTable` 布局。
//!
//! 本能力的实现走 `Work` 池：UDP 数据报在池线程里用阻塞 `recvfrom` /
//! `sendto` 完成，回调由 `Loop.drainWork` 在循环线程触发。这样三个后端
//! 共用一份平台代码，不需要各自写原生数据报 SQE / OVERLAPPED；
//! 之后若要在某个后端上换成原生异步，只需替换同一 ID 下的函数表，
//! 调用方代码一行都不用改。
//!
//! 扩展新能力的成本 = 一个 `cap("...")` 常量 + 一张函数表 + 一个节点类型，
//! 主 `VTable` 与 `Loop.add` 的热路径完全不动。

const std = @import("std");
const types = @import("types.zig");
const io_mod = @import("io.zig");
const Loop = @import("loop.zig").Loop;
const Work = @import("completion.zig").Work;

const Handle = types.Handle;
const INVALID_HANDLE = types.INVALID_HANDLE;

/// 后端私有存储。`usize` 元素已保证 8 字节对齐，因此不需要额外的对齐声明；
/// `Io.VTable` 的 udp 入口以普通 `[]usize` 接收它。
const HdrStore = [32]usize;
const IpAddress = std.Io.net.IpAddress;

/// 能力 ID。调用方与实现各自在编译期用 `cap` 算出同一个值。
pub const id = types.cap("mox.io.udp.v1");

/// 后端（或通用实现）提供的 UDP 函数表。`userdata` 由 `Udp` 透传。
pub const VTable = struct {
    create: *const fn (userdata: ?*anyopaque, address: IpAddress) anyerror!Handle,
    bind: *const fn (userdata: ?*anyopaque, socket: Handle, address: IpAddress) anyerror!void,
    /// 在池线程里阻塞收一个数据报；`from` 回填发送方原始 sockaddr 字节。
    recvFrom: *const fn (userdata: ?*anyopaque, socket: Handle, buf: []u8, from: []u8) anyerror!usize,
    sendTo: *const fn (userdata: ?*anyopaque, socket: Handle, buf: []const u8, address: IpAddress) anyerror!usize,
    close: *const fn (userdata: ?*anyopaque, socket: Handle) void,
};

/// 调用方缓存的能力句柄。构造一次，之后所有 UDP 操作都走它。
pub const Udp = struct {
    io: io_mod.Io,
    vt: *const VTable,

    /// 取能力；后端不支持时返回 `null`。
    pub fn get(io: io_mod.Io) ?Udp {
        return .{ .io = io, .vt = io.capability(*const VTable, id) orelse return null };
    }

    pub fn create(self: Udp, address: IpAddress) !Handle {
        const s = try self.vt.create(self.io.userdata, address);
        // IOCP 这类后端要求套接字先挂到完成端口，否则完成包永远投不进来。
        // 关联是「每个套接字一次」的动作——对同一 socket 重复关联会被拒绝
        // （ERROR_INVALID_PARAMETER），所以放在创建处而不是每次提交时做。
        // 不需要关联的后端（io_uring）这是空操作；即便失败也不致命，后续
        // 提交会自动降级到线程池，语义仍然正确。
        if (self.io.vtable.udpRecv != null) {
            self.io.vtable.associate(self.io.userdata, s, 0) catch {};
        }
        return s;
    }

    pub fn bind(self: Udp, socket: Handle, address: IpAddress) !void {
        return self.vt.bind(self.io.userdata, socket, address);
    }

    pub fn close(self: Udp, socket: Handle) void {
        self.vt.close(self.io.userdata, socket);
    }

    /// 提交一次接收；完成时 `r.work.c.callback` 在循环线程触发。
    pub fn recv(self: Udp, loop: *Loop, r: *Recv) void {
        r.udp = self;
        const submit = self.io.vtable.udpRecv orelse {
            loop.add(&r.work.c);
            return;
        };
        // 异步路径复用同一个 Completion 作为身份锚点：完成包照样经
        // `Loop.completeOne` 反查回来，回调写法与阻塞路径完全一致。
        r.work.c.op = .udp_recv;
        r.work.c.socket = r.socket;
        submit(self.io.userdata, r.socket, r.buffer, &r.from, &r.hdr, &r.work.c.ov) catch {
            // 提交失败（SQE 耗尽等）：降级为线程池阻塞接收，重试一次。
            // 绝不在调用栈内同步回调，免得调用方还没返回就地重入。
            r.work.c.op = .work;
            r.work.c.socket = INVALID_HANDLE;
            loop.add(&r.work.c);
        };
    }

    /// 提交一次发送。
    pub fn send(self: Udp, loop: *Loop, s: *Send) void {
        s.udp = self;
        const submit = self.io.vtable.udpSend orelse {
            loop.add(&s.work.c);
            return;
        };
        s.work.c.op = .udp_send;
        s.work.c.socket = s.socket;
        submit(self.io.userdata, s.socket, s.buffer, s.address, &s.hdr, &s.work.c.ov) catch {
            s.work.c.op = .work;
            s.work.c.socket = INVALID_HANDLE;
            loop.add(&s.work.c);
        };
    }
};

/// 数据报源地址的字节数。`sockaddr` 头两字节是地址族：`AF_INET` 在两个平台
/// 都是 2，`AF_INET6` 在 Linux 是 10、在 Windows 是 23。异步路径不必让内核
/// 回填长度（`msg_namelen` 落在后端私有存储里），按地址族推导即可。
fn sockaddrLength(from: []const u8) usize {
    if (from.len < 2) return 0;
    const family = std.mem.readInt(u16, from[0..2], .native);
    return switch (family) {
        2 => 16, // AF_INET
        10 => 28, // AF_INET6（Linux）
        23 => 28, // AF_INET6（Windows）
        else => 0,
    };
}

pub const Recv = struct {
    work: Work = .{ .func = run },
    /// 后端私有存储：io_uring 在此放 msghdr + iovec，它们必须活到完成包被
    /// 收割，所以不能放栈上，也塞不进 64 字节的 `Scratch`。
    hdr: HdrStore = std.mem.zeroes(HdrStore),
    socket: Handle = INVALID_HANDLE,
    buffer: []u8 = &.{},
    from: [128]u8 align(8) = undefined,
    from_len: usize = 0,
    udp: Udp = undefined,
    /// 收到的字节数。
    result: ?anyerror!usize = null,

    pub fn init(socket: Handle, buffer: []u8) Recv {
        return .{ .socket = socket, .buffer = buffer };
    }

    fn run(w: *Work) void {
        const self: *Recv = @fieldParentPtr("work", w);
        self.result = self.udp.vt.recvFrom(
            self.udp.io.userdata,
            self.socket,
            self.buffer,
            &self.from,
        );
    }

    /// 收到的字节数。异步路径从完成节点取值，源地址长度按 sockaddr 族推导；
    /// 阻塞路径用后端回填的 `from_len`。两条路径对外语义一致。
    pub fn getResult(self: *Recv) !usize {
        if (self.work.c.op == .udp_recv) {
            if (self.work.c.err) |e| return e;
            self.from_len = sockaddrLength(self.from[0..]);
            return self.work.c.bytes;
        }
        return self.result orelse error.NotReady;
    }
};

pub const Send = struct {
    work: Work = .{ .func = run },
    /// 后端私有存储：io_uring 在此放 msghdr + iovec + sockaddr。
    hdr: HdrStore = std.mem.zeroes(HdrStore),
    socket: Handle = INVALID_HANDLE,
    buffer: []const u8 = &.{},
    address: IpAddress = undefined,
    udp: Udp = undefined,
    result: ?anyerror!usize = null,

    pub fn init(socket: Handle, buffer: []const u8, address: IpAddress) Send {
        return .{ .socket = socket, .buffer = buffer, .address = address };
    }

    fn run(w: *Work) void {
        const self: *Send = @fieldParentPtr("work", w);
        self.result = self.udp.vt.sendTo(
            self.udp.io.userdata,
            self.socket,
            self.buffer,
            self.address,
        );
    }

    /// 发送的字节数（数据报要么整发要么失败，正常等于缓冲区长度）。
    pub fn getResult(self: *Send) !usize {
        if (self.work.c.op == .udp_send) {
            if (self.work.c.err) |e| return e;
            return self.work.c.bytes;
        }
        return self.result orelse error.NotReady;
    }
};

test "能力 ID 稳定且不同名字不冲突" {
    try std.testing.expect(id != types.cap("mox.io.dns.v1"));
    try std.testing.expectEqual(id, types.cap("mox.io.udp.v1"));
}
