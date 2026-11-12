//! 精简的 Win32 套接字 + IOCP 接口层，供 `IocpIo` 后端使用。
//!
//! 为什么必须有这个文件：
//!
//! * Zig 0.17 的 `std.os.windows.ws2_32` 只是常量桩：没有声明
//! `WSASocketW`、`WSARecv`、`CreateIoCompletionPort`，std 里
//! 也根本没有任何 IOCP 绑定。
//! * `std.Io.Threaded` 在 Windows 上确实能建套接字，但开的是裸
//! AFD 设备句柄（对 `\Device\Afd\Endpoint` 调 `NtCreateFile`）。
//! 它们不是 winsock 套接字：对其调 `WSARecv` 会报
//! `WSAENOTSOCK`，调 `NtReadFile` 会报 `INVALID_PARAMETER`。
//! 因此后端无法借用 Threaded 的套接字再用 IOCP 驱动。
//!
//! 唯一可行的路线是后端自己完整持有套接字层，
//! 这正是本模块提供的。这里的每条声明都
//! 在真实 Windows 套接字上验证过。

const std = @import("std");
const windows = std.os.windows;
const net = std.Io.net;

pub const HANDLE = windows.HANDLE;

/// winsock 的 `SOCKET` 是 `UINT_PTR`；Zig 的 `net.Socket.Handle` 在
/// Windows 上是 `*anyopaque`，两者可无损互转。
pub const SOCKET = usize;
pub const INVALID_SOCKET: SOCKET = std.math.maxInt(SOCKET);

/// `WSAGetLastError` 的值，含义是「操作正在进行中」。
pub const WSA_IO_PENDING = 997;

/// 超时时 `GetQueuedCompletionStatus` 返回的 `GetLastError` 值。
const WAIT_TIMEOUT = 258;

pub const AF_INET = 2;
pub const AF_INET6 = 23;
pub const SOCK_STREAM = 1;
pub const IPPROTO_TCP = 6;
pub const SOCK_DGRAM = 2;
pub const IPPROTO_UDP = 17;

/// 任何要走重叠 I/O 的套接字都必须带此标志。
pub const WSA_FLAG_OVERLAPPED = 1;

pub const SD_RECEIVE = 0;
pub const SD_SEND = 1;
pub const SD_BOTH = 2;

/// Winsock 的套接字选项常量。std 的 `std.os.windows.ws2_32` 只给了
/// `IPPROTO`，`SO_*` / `TCP_*` 没导出，所以在这里按 Windows SDK 的定义补上
/// —— 数值不能借用 Linux 的，两家同名不同值。
pub const SOL_SOCKET_OPT: c_int = 0xffff;
pub const SO_RCVBUF_OPT: c_int = 0x1002;
pub const SO_SNDBUF_OPT: c_int = 0x1001;
pub const TCP_NODELAY_OPT: c_int = 0x0001;
pub const TCP_KEEPIDLE_OPT: c_int = 0x0003;

pub const ERROR_SUCCESS: c_int = 0;

/// IOCP 在完成包里交回的 `OVERLAPPED` 结构。
/// `_OVERLAPPED` 的镜像；匿名联合对应 offset / pointer 的叠放。
pub const OVERLAPPED = extern struct {
    Internal: usize = 0,
    InternalHigh: usize = 0,
    Anonymous: extern union {
        Anonymous: extern struct { Offset: u32, OffsetHigh: u32 },
        Pointer: ?*anyopaque,
    },
    hEvent: ?HANDLE = null,

    pub fn init() OVERLAPPED {
        return .{ .Anonymous = .{ .Pointer = null } };
    }
};

pub const WSABUF = extern struct {
    len: u32,
    buf: [*]u8,
};

pub const sockaddr_in = extern struct {
    family: u16,
    port: u16,
    addr: [4]u8,
    zero: [8]u8,
};

pub const sockaddr_in6 = extern struct {
    family: u16,
    port: u16,
    flowinfo: u32,
    addr: [16]u8,
    scope_id: u32,
};

/// 足够容纳所有 `sockaddr` 变体，包括 `sockaddr_storage`。
pub const SockAddr = extern struct {
    storage: [128]u8 align(8) = @splat(0),

    pub fn len(self: *const SockAddr) c_int {
        const family: u16 = @bitCast(self.storage[0..2].*);
        return switch (family) {
            AF_INET => @sizeOf(sockaddr_in),
            AF_INET6 => @sizeOf(sockaddr_in6),
            else => @sizeOf(SockAddr),
        };
    }

    pub fn port(self: *const SockAddr) u16 {
        const in: *const sockaddr_in = @ptrCast(&self.storage);
        return std.mem.bigToNative(u16, in.port);
    }
};

/// 把 std 的 `IpAddress` 转成 ws2_32 期望的线上 `sockaddr` 布局。
pub fn toSockAddr(address: net.IpAddress) SockAddr {
    var out: SockAddr = .{};
    switch (address) {
        .ip4 => |a| {
            const in: *sockaddr_in = @ptrCast(&out.storage);
            in.* = .{
                .family = AF_INET,
                .port = std.mem.nativeToBig(u16, a.port),
                .addr = a.bytes,
                .zero = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
            };
        },
        .ip6 => |a| {
            const in: *sockaddr_in6 = @ptrCast(&out.storage);
            in.* = .{
                .family = AF_INET6,
                .port = std.mem.nativeToBig(u16, a.port),
                .flowinfo = 0,
                .addr = a.bytes,
                .scope_id = 0,
            };
        },
    }
    return out;
}

pub fn fromSockAddr(addr: *const SockAddr) net.IpAddress {
    const family: u16 = @bitCast(addr.storage[0..2].*);
    switch (family) {
        AF_INET => {
            const in: *const sockaddr_in = @ptrCast(&addr.storage);
            return .{ .ip4 = .{
                .bytes = in.addr,
                .port = std.mem.bigToNative(u16, in.port),
            } };
        },
        else => {
            const in: *const sockaddr_in6 = @ptrCast(&addr.storage);
            return .{ .ip6 = .{
                .bytes = in.addr,
                .port = std.mem.bigToNative(u16, in.port),
            } };
        },
    }
}

/// 裸导入，放在独立命名空间里，避免其 C 名称与
/// 本模块自身的函数冲突。
const c = struct {
    extern "ws2_32" fn WSAStartup(version: u16, data: *anyopaque) callconv(.winapi) c_int;
    extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;
    extern "ws2_32" fn WSASocketW(af: c_int, kind: c_int, protocol: c_int, info: ?*anyopaque, group: u32, flags: u32) callconv(.winapi) SOCKET;
    extern "ws2_32" fn bind(s: SOCKET, name: *const anyopaque, namelen: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn listen(s: SOCKET, backlog: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn accept(s: SOCKET, addr: ?*anyopaque, addrlen: ?*c_int) callconv(.winapi) SOCKET;
    extern "ws2_32" fn connect(s: SOCKET, name: *const anyopaque, namelen: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn getsockname(s: SOCKET, name: *anyopaque, namelen: *c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn setsockopt(s: SOCKET, level: c_int, optname: c_int, optval: *const anyopaque, optlen: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn shutdown(s: SOCKET, how: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) c_int;
    extern "ws2_32" fn WSARecv(s: SOCKET, buffers: [*]WSABUF, count: u32, bytes_recvd: ?*u32, flags: *u32, overlapped: *OVERLAPPED, routine: ?*anyopaque) callconv(.winapi) c_int;
    extern "ws2_32" fn WSASend(s: SOCKET, buffers: [*]WSABUF, count: u32, bytes_sent: ?*u32, flags: u32, overlapped: *OVERLAPPED, routine: ?*anyopaque) callconv(.winapi) c_int;
    extern "ws2_32" fn WSARecvFrom(s: SOCKET, buffers: [*]WSABUF, count: u32, bytes_recvd: ?*u32, flags: *u32, from: ?*anyopaque, from_len: ?*c_int, overlapped: *OVERLAPPED, routine: ?*anyopaque) callconv(.winapi) c_int;
    extern "ws2_32" fn WSASendTo(s: SOCKET, buffers: [*]WSABUF, count: u32, bytes_sent: ?*u32, flags: u32, to: *const anyopaque, to_len: c_int, overlapped: *OVERLAPPED, routine: ?*anyopaque) callconv(.winapi) c_int;
    extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn recvfrom(s: SOCKET, buf: [*]u8, len: c_int, flags: c_int, from: ?*anyopaque, fromlen: ?*c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn sendto(s: SOCKET, buf: [*]const u8, len: c_int, flags: c_int, to: *const anyopaque, tolen: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: c_int, flags: c_int) callconv(.winapi) c_int;

    extern "kernel32" fn CreateIoCompletionPort(file_handle: usize, existing: ?HANDLE, key: usize, threads: u32) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn GetQueuedCompletionStatus(port: HANDLE, bytes: *u32, key: *usize, overlapped: *?*anyopaque, ms: u32) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn PostQueuedCompletionStatus(port: HANDLE, bytes: u32, key: usize, overlapped: ?*anyopaque) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn CancelIoEx(file_handle: HANDLE, overlapped: ?*anyopaque) callconv(.winapi) windows.BOOL;
    /// IOCP 批量收割条目。字段顺序与 Win32 `OVERLAPPED_ENTRY` 一致。
    pub const OVERLAPPED_ENTRY = extern struct {
        completion_key: usize,
        overlapped: ?*anyopaque,
        internal: usize,
        bytes: u32,
    };
    extern "kernel32" fn GetQueuedCompletionStatusEx(
        port: HANDLE,
        entries: [*]OVERLAPPED_ENTRY,
        count: u32,
        removed: *u32,
        ms: u32,
        alertable: windows.BOOL,
    ) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
    extern "kernel32" fn GetFileTime(h: HANDLE, creation: ?*windows.FILETIME, access: ?*windows.FILETIME, write: ?*windows.FILETIME) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn CreateSymbolicLinkW(link: [*]const u16, target: [*]const u16, flags: u32) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn FindFirstFileW(name: [*]const u16, data: *WIN32_FIND_DATAW) callconv(.winapi) HANDLE;
    extern "kernel32" fn FindNextFileW(h: HANDLE, data: *WIN32_FIND_DATAW) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn FindClose(h: HANDLE) callconv(.winapi) windows.BOOL;
};

var started: std.atomic.Value(bool) = .init(false);

/// 初始化 ws2_32，必须先于本文件其余任何函数调用。
///
/// `std.Io.Threaded` 从不调用它——它经 AFD 完全绕开了 ws2_32；
/// 在我们自己调用之前，每个 ws2_32 入口都会报
/// `WSANOTINITIALISED`(10093)。可重复调用，安全。
pub fn startup() !void {
    if (started.swap(true, .acquire)) return;

    // x64 上 WSADATA 是 408 字节；宁可多分配，也不去镜像它的结构。
    var wsadata: [512]u8 align(8) = undefined;
    const rc = c.WSAStartup(0x0202, &wsadata);
    if (rc != ERROR_SUCCESS) {
        started.store(false, .release);
        return error.WsaStartupFailed;
    }
}

pub fn lastError() c_int {
    return c.WSAGetLastError();
}

pub const SocketError = error{
    SocketCreationFailed,
    BindFailed,
    ListenFailed,
    AcceptFailed,
    ConnectFailed,
    OptionFailed,
    ShutdownFailed,
    RequestFailed,
    Unexpected,
};

pub fn createSocket(family: c_int, kind: c_int, protocol: c_int) SocketError!SOCKET {
    const s = c.WSASocketW(family, kind, protocol, null, 0, WSA_FLAG_OVERLAPPED);
    if (s == INVALID_SOCKET) return error.SocketCreationFailed;
    return s;
}

/// 创建一个与 `address` 同地址族的 TCP 套接字。
pub fn createTcpSocket(address: net.IpAddress) SocketError!SOCKET {
    const family: c_int = switch (address) {
        .ip4 => AF_INET,
        .ip6 => AF_INET6,
    };
    return createSocket(family, SOCK_STREAM, IPPROTO_TCP);
}

/// UDP 能力用的阻塞数据报 helper；在 `Work` 池线程里调用，不占完成端口。
pub fn createUdpSocket(address: net.IpAddress) SocketError!SOCKET {
    const family: c_int = switch (address) {
        .ip4 => AF_INET,
        .ip6 => AF_INET6,
    };
    return createSocket(family, SOCK_DGRAM, IPPROTO_UDP);
}

pub fn recvFromBlocking(s: SOCKET, buf: []u8, from: []u8) SocketError!usize {
    var len: c_int = @intCast(from.len);
    const rc = c.recvfrom(s, buf.ptr, @intCast(buf.len), 0, @ptrCast(from.ptr), &len);
    if (rc < 0) return error.RequestFailed;
    return @intCast(rc);
}

pub fn sendToBlocking(s: SOCKET, buf: []const u8, address: net.IpAddress) SocketError!usize {
    const addr = toSockAddr(address);
    const rc = c.sendto(s, buf.ptr, @intCast(buf.len), 0, &addr, addr.len());
    if (rc < 0) return error.RequestFailed;
    return @intCast(rc);
}

pub fn bindSocket(s: SOCKET, address: net.IpAddress) SocketError!void {
    const addr = toSockAddr(address);
    if (c.bind(s, &addr, addr.len()) != ERROR_SUCCESS) return error.BindFailed;
}

pub fn listenSocket(s: SOCKET, backlog: c_int) SocketError!void {
    if (c.listen(s, backlog) != ERROR_SUCCESS) return error.ListenFailed;
}

pub fn localAddress(s: SOCKET) SocketError!net.IpAddress {
    var addr: SockAddr = .{};
    var len: c_int = @sizeOf(SockAddr);
    if (c.getsockname(s, &addr, &len) != ERROR_SUCCESS) return error.RequestFailed;
    return fromSockAddr(&addr);
}

/// 接受一个连接，会阻塞调用线程；改成重叠的
/// `AcceptEx` 操作是本后端接下来的工作。
pub fn acceptSocket(s: SOCKET) SocketError!struct { socket: SOCKET, address: net.IpAddress } {
    var addr: SockAddr = .{};
    var len: c_int = @sizeOf(SockAddr);
    const peer = c.accept(s, &addr, &len);
    if (peer == INVALID_SOCKET) return error.AcceptFailed;
    return .{ .socket = peer, .address = fromSockAddr(&addr) };
}

pub fn connectSocket(s: SOCKET, address: net.IpAddress) SocketError!void {
    const addr = toSockAddr(address);
    if (c.connect(s, &addr, addr.len()) != ERROR_SUCCESS) return error.ConnectFailed;
}

/// `reuse_address` 对应 `SO_REUSEADDR`。
pub fn setReuseAddress(s: SOCKET, on: bool) SocketError!void {
    const value: c_int = if (on) 1 else 0;
    if (c.setsockopt(s, 0xFFFF, 0x0004, &value, @sizeOf(c_int)) != ERROR_SUCCESS)
        return error.OptionFailed;
}

pub fn shutdownSocket(s: SOCKET, how: c_int) void {
    _ = c.shutdown(s, how);
}

/// 语义选项 → Winsock `setsockopt`。数值用 Windows SDK 的常量，不借用
/// Linux 的编号 —— 两边名字像，取值并不通用。
pub fn setSockOpt(s: SOCKET, opt: root.SockOpt, value: u32) SocketError!void {
    const v: c_int = @intCast(value);
    const len: c_int = @sizeOf(c_int);
    const level: c_int, const name: c_int = switch (opt) {
        .tcp_nodelay => .{ IPPROTO_TCP, TCP_NODELAY_OPT },
        .keepalive_idle => .{ IPPROTO_TCP, TCP_KEEPIDLE_OPT },
        .recv_buf => .{ SOL_SOCKET_OPT, SO_RCVBUF_OPT },
        .send_buf => .{ SOL_SOCKET_OPT, SO_SNDBUF_OPT },
    };
    if (c.setsockopt(s, level, name, &v, len) != ERROR_SUCCESS) return error.OptionFailed;
}

/// 只关发送方向（`SD_SEND`）。与 `closeSocket` 的完全终止不同，
/// 对端仍能把我们已发出的数据读完。
pub fn shutdownSend(s: SOCKET) SocketError!void {
    if (c.shutdown(s, SD_SEND) != ERROR_SUCCESS) return error.ShutdownFailed;
}

pub fn closeSocket(s: SOCKET) void {
    _ = c.closesocket(s);
}

/// 一个 I/O 完成端口，以及汇入其中的操作。
pub const CompletionPort = struct {
    handle: HANDLE,

    pub fn init() SocketError!CompletionPort {
        // 传 INVALID_HANDLE_VALUE 作为文件句柄会新建一个端口，
        // 而不是关联到已有端口。
        const handle = c.CreateIoCompletionPort(INVALID_SOCKET, null, 0, 0) orelse
            return error.RequestFailed;
        return .{ .handle = handle };
    }

    pub fn deinit(self: CompletionPort) void {
        _ = c.CloseHandle(self.handle);
    }

    /// 唤醒阻塞在 `wait` 里的线程（由 `Work` 池线程调用）。
    pub fn notify(self: CompletionPort) void {
        _ = c.PostQueuedCompletionStatus(self.handle, 0, 0, null);
    }

    /// 把 `socket` 的所有完成包路由到本端口。`key` 会随每个完成包
    /// 一并交回，后端据此找回该套接字的状态。
    pub fn associate(self: CompletionPort, socket: SOCKET, key: usize) SocketError!void {
        const handle = c.CreateIoCompletionPort(socket, self.handle, key, 0) orelse
            return error.RequestFailed;
        // 每个端口都会把自身交回，所以这里只做一致性校验，
        // 不需要额外保存句柄。
        std.debug.assert(handle == self.handle);
    }

    pub const Completion = struct {
        bytes: u32,
        key: usize,
        overlapped: *OVERLAPPED,
        /// 操作本身失败（例如对端重置连接）时为真。
        /// 干净的「0 字节完成」（流结束）保持为假，
        /// 调用方据此区分「正常关闭」与「出错」。
        failed: bool = false,
    };

    /// 等待一个完成包，超时返回 null。
    pub fn wait(self: CompletionPort, timeout_ms: u32) SocketError!?Completion {
        var bytes: u32 = 0;
        var key: usize = 0;
        var overlapped: ?*anyopaque = null;
        const ok = c.GetQueuedCompletionStatus(self.handle, &bytes, &key, &overlapped, timeout_ms);
        const ok_bool = ok.toBool();
        if (overlapped == null) {
            // 超时、唤醒信号（PostQueuedCompletionStatus 传空
            // OVERLAPPED）、或端口已关闭——这些都不携带完成包。
            if (!ok_bool and c.GetLastError() != WAIT_TIMEOUT) return error.RequestFailed;
            return null;
        }
        return .{
            .bytes = bytes,
            .key = key,
            .overlapped = @ptrCast(@alignCast(overlapped.?)),
            .failed = !ok_bool,
        };
    }

    /// 阻塞直到携带 `overlapped` 的完成包到达。共享同一端口的
    /// 其它套接字可能先完成，因此跳过所有不匹配的包。
    pub fn waitFor(self: CompletionPort, overlapped: *OVERLAPPED) SocketError!u32 {
        while (true) {
            const completion = try self.wait(std.math.maxInt(u32)) orelse continue;
            if (completion.overlapped == overlapped) return completion.bytes;
        }
    }
};

/// 发起一次重叠接收并等待其完成，返回读到的字节数；
/// 0 表示流正常结束。
///
/// 注意：`WSARecv` 的 `lpFlags` 参数不能为 null；传 null 会在
/// 当前 Windows 的 `mswsock.dll` 内部触发空指针解引用。
pub fn recv(port: CompletionPort, s: SOCKET, buffer: []u8) SocketError!usize {
    var wsabuf = [1]WSABUF{.{ .len = @intCast(buffer.len), .buf = buffer.ptr }};
    var overlapped = OVERLAPPED.init();
    var flags: u32 = 0;
    var bytes: u32 = 0;

    const rc = c.WSARecv(s, &wsabuf, 1, &bytes, &flags, &overlapped, null);
    if (rc == 0) return @intCast(bytes);
    if (lastError() != WSA_IO_PENDING) return error.RequestFailed;
    return @intCast(try port.waitFor(&overlapped));
}

/// 发起一次重叠发送并等待其完成。
pub fn send(port: CompletionPort, s: SOCKET, bytes_to_send: []const u8) SocketError!usize {
    var wsabuf = [1]WSABUF{.{ .len = @intCast(bytes_to_send.len), .buf = @constCast(bytes_to_send.ptr) }};
    var overlapped = OVERLAPPED.init();
    var bytes: u32 = 0;

    const rc = c.WSASend(s, &wsabuf, 1, &bytes, 0, &overlapped, null);
    if (rc == 0) return @intCast(bytes);
    if (lastError() != WSA_IO_PENDING) return error.RequestFailed;
    return @intCast(try port.waitFor(&overlapped));
}

test "listen, connect, accept and exchange data through an IOCP" {
    try startup();

    const port = try CompletionPort.init();
    defer port.deinit();

    // 客户端在另一个线程写入，所以给它独立端口，
    // 免得与服务端端口上的接收争抢完成包。
    const client_port = try CompletionPort.init();
    defer client_port.deinit();

    const loopback = try net.IpAddress.parse("127.0.0.1", 0);

    const listener = try createTcpSocket(loopback);
    defer closeSocket(listener);

    try setReuseAddress(listener, true);
    try bindSocket(listener, loopback);
    try listenSocket(listener, 128);

    const bound = try localAddress(listener);
    try std.testing.expect(bound.getPort() != 0);

    const client = try createTcpSocket(bound);
    defer closeSocket(client);
    try connectSocket(client, bound);
    try client_port.associate(client, 1);

    const accepted = try acceptSocket(listener);
    defer closeSocket(accepted.socket);
    try port.associate(accepted.socket, 7);

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const sender = try std.Thread.spawn(.{}, struct {
        fn run(p: CompletionPort, s: SOCKET, i: std.Io) void {
            // 稍作延迟，确保下面的接收真的处于「未完成」状态，
            // 而不是就地同步完成。
            std.Io.sleep(i, .fromMilliseconds(200), .awake) catch {};
            _ = send(p, s, "ping") catch {};
        }
    }.run, .{ client_port, client, io });

    var buffer: [16]u8 = undefined;
    const read = try recv(port, accepted.socket, &buffer);
    std.debug.print("iocp test: read {d} bytes \"{s}\"\n", .{ read, buffer[0..read] });

    try std.testing.expectEqualStrings("ping", buffer[0..read]);

    const echoed = try send(port, accepted.socket, buffer[0..read]);
    try std.testing.expectEqual(@as(usize, 4), echoed);

    sender.join();
}

// ---- 回调循环原语 ----------------------------------------------------------
//
// 上面的阻塞辅助函数（`recv`/`send`）自己等完成包，
// 对事件循环没用。下面这些发起同样的重叠操作，
// 但交回由调用方持有的 OVERLAPPED 而不等待，让循环
// 稍后投递完成。

const k32 = struct {
    extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
};

/// 单调毫秒时钟；开销小到每轮循环调用一次也无妨。
/// 阻塞接收，仅用于测试 / benchmark 的客户端线程。
pub fn recvBlocking(s: SOCKET, buf: []u8) SocketError!usize {
    const rc = c.recv(s, buf.ptr, @intCast(buf.len), 0);
    if (rc < 0) return error.RequestFailed;
    return @intCast(rc);
}

pub fn tickCount() u64 {
    return k32.GetTickCount64();
}

/// 发起一次重叠接收。返回 `null` 表示操作尚未完成——
/// 完成端口会针对 `overlapped` 投递完成包。同步完成时返回
/// 字节数（0 表示对端关闭）。`overlapped` 在处理完成前
/// 必须保持存活且唯一。
pub fn recvInto(s: SOCKET, wsabuf: [*]WSABUF, overlapped: *OVERLAPPED) SocketError!?usize {
    var flags: u32 = 0;
    var bytes: u32 = 0;
    const rc = c.WSARecv(s, wsabuf, 1, &bytes, &flags, overlapped, null);
    // 即便此处返回 0，完成端口仍会为重叠操作排队一个包，
    // 所以「成功」是「已提交」而非「已完成」——一律按未完成上报。
    if (rc == 0) return null;
    if (lastError() != WSA_IO_PENDING) return error.RequestFailed;
    return null;
}

/// 发起一次重叠发送，契约同 `recvInto`。
pub fn sendFrom(s: SOCKET, wsabuf: [*]WSABUF, overlapped: *OVERLAPPED) SocketError!?usize {
    var bytes: u32 = 0;
    const rc = c.WSASend(s, wsabuf, 1, &bytes, 0, overlapped, null);
    if (rc == 0) return null; // completion packet is still queued
    if (lastError() != WSA_IO_PENDING) return error.RequestFailed;
    return null;
}

/// 普通阻塞发送，供不跑在循环上的测试与一次性辅助函数使用
/// （没有 OVERLAPPED 可投递）。
pub fn sendBlocking(s: SOCKET, bytes_to_send: []const u8) SocketError!usize {
    const rc = c.send(s, bytes_to_send.ptr, @intCast(bytes_to_send.len), 0);
    if (rc < 0) return error.RequestFailed;
    return @intCast(rc);
}

// ---- 异步接受（AcceptEx） --------------------------------------------------
//
// `accept` 会阻塞。AcceptEx 是重叠版本：接收一个你已
// 预先建好的 socket，对端连上后完成，因此能和别的操作一样
// 挂在完成端口上。

const wsa = struct {
    extern "ws2_32" fn WSAIoctl(
        s: SOCKET,
        code: u32,
        in_buf: *anyopaque,
        in_len: u32,
        out_buf: *anyopaque,
        out_len: u32,
        bytes: *u32,
        overlapped: ?*anyopaque,
        routine: ?*anyopaque,
    ) callconv(.winapi) c_int;
};

const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

/// 用于定位 mswsock.dll 里的 AcceptEx 扩展。
const WSAID_ACCEPTEX = GUID{
    .Data1 = 0xb5367df1,
    .Data2 = 0xcbac,
    .Data3 = 0x11cf,
    .Data4 = .{ 0x95, 0xca, 0x00, 0x80, 0x5f, 0x48, 0xa1, 0x92 },
};

const SIO_GET_EXTENSION_FUNCTION_POINTER: u32 = 0xC8000006;
const SOL_SOCKET: c_int = 0xffff;
/// 把 AcceptEx 接受的套接字属性回写到句柄，使
/// getsockname/getpeername/setsockopt 能正常作用于它。
const SO_UPDATE_ACCEPT_CONTEXT: c_int = 0x700B;

pub const AcceptExFn = *const fn (
    listen: SOCKET,
    accept: SOCKET,
    buf: *anyopaque,
    recv_len: u32,
    local_len: u32,
    remote_len: u32,
    bytes: *u32,
    overlapped: *OVERLAPPED,
) callconv(.winapi) c_int;

fn acceptExFn(listen: SOCKET) SocketError!AcceptExFn {
    var fn_ptr: AcceptExFn = undefined;
    var bytes: u32 = 0;
    const rc = wsa.WSAIoctl(
        listen,
        SIO_GET_EXTENSION_FUNCTION_POINTER,
        @ptrCast(@constCast(&WSAID_ACCEPTEX)),
        @sizeOf(GUID),
        @ptrCast(&fn_ptr),
        @sizeOf(AcceptExFn),
        &bytes,
        null,
        null,
    );
    if (rc != 0) return error.RequestFailed;
    return fn_ptr;
}

/// 发起一次重叠接受。`accept` 必须是与监听套接字同族、
/// 新建且未绑定的 socket；`buf` 接收本端+对端地址，长度必须
/// 至少为 `2 * (sizeof(sockaddr_in6) + 16)`。未完成时返回 `null`。
pub fn acceptEx(listen: SOCKET, accept: SOCKET, buf: []u8, overlapped: *OVERLAPPED) SocketError!?usize {
    const f = try acceptExFn(listen);
    const addr_len: u32 = @intCast(buf.len / 2);
    var bytes: u32 = 0;
    const rc = f(listen, accept, buf.ptr, 0, addr_len, addr_len, &bytes, overlapped);
    if (rc != 0) return null; // completion packet is still queued
    if (lastError() != WSA_IO_PENDING) return error.RequestFailed;
    return null;
}

/// 让已接受的套接字可被 getsockname/getpeername/setsockopt 使用。
/// 在 AcceptEx 报成功后、使用该套接字之前调用一次。
pub fn updateAcceptContext(listen: SOCKET, accept: SOCKET) void {
    _ = c.setsockopt(accept, SOL_SOCKET, SO_UPDATE_ACCEPT_CONTEXT, @ptrCast(&listen), @sizeOf(SOCKET));
}

// ---- 异步连接（ConnectEx） -------------------------------------------------

const WSAID_CONNECTEX = GUID{
    .Data1 = 0x25a207b9,
    .Data2 = 0xddf3,
    .Data3 = 0x4660,
    .Data4 = .{ 0x8e, 0xe9, 0x76, 0xe5, 0x8c, 0x74, 0x06, 0x3e },
};
/// 把 ConnectEx 套接字的属性回写到句柄。
const SO_UPDATE_CONNECT_CONTEXT: c_int = 0x7010;

const ConnectExFn = *const fn (
    s: SOCKET,
    name: *const anyopaque,
    namelen: c_int,
    send_buffer: ?*anyopaque,
    send_len: u32,
    bytes_sent: *u32,
    overlapped: *OVERLAPPED,
) callconv(.winapi) c_int;

fn connectExFn(s: SOCKET) SocketError!ConnectExFn {
    var fn_ptr: ConnectExFn = undefined;
    var bytes: u32 = 0;
    const rc = wsa.WSAIoctl(
        s,
        SIO_GET_EXTENSION_FUNCTION_POINTER,
        @ptrCast(@constCast(&WSAID_CONNECTEX)),
        @sizeOf(GUID),
        @ptrCast(&fn_ptr),
        @sizeOf(ConnectExFn),
        &bytes,
        null,
        null,
    );
    if (rc != 0) return error.RequestFailed;
    return fn_ptr;
}

/// 发起一次重叠连接。先绑定到通配本端地址，
/// 因为 ConnectEx 要求如此。未完成时返回 `null`。
pub fn connectEx(s: SOCKET, address: net.IpAddress, overlapped: *OVERLAPPED) SocketError!?usize {
    const any: net.IpAddress = switch (address) {
        .ip4 => .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } },
        .ip6 => .{ .ip6 = .{ .bytes = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .port = 0 } },
    };
    try bindSocket(s, any);
    const f = try connectExFn(s);
    const addr = toSockAddr(address);
    var bytes: u32 = 0;
    const rc = f(s, &addr, addr.len(), null, 0, &bytes, overlapped);
    if (rc != 0) return null; // success; completion packet is still queued
    if (lastError() != WSA_IO_PENDING) return error.RequestFailed;
    return null;
}

pub fn updateConnectContext(s: SOCKET) void {
    var dummy: u8 = 0;
    _ = c.setsockopt(s, SOL_SOCKET, SO_UPDATE_CONNECT_CONTEXT, @ptrCast(&dummy), 0);
}

// ---- Io 接口接线 -----------------------------------------------------------
//
// 上面是裸 Win32/IOCP 接口，下面把它映射到与平台无关的 `root.Io`，
// 使 `root.zig`（进而整个框架）永远看不到 Windows 类型。本文件即完整的 Windows 后端。
const root = @import("../io.zig");

/// `Io.userdata` 背后的后端状态：完成端口 + 持有它的分配器。
const State = struct {
    alloc: std.mem.Allocator,
    port: CompletionPort,
};

fn stateOf(userdata: ?*anyopaque) *State {
    return @ptrCast(@alignCast(userdata.?));
}

fn vtDeinit(userdata: ?*anyopaque) void {
    const st = stateOf(userdata);
    st.port.deinit();
    st.alloc.destroy(st);
}

fn vtNow(userdata: ?*anyopaque) u64 {
    _ = userdata;
    return tickCount();
}

fn vtAssociate(userdata: ?*anyopaque, socket: root.Handle, key: usize) anyerror!void {
    try stateOf(userdata).port.associate(socket, key);
}

/// 64 字节的 `root.Scratch` 里先放 `OVERLAPPED`(32 字节)，
/// 再放 `WSABUF`(16)。两者都放在调用方节点内，内核就绝不会
/// 在操作未完成时读到已失效的描述符。
fn scratchOverlapped(scratch: *root.Scratch) *OVERLAPPED {
    return @ptrCast(@alignCast(scratch));
}

fn scratchBuf(scratch: *root.Scratch) [*]WSABUF {
    return @ptrCast(@alignCast(&scratch.bytes[32]));
}

fn vtRecv(userdata: ?*anyopaque, socket: root.Handle, buf: []u8, scratch: *root.Scratch) anyerror!?usize {
    _ = userdata;
    const wb = scratchBuf(scratch);
    wb[0] = .{ .len = @intCast(buf.len), .buf = buf.ptr };
    return recvInto(socket, wb, scratchOverlapped(scratch));
}

fn vtSend(userdata: ?*anyopaque, socket: root.Handle, buf: []const u8, scratch: *root.Scratch) anyerror!?usize {
    _ = userdata;
    const wb = scratchBuf(scratch);
    wb[0] = .{ .len = @intCast(buf.len), .buf = @constCast(buf.ptr) };
    return sendFrom(socket, wb, scratchOverlapped(scratch));
}

/// 异步 UDP 接收的后端私有状态。源地址本身由内核直接写进调用方的 `from`
/// 缓冲（与 io_uring 行为一致，好让 `Recv.from` 在两条路径下同义），这里只
/// 放 `lpFromLength` 这个入/出参——它必须活到完成包被收割，而 `Scratch`
/// 已被 `WSABUF` 与 `OVERLAPPED` 占用。
const UdpRecvHdr = extern struct {
    from_len: c_int = 28,
};

/// 异步 UDP 发送的状态：`to` 的 sockaddr 编码结果必须活到完成。
const UdpSendHdr = extern struct {
    to: SockAddr = .{},
};

comptime {
    // 节点侧 `hdr` 的预算是 32 个 usize。
    if (@sizeOf(UdpRecvHdr) > 32 * @sizeOf(usize)) @compileError("UdpRecvHdr 超出 hdr 预算");
    if (@sizeOf(UdpSendHdr) > 32 * @sizeOf(usize)) @compileError("UdpSendHdr 超出 hdr 预算");
}

fn udpHdr(comptime T: type, hdr: []usize) *T {
    std.debug.assert(hdr.len * @sizeOf(usize) >= @sizeOf(T));
    return @ptrCast(@alignCast(hdr.ptr));
}

fn vtUdpRecv(
    userdata: ?*anyopaque,
    socket: root.Handle,
    buf: []u8,
    from: []u8,
    hdr: []usize,
    scratch: *root.Scratch,
) anyerror!void {
    _ = userdata;
    const h = udpHdr(UdpRecvHdr, hdr);
    h.* = .{};
    h.from_len = @intCast(from.len);
    const wb = scratchBuf(scratch);
    wb[0] = .{ .len = @intCast(buf.len), .buf = buf.ptr };
    var flags: u32 = 0;
    const rc = c.WSARecvFrom(
        socket,
        wb,
        1,
        null, // 重叠套接字上必须传 null：完成字节数来自完成包，不是这个出参。
        &flags,
        @ptrCast(from.ptr),
        &h.from_len,
        scratchOverlapped(scratch),
        null,
    );
    // 契约与 `recvInto` 相同：返回 0 只代表提交成功，完成包仍会排队。
    if (rc == 0) return;
    if (lastError() != WSA_IO_PENDING) return error.RequestFailed;
}

fn vtUdpSend(
    userdata: ?*anyopaque,
    socket: root.Handle,
    buf: []const u8,
    to: net.IpAddress,
    hdr: []usize,
    scratch: *root.Scratch,
) anyerror!void {
    _ = userdata;
    const h = udpHdr(UdpSendHdr, hdr);
    h.to = toSockAddr(to);
    const wb = scratchBuf(scratch);
    wb[0] = .{ .len = @intCast(buf.len), .buf = @constCast(buf.ptr) };
    const rc = c.WSASendTo(
        socket,
        wb,
        1,
        null, // 重叠套接字上必须传 null：完成字节数来自完成包，不是这个出参。
        0,
        &h.to.storage,
        h.to.len(),
        scratchOverlapped(scratch),
        null,
    );
    if (rc == 0) return;
    if (lastError() != WSA_IO_PENDING) return error.RequestFailed;
}

fn vtAccept(userdata: ?*anyopaque, listen: root.Handle, accept_socket: root.Handle, addr_buf: []u8, scratch: *root.Scratch) anyerror!?usize {
    _ = userdata;
    return acceptEx(listen, accept_socket, addr_buf, scratchOverlapped(scratch));
}

fn vtUpdateAccept(userdata: ?*anyopaque, listen: root.Handle, accept_socket: root.Handle) void {
    _ = userdata;
    updateAcceptContext(listen, accept_socket);
}

fn vtConnect(userdata: ?*anyopaque, socket: root.Handle, address: std.Io.net.IpAddress, scratch: *root.Scratch) anyerror!void {
    _ = userdata;
    _ = try connectEx(socket, address, scratchOverlapped(scratch));
}

fn vtUpdateConnect(userdata: ?*anyopaque, socket: root.Handle) void {
    _ = userdata;
    updateConnectContext(socket);
}

fn vtClose(userdata: ?*anyopaque, socket: root.Handle) void {
    _ = userdata;
    closeSocket(socket);
}

/// 取消一个重叠操作。`CancelIoEx` 成功后 IOCP 仍会投递一个
/// `ERROR_OPERATION_ABORTED` 完成包，循环据此回收节点。
fn vtCancel(userdata: ?*anyopaque, socket: root.Handle, scratch: *root.Scratch) void {
    _ = userdata;
    if (socket == root.INVALID_HANDLE) return;
    const ov: *anyopaque = @ptrCast(scratchOverlapped(scratch));
    _ = c.CancelIoEx(@ptrFromInt(socket), ov);
}

fn vtNotify(userdata: ?*anyopaque) void {
    stateOf(userdata).port.notify();
}

/// 一次系统调用收割多个 IOCP 完成包。空 `OVERLAPPED` 是 `notify` 唤醒信号，
/// 直接跳过。`OVERLAPPED.Internal` 是 NTSTATUS：非 0 表示操作失败。
fn vtWaitBatch(userdata: ?*anyopaque, timeout_ms: u32, refs: []root.Ref) anyerror!usize {
    const port = stateOf(userdata).port;
    var entries: [64]c.OVERLAPPED_ENTRY = undefined;
    const cap: u32 = @intCast(@min(refs.len, entries.len));
    var removed: u32 = 0;
    const ok = c.GetQueuedCompletionStatusEx(
        port.handle,
        &entries,
        cap,
        &removed,
        timeout_ms,
        .FALSE,
    );
    if (!ok.toBool()) return 0;

    var n: usize = 0;
    var i: u32 = 0;
    while (i < removed) : (i += 1) {
        const ov = entries[i].overlapped orelse continue; // 唤醒信号，无完成包
        const scratch: *root.Scratch = @ptrCast(@alignCast(ov));
        const overlapped: *const OVERLAPPED = @ptrCast(@alignCast(ov));
        refs[n] = .{
            .scratch = scratch,
            .bytes = entries[i].bytes,
            .failed = overlapped.Internal != 0,
            // AcceptEx 写进预先建好的 socket，内核不另给新句柄。
            .new_handle = root.INVALID_HANDLE,
        };
        n += 1;
    }
    return n;
}

// ---- 套接字 / 文件辅助操作（经 VTable 暴露给上层） ------------------------

fn vtCreateSocket(userdata: ?*anyopaque, address: net.IpAddress) anyerror!root.Handle {
    _ = userdata;
    return @intCast(try createTcpSocket(address));
}

fn vtSetReuseAddress(userdata: ?*anyopaque, socket: root.Handle, on: bool) anyerror!void {
    _ = userdata;
    try setReuseAddress(@intCast(socket), on);
}

fn vtSetSockOpt(userdata: ?*anyopaque, socket: root.Handle, opt: root.SockOpt, value: u32) anyerror!void {
    _ = userdata;
    try setSockOpt(@intCast(socket), opt, value);
}

fn vtShutdownSend(userdata: ?*anyopaque, socket: root.Handle) anyerror!void {
    _ = userdata;
    try shutdownSend(@intCast(socket));
}

fn vtShutdown(userdata: ?*anyopaque, socket: root.Handle, how: root.ShutdownHow) anyerror!void {
    _ = userdata;
    const flag: c_int = switch (how) {
        .read => SD_RECEIVE,
        .write => SD_SEND,
        .both => SD_BOTH,
    };
    if (c.shutdown(@intCast(socket), flag) != ERROR_SUCCESS) return error.ShutdownFailed;
}

/// iovec 上限，与 `MSG_HDR_WORDS` 的预算对应（32 个 WSABUF = 256 字节）。
const IOV_MAX = 32;

fn vtSendMsg(
    userdata: ?*anyopaque,
    socket: root.Handle,
    bufs: []const []const u8,
    hdr: []usize,
    scratch: *root.Scratch,
) anyerror!void {
    _ = userdata;
    _ = hdr;
    if (bufs.len == 0) return error.NoBuffers;
    if (bufs.len > IOV_MAX) return error.TooManyBuffers;

    var wsabufs: [IOV_MAX]WSABUF = undefined;
    for (bufs, 0..) |b, i| wsabufs[i] = .{ .len = @intCast(b.len), .buf = @constCast(b.ptr) };

    // OVERLAPPED 必须活到完成包被收割：`scratch` 正是为此存在。
    const ov: *OVERLAPPED = @ptrCast(@alignCast(&scratch.bytes));
    ov.* = std.mem.zeroes(OVERLAPPED);
    const s: SOCKET = @intCast(socket);
    var sent: u32 = 0;
    if (c.WSASend(s, &wsabufs, @intCast(bufs.len), &sent, 0, ov, null) != 0) {
        const e = lastError();
        // WSA_IO_PENDING 是正常路径：完成包稍后投递到 IOCP。
        if (e != WSA_IO_PENDING) return error.SendFailed;
    }
}

fn vtRecvMsg(
    userdata: ?*anyopaque,
    socket: root.Handle,
    bufs: []const []u8,
    hdr: []usize,
    scratch: *root.Scratch,
) anyerror!void {
    _ = userdata;
    _ = hdr;
    if (bufs.len == 0) return error.NoBuffers;
    if (bufs.len > IOV_MAX) return error.TooManyBuffers;

    var wsabufs: [IOV_MAX]WSABUF = undefined;
    for (bufs, 0..) |b, i| wsabufs[i] = .{ .len = @intCast(b.len), .buf = b.ptr };

    const ov: *OVERLAPPED = @ptrCast(@alignCast(&scratch.bytes));
    ov.* = std.mem.zeroes(OVERLAPPED);
    const s: SOCKET = @intCast(socket);
    var received: u32 = 0;
    var flags: u32 = 0;
    if (c.WSARecv(s, &wsabufs, @intCast(bufs.len), &received, &flags, ov, null) != 0) {
        const e = lastError();
        if (e != WSA_IO_PENDING) return error.RecvFailed;
    }
}

fn vtBind(userdata: ?*anyopaque, socket: root.Handle, address: net.IpAddress) anyerror!void {
    _ = userdata;
    try bindSocket(@intCast(socket), address);
}

fn vtListen(userdata: ?*anyopaque, socket: root.Handle, backlog: c_int) anyerror!void {
    _ = userdata;
    try listenSocket(@intCast(socket), backlog);
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

fn vtOpenFile(userdata: ?*anyopaque, path: []const u8, mode: root.FileMode) anyerror!root.Handle {
    _ = userdata;
    return openFile(path, mode);
}

fn vtReadFileHandle(userdata: ?*anyopaque, file: root.Handle, offset: u64, buf: []u8) anyerror!usize {
    _ = userdata;
    return readFileHandle(file, offset, buf);
}

fn vtWriteFileHandle(userdata: ?*anyopaque, file: root.Handle, offset: u64, bytes: []const u8) anyerror!usize {
    _ = userdata;
    return writeFileHandle(file, offset, bytes);
}

fn vtCloseFile(userdata: ?*anyopaque, file: root.Handle) void {
    _ = userdata;
    closeFile(file);
}

fn vtStatFile(userdata: ?*anyopaque, file: root.Handle) anyerror!root.Stat {
    _ = userdata;
    const st = try statFile(file);
    return .{ .kind = @fromBackingInt(@intCast(@backingInt(st.kind))), .size = st.size, .mtime_ms = st.mtime_ms };
}

fn vtSetFileSize(userdata: ?*anyopaque, file: root.Handle, size: u64) anyerror!void {
    _ = userdata;
    return setFileSize(file, size);
}

fn vtSyncFile(userdata: ?*anyopaque, file: root.Handle) anyerror!void {
    _ = userdata;
    return syncFile(file);
}

fn vtReadLink(userdata: ?*anyopaque, link_path: []const u8, buf: []u8) anyerror!usize {
    _ = userdata;
    return readLink(link_path, buf);
}

// 目录流需要分配器（`WinDirStream` 是堆对象），从后端状态里取。
fn vtOpenDir(userdata: ?*anyopaque, path: []const u8) anyerror!root.Handle {
    return openDir(stateOf(userdata).alloc, path);
}

fn vtReadDirHandle(userdata: ?*anyopaque, dir: root.Handle, buf: []root.DirEntry) anyerror!usize {
    return readDirHandle(stateOf(userdata).alloc, dir, buf);
}

fn vtCloseDir(userdata: ?*anyopaque, dir: root.Handle) void {
    closeDir(stateOf(userdata).alloc, dir);
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
    .close = vtClose,
    .waitBatch = vtWaitBatch,
    .notify = vtNotify,
};

/// 拉起 IOCP 后端，交回一个可供循环驱动的 `Io`。
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
    try startup();
    const st = try alloc.create(State);
    errdefer alloc.destroy(st);
    st.* = .{ .alloc = alloc, .port = try CompletionPort.init() };
    return .{ .userdata = st, .vtable = &vtable_storage };
}

// ---- 扁平文件 I/O（在 `Work` 池线程中执行） --------------------------------

/// `WIN32_FIND_DATAW` 在 std 的 windows 绑定里没有，按 SDK 定义自行声明。
/// 布局必须与 SDK 完全一致（`FindFirstFileW` 会按它写内存），所以用
/// `extern struct` 且字段顺序一个都不能少。
const WIN32_FIND_DATAW = extern struct {
    dwFileAttributes: u32,
    ftCreationTime: windows.FILETIME,
    ftLastAccessTime: windows.FILETIME,
    ftLastWriteTime: windows.FILETIME,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
    dwReserved0: u32,
    dwReserved1: u32,
    cFileName: [260]u16,
    cAlternateFileName: [14]u16,
};

/// `fileapi.h: BY_HANDLE_FILE_INFORMATION`
/// 字段顺序与 Win32 一致；`nFileSizeHigh`/`Low` 拼成 64 位大小。
const BY_HANDLE_FILE_INFORMATION = extern struct {
    dwFileAttributes: u32,
    ftCreationTime: std.os.windows.FILETIME,
    ftLastAccessTime: std.os.windows.FILETIME,
    ftLastWriteTime: std.os.windows.FILETIME,
    dwVolumeSerialNumber: u32,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
    nNumberOfLinks: u32,
    nFileIndexHigh: u32,
    nFileIndexLow: u32,
};
const fl32 = struct {
    extern "kernel32" fn CreateFileW(
        name: [*]const u16,
        access: u32,
        share: u32,
        sa: ?*anyopaque,
        disposition: u32,
        flags: u32,
        template: ?HANDLE,
    ) callconv(.winapi) HANDLE;
    extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, to_read: u32, read: *u32, ov: ?*anyopaque) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, to_write: u32, written: *u32, ov: ?*anyopaque) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetFileSizeEx(h: HANDLE, size: *i64) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn CreateSymbolicLinkW(link: [*]const u16, target: [*]const u16, flags: u32) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetFileTime(h: HANDLE, creation: ?*windows.FILETIME, access: ?*windows.FILETIME, write: ?*windows.FILETIME) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetFileInformationByHandle(h: HANDLE, info: *BY_HANDLE_FILE_INFORMATION) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn FlushFileBuffers(h: HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn DeviceIoControl(
        h: HANDLE,
        code: u32,
        in_buf: ?*const anyopaque,
        in_size: u32,
        out_buf: ?*anyopaque,
        out_size: u32,
        returned: *u32,
        overlapped: ?*anyopaque,
    ) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn FindFirstFileW(name: [*]const u16, data: *WIN32_FIND_DATAW) callconv(.winapi) HANDLE;
    extern "kernel32" fn FindNextFileW(h: HANDLE, data: *WIN32_FIND_DATAW) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn FindClose(h: HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn CreateDirectoryW(name: [*]const u16, sa: ?*anyopaque) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn RemoveDirectoryW(name: [*]const u16) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn MoveFileExW(old: [*]const u16, new: [*]const u16, flags: u32) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetFileAttributesW(name: [*]const u16) callconv(.winapi) u32;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
    extern "kernel32" fn DeleteFileW(name: [*]const u16) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn SetFilePointerEx(
        h: HANDLE,
        distance: std.os.windows.LARGE_INTEGER,
        new_pos: ?*std.os.windows.LARGE_INTEGER,
        method: u32,
    ) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn SetEndOfFile(h: HANDLE) callconv(.winapi) windows.BOOL;
};

const GENERIC_READ: u32 = 0x80000000;
const GENERIC_WRITE: u32 = 0x40000000;
const FILE_SHARE_READ: u32 = 0x00000001;
const FILE_SHARE_WRITE: u32 = 0x00000002;
const OPEN_EXISTING: u32 = 3;
const CREATE_ALWAYS: u32 = 2;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
const OPEN_ALWAYS: u32 = 4;
const FILE_BEGIN: u32 = 0;
const FILE_END: u32 = 2;
const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
const MOVEFILE_REPLACE_EXISTING: u32 = 0x00000001;
const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFFFFFF;
const ERROR_ALREADY_EXISTS: u32 = 183;
const ERROR_FILE_NOT_FOUND: u32 = 2;
const ERROR_PATH_NOT_FOUND: u32 = 3;
const ERROR_ACCESS_DENIED: u32 = 5;
const ERROR_INVALID_HANDLE: u32 = 6;

// 重解析点（符号链接 / junction）相关常量，见 `winnt.h` / `winioctl.h`。
const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x02000000;
const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x00200000;
const FSCTL_GET_REPARSE_POINT: u32 = 0x000900A8;
const IO_REPARSE_TAG_MOUNT_POINT: u32 = 0xA0000003;
const IO_REPARSE_TAG_SYMLINK: u32 = 0xA000000C;

fn invalidHandle() HANDLE {
    return @ptrFromInt(std.math.maxInt(usize));
}

fn widePath(path: []const u8, buf: []u16) anyerror![:0]const u16 {
    if (path.len >= buf.len) return error.NameTooLong;
    const n = std.unicode.utf8ToUtf16Le(buf[0..path.len], path) catch return error.InvalidPath;
    buf[n] = 0;
    return buf[0..n :0];
}

// ---- 目录与元数据（在 `Work` 池线程中执行） ------------------------------

pub const FileKind = enum { file, directory, sym_link, other };

pub const Stat = struct {
    kind: FileKind,
    size: u64,
    /// 最后修改时间（Unix 毫秒）；0 表示拿不到。
    mtime_ms: i64,
};

/// 创建目录（含所有缺失的父目录，等价 `mkdir -p`）。
/// Windows 没有 mode 概念，`mode` 参数被忽略，保留只为与 POSIX 同签名。
pub fn makeDir(path: []const u8, mode: u32) anyerror!void {
    _ = mode;
    if (path.len == 0) return error.InvalidPath;
    var buf: [1024]u16 = undefined;
    var i: usize = 0;
    // 逐级创建。Windows 路径分隔符两种都认，这里按 '/' 与 '\' 切分。
    while (i <= path.len) : (i += 1) {
        if (i != path.len and path[i] != '/' and path[i] != '\\') continue;
        // 跳过盘符本身（`C:`）与根（`C:\`）。
        if (i == 0) continue;
        if (i == 2 and path.len >= 2 and path[1] == ':') continue;
        const z = try widePath(path[0..i], &buf);
        if (!fl32.CreateDirectoryW(z.ptr, null).toBool()) {
            const e = fl32.GetLastError();
            if (e != ERROR_ALREADY_EXISTS) return error.MakeDirFailed;
        }
    }
    return;
}

pub fn removeDir(path: []const u8) anyerror!void {
    var buf: [1024]u16 = undefined;
    const z = try widePath(path, &buf);
    if (fl32.RemoveDirectoryW(z.ptr).toBool()) return;
    // 非空目录在 Windows 上就是 ERROR_DIR_NOT_EMPTY(145)。
    if (fl32.GetLastError() == 145) return error.DirNotEmpty;
    return error.RemoveDirFailed;
}

pub fn rename(old_path: []const u8, new_path: []const u8) anyerror!void {
    var obuf: [1024]u16 = undefined;
    var nbuf: [1024]u16 = undefined;
    const o = try widePath(old_path, &obuf);
    const n = try widePath(new_path, &nbuf);
    // `MOVEFILE_REPLACE_EXISTING` 让语义与 POSIX `rename(2)` 对齐
    // （目标已存在时覆盖，而不是失败）。
    if (!fl32.MoveFileExW(o.ptr, n.ptr, MOVEFILE_REPLACE_EXISTING).toBool()) {
        return switch (fl32.GetLastError()) {
            ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND => error.FileNotFound,
            else => error.RenameFailed,
        };
    }
}

/// Windows 的符号链接需要管理员权限或开发者模式，失败时如实上报。
pub fn symLink(target: []const u8, link_path: []const u8) anyerror!void {
    var tbuf: [1024]u16 = undefined;
    var lbuf: [1024]u16 = undefined;
    const t = try widePath(target, &tbuf);
    const l = try widePath(link_path, &lbuf);
    if (!fl32.CreateSymbolicLinkW(l.ptr, t.ptr, 0).toBool()) return error.SymLinkFailed;
}

pub fn stat(path: []const u8) anyerror!Stat {
    var buf: [1024]u16 = undefined;
    const z = try widePath(path, &buf);
    const attrs = fl32.GetFileAttributesW(z.ptr);
    if (attrs == INVALID_FILE_ATTRIBUTES) {
        return switch (fl32.GetLastError()) {
            ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND => error.FileNotFound,
            else => error.StatFailed,
        };
    }
    const is_dir = attrs & FILE_ATTRIBUTE_DIRECTORY != 0;
    // 大小与 mtime 要从文件句柄拿；目录不必开句柄。
    var size: u64 = 0;
    var mtime_ms: i64 = 0;
    if (!is_dir) {
        const h = fl32.CreateFileW(z.ptr, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
        if (h != invalidHandle()) {
            defer _ = c.CloseHandle(h);
            var sz: i64 = 0;
            if (fl32.GetFileSizeEx(h, &sz).toBool()) size = @intCast(sz);
            var ft: windows.FILETIME = undefined;
            if (fl32.GetFileTime(h, null, null, &ft).toBool()) {
                // FILETIME 是 1601 起的 100ns 计数；转 Unix 毫秒要减去 1601→1970 的偏移。
                const ticks: u64 = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
                const epoch_diff: u64 = 116_444_736_000_000_000;
                if (ticks > epoch_diff) {
                    mtime_ms = @intCast((ticks - epoch_diff) / 10_000);
                }
            }
        }
    }
    return .{
        .kind = if (is_dir) .directory else .file,
        .size = size,
        .mtime_ms = mtime_ms,
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
pub fn listDir(path: []const u8, buf: []DirEntry) anyerror!usize {
    var zbuf: [1024]u16 = undefined;
    // 用 `path\*` 通配；`FindFirstFileW` 是 std 未绑定的，同样自声明。
    var joined: [1100]u8 = undefined;
    if (path.len + 3 > joined.len) return error.NameTooLong;
    @memcpy(joined[0..path.len], path);
    @memcpy(joined[path.len..][0..2], "\\*");
    const z = try widePath(joined[0 .. path.len + 2], &zbuf);

    var data: WIN32_FIND_DATAW = undefined;
    const h = fl32.FindFirstFileW(z.ptr, &data);
    if (h == invalidHandle()) return 0; // 空目录或不存在
    defer _ = fl32.FindClose(h);

    var count: usize = 0;
    while (true) {
        const name_u16 = std.mem.sliceTo(&data.cFileName, 0);
        if (!std.mem.eql(u16, name_u16, &.{'.'}) and !std.mem.eql(u16, name_u16, &.{ '.', '.' })) {
            if (count >= buf.len) return count;
            var utf8: [256]u8 = undefined;
            const n = std.unicode.utf16LeToUtf8(&utf8, name_u16) catch 0;
            if (n > 0 and n <= buf[count].name.len) {
                @memcpy(buf[count].name[0..n], utf8[0..n]);
                buf[count].len = n;
                buf[count].is_dir = data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0;
                count += 1;
            }
        }
        if (!fl32.FindNextFileW(h, &data).toBool()) break;
    }
    return count;
}

pub fn fileSize(path: []const u8) anyerror!u64 {
    var wbuf: [1024]u16 = undefined;
    const w = try widePath(path, &wbuf);
    const h = fl32.CreateFileW(w.ptr, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
    if (h == invalidHandle()) return error.FileNotFound;
    defer _ = c.CloseHandle(h);
    var sz: i64 = 0;
    if (!fl32.GetFileSizeEx(h, &sz).toBool()) return error.RequestFailed;
    return @intCast(sz);
}

pub fn readFileInto(path: []const u8, buf: []u8) anyerror!usize {
    var wbuf: [1024]u16 = undefined;
    const w = try widePath(path, &wbuf);
    const h = fl32.CreateFileW(w.ptr, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
    if (h == invalidHandle()) return error.FileNotFound;
    defer _ = c.CloseHandle(h);
    var total: usize = 0;
    while (total < buf.len) {
        var got: u32 = 0;
        if (!fl32.ReadFile(h, buf.ptr + total, @intCast(buf.len - total), &got, null).toBool()) return error.RequestFailed;
        if (got == 0) break;
        total += got;
    }
    return total;
}

pub fn writeFileAll(path: []const u8, bytes: []const u8) anyerror!void {
    var wbuf: [1024]u16 = undefined;
    const w = try widePath(path, &wbuf);
    const h = fl32.CreateFileW(w.ptr, GENERIC_WRITE, FILE_SHARE_READ, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    if (h == invalidHandle()) return error.RequestFailed;
    defer _ = c.CloseHandle(h);
    var written: u32 = 0;
    if (!fl32.WriteFile(h, bytes.ptr, @intCast(bytes.len), &written, null).toBool()) return error.RequestFailed;
}

pub fn deleteFile(path: []const u8) void {
    var wbuf: [1024]u16 = undefined;
    const w = widePath(path, &wbuf) catch return;
    _ = fl32.DeleteFileW(w.ptr);
}

/// 从 `offset` 处读入 `buf`，返回实际读到的字节数（文件尾会短读）。
/// 与 `readFileInto` 的区别是支持随机访问，是分段读大文件的基础。
pub fn readFileAt(path: []const u8, offset: u64, buf: []u8) anyerror!usize {
    var wbuf: [1024]u16 = undefined;
    const w = try widePath(path, &wbuf);
    const h = fl32.CreateFileW(w.ptr, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
    if (h == invalidHandle()) return error.FileNotFound;
    defer _ = c.CloseHandle(h);
    const dist: std.os.windows.LARGE_INTEGER = @intCast(offset);
    if (!fl32.SetFilePointerEx(h, dist, null, FILE_BEGIN).toBool()) return error.RequestFailed;
    var total: usize = 0;
    while (total < buf.len) {
        var got: u32 = 0;
        if (!fl32.ReadFile(h, buf.ptr + total, @intCast(buf.len - total), &got, null).toBool()) return error.RequestFailed;
        if (got == 0) break;
        total += got;
    }
    return total;
}

/// 在文件末尾追加 `bytes`；文件不存在时创建。只做追加，不动既有内容。
pub fn appendFile(path: []const u8, bytes: []const u8) anyerror!void {
    var wbuf: [1024]u16 = undefined;
    const w = try widePath(path, &wbuf);
    const h = fl32.CreateFileW(w.ptr, GENERIC_WRITE, FILE_SHARE_READ, null, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    if (h == invalidHandle()) return error.RequestFailed;
    defer _ = c.CloseHandle(h);
    // 定位到文件末尾再写，等价于 POSIX 的 O_APPEND 语义。
    if (!fl32.SetFilePointerEx(h, 0, null, FILE_END).toBool()) return error.RequestFailed;
    var written: u32 = 0;
    if (!fl32.WriteFile(h, bytes.ptr, @intCast(bytes.len), &written, null).toBool()) return error.RequestFailed;
}

/// 把文件截断到 `size` 字节。
pub fn truncateFile(path: []const u8, size: u64) anyerror!void {
    var wbuf: [1024]u16 = undefined;
    const w = try widePath(path, &wbuf);
    const h = fl32.CreateFileW(w.ptr, GENERIC_WRITE, FILE_SHARE_READ, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
    if (h == invalidHandle()) return error.FileNotFound;
    defer _ = c.CloseHandle(h);
    const dist: std.os.windows.LARGE_INTEGER = @intCast(size);
    if (!fl32.SetFilePointerEx(h, dist, null, FILE_BEGIN).toBool()) return error.RequestFailed;
    if (!fl32.SetEndOfFile(h).toBool()) return error.RequestFailed;
}

// ---- 文件句柄层（阶段 A）--------------------------------------------------
// Windows 用 CreateFileW 拿 HANDLE，读写前用 SetFilePointerEx 定位到显式
// offset（Windows 的 ReadFile/WriteFile 没有 pread/pwrite 那种带偏移的重载，
// 除非走 OVERLAPPED 异步形式；同步场景用 SetFilePointerEx 更直接）。
// 这里刻意**不用** OVERLAPPED：那会把文件 I/O 接到 IOCP 上，语义变成异步，
// 与另外两个后端的同步 Work 池语义不一致。

/// 打开文件并返回 HANDLE。
pub fn openFile(path: []const u8, mode: root.FileMode) anyerror!root.Handle {
    var wbuf: [1024]u16 = undefined;
    const w = try widePath(path, &wbuf);
    const access: u32 = switch (mode) {
        .read_only => GENERIC_READ,
        .write_only, .append => GENERIC_WRITE,
        .read_write => GENERIC_READ | GENERIC_WRITE,
    };
    const disposition: u32 = switch (mode) {
        .read_only => OPEN_EXISTING,
        .write_only => CREATE_ALWAYS,
        .read_write, .append => OPEN_ALWAYS,
    };
    const h = fl32.CreateFileW(w.ptr, access, FILE_SHARE_READ | FILE_SHARE_WRITE, null, disposition, FILE_ATTRIBUTE_NORMAL, null);
    if (h == invalidHandle()) {
        // 把 Win32 错误码翻译成与其它后端一致的语义错误。只报 OpenFailed
        // 会让调用方没法区分「文件不存在」和「权限不足」——那是调用方
        // 必须分开处理的两件事。
        return switch (fl32.GetLastError()) {
            ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND => error.FileNotFound,
            ERROR_ACCESS_DENIED => error.AccessDenied,
            else => error.OpenFailed,
        };
    }
    return @intFromPtr(h);
}

/// 定位到 `offset`（`FILE_BEGIN` 起点）。失败返回错误。
fn seekTo(h: HANDLE, offset: u64) anyerror!void {
    const dist: std.os.windows.LARGE_INTEGER = @intCast(offset);
    if (!fl32.SetFilePointerEx(h, dist, null, FILE_BEGIN).toBool()) return error.SeekFailed;
}

/// 从 `offset` 读入 `buf`。返回实际读到的字节数；文件尾短读不报错。
pub fn readFileHandle(file: root.Handle, offset: u64, buf: []u8) anyerror!usize {
    const h: HANDLE = @ptrFromInt(file);
    try seekTo(h, offset);
    var total: usize = 0;
    while (total < buf.len) {
        var got: u32 = 0;
        if (!fl32.ReadFile(h, buf.ptr + total, @intCast(buf.len - total), &got, null).toBool()) return error.ReadFailed;
        if (got == 0) break; // EOF
        total += got;
    }
    return total;
}

/// 从 `offset` 写入全部 `bytes`。返回写入的字节数。
pub fn writeFileHandle(file: root.Handle, offset: u64, bytes: []const u8) anyerror!usize {
    const h: HANDLE = @ptrFromInt(file);
    try seekTo(h, offset);
    var total: usize = 0;
    while (total < bytes.len) {
        var written: u32 = 0;
        if (!fl32.WriteFile(h, bytes.ptr + total, @intCast(bytes.len - total), &written, null).toBool()) return error.WriteFailed;
        if (written == 0) return error.WriteZero;
        total += written;
    }
    return total;
}

/// 关闭句柄。无效句柄不报错（幂等）。
pub fn closeFile(file: root.Handle) void {
    const h: HANDLE = @ptrFromInt(file);
    if (h != invalidHandle()) _ = c.CloseHandle(h);
}

// ---- 句柄级元数据与同步（阶段 B）------------------------------------------

/// 把 FILETIME 转成 Unix 毫秒。1601→1970 的偏移是固定常数。
fn fileTimeToUnixMs(ft: std.os.windows.FILETIME) i64 {
    const ticks: u64 = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
    const epoch_diff: u64 = 116_444_736_000_000_000;
    if (ticks <= epoch_diff) return 0;
    return @intCast((ticks - epoch_diff) / 10_000);
}

/// 取句柄元数据。`GetFileInformationByHandle` 直接作用于句柄，
/// 不需要重新解析路径（也就没有「open 后路径被换掉」的竞态）。
pub fn statFile(file: root.Handle) anyerror!Stat {
    const h: HANDLE = @ptrFromInt(file);
    if (h == invalidHandle()) return error.InvalidHandle;
    var info: BY_HANDLE_FILE_INFORMATION = undefined;
    if (!fl32.GetFileInformationByHandle(h, &info).toBool()) {
        return switch (fl32.GetLastError()) {
            ERROR_INVALID_HANDLE => error.InvalidHandle,
            else => error.StatFailed,
        };
    }
    const is_dir = info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0;
    const size: u64 = (@as(u64, info.nFileSizeHigh) << 32) | info.nFileSizeLow;
    return .{
        .kind = if (is_dir) .directory else .file,
        .size = if (is_dir) 0 else size,
        .mtime_ms = fileTimeToUnixMs(info.ftLastWriteTime),
    };
}

/// 把句柄对应文件截断到 `size` 字节。
/// 先定位到目标长度再 `SetEndOfFile`（Win32 没有 `ftruncate` 那种一步到位）。
pub fn setFileSize(file: root.Handle, size: u64) anyerror!void {
    const h: HANDLE = @ptrFromInt(file);
    if (h == invalidHandle()) return error.InvalidHandle;
    try seekTo(h, size);
    if (!fl32.SetEndOfFile(h).toBool()) return error.TruncateFailed;
}

/// 把缓冲内容刷到磁盘。`FlushFileBuffers` 是 Win32 的 `fsync` 等价物。
pub fn syncFile(file: root.Handle) anyerror!void {
    const h: HANDLE = @ptrFromInt(file);
    if (h == invalidHandle()) return error.InvalidHandle;
    if (!fl32.FlushFileBuffers(h).toBool()) return error.SyncFailed;
}

// ---- 符号链接读取 + 目录流式句柄（阶段 C）--------------------------------

/// 读符号链接指向的目标。
pub fn readLink(link_path: []const u8, buf: []u8) anyerror!usize {
    var wbuf: [1024]u16 = undefined;
    const w = try widePath(link_path, &wbuf);
    // 打开重解析点本身（FILE_FLAG_OPEN_REPARSE_POINT 才能拿到链接本身
    // 而不是它指向的目标）。BACKUP_SEMANTICS 是打开目录所必需的。
    const h = fl32.CreateFileW(
        w.ptr,
        0, // 只查属性，不需要读写权限
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        null,
        OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
        null,
    );
    if (h == invalidHandle()) {
        return switch (fl32.GetLastError()) {
            ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND => error.FileNotFound,
            else => error.ReadLinkFailed,
        };
    }
    defer _ = c.CloseHandle(h);

    // 用 FSCTL_GET_REPARSE_POINT 拿重解析数据。
    var rdb: [16 * 1024]u8 align(8) = undefined;
    var returned: u32 = 0;
    if (!fl32.DeviceIoControl(h, FSCTL_GET_REPARSE_POINT, null, 0, &rdb, rdb.len, &returned, null).toBool()) {
        return error.NotASymLink; // 不是重解析点
    }
    return parseReparsePoint(&rdb, returned, buf);
}

/// 从 `REPARSE_DATA_BUFFER` 里取出符号链接目标并转成 UTF-8。
/// 结构见 `ntifs.h`；只处理 `IO_REPARSE_TAG_SYMLINK` 与
/// `IO_REPARSE_TAG_MOUNT_POINT`（junction）两种。
fn parseReparsePoint(raw: []const u8, returned: u32, buf: []u8) anyerror!usize {
    if (returned < 8) return error.ReadLinkFailed;
    const tag = std.mem.readInt(u32, raw[0..4], .little);
    const data_len = std.mem.readInt(u16, raw[4..6], .little);
    if (returned < 8 + @as(u32, data_len)) return error.ReadLinkFailed;

    if (tag == IO_REPARSE_TAG_MOUNT_POINT) {
        // junction：8 字节头之后是 4 个偏移/长度字段（SubstName 与
        // PrintName 各一对），路径在偏移 16 处开始。
        if (data_len < 16) return error.ReadLinkFailed;
        const sub_off = std.mem.readInt(u16, raw[8..10], .little);
        const sub_len = std.mem.readInt(u16, raw[10..12], .little);
        const base: usize = 8;
        if (base + sub_off + sub_len > 8 + @as(usize, data_len)) return error.ReadLinkFailed;
        return u16PathToUtf8(raw[base + sub_off .. base + sub_off + sub_len], buf);
    }
    if (tag == IO_REPARSE_TAG_SYMLINK) {
        // symlink：8 字节头 + 4 偏移 + 4 长度 + 4 标志 + 路径，路径从偏移 20 开始。
        if (data_len < 12) return error.ReadLinkFailed;
        const sub_off = std.mem.readInt(u16, raw[8..10], .little);
        const sub_len = std.mem.readInt(u16, raw[10..12], .little);
        const base: usize = 20;
        if (base + sub_off + sub_len > 8 + @as(usize, data_len)) return error.ReadLinkFailed;
        return u16PathToUtf8(raw[base + sub_off .. base + sub_off + sub_len], buf);
    }
    return error.NotASymLink;
}

/// 把 UTF-16LE 字节序列转成 UTF-8 写进 `buf`。
fn u16PathToUtf8(u16_bytes: []const u8, buf: []u8) anyerror!usize {
    const n_u16 = u16_bytes.len / 2;
    if (n_u16 == 0) return 0;
    const src: [*]const u16 = @ptrCast(@alignCast(u16_bytes.ptr));
    const written = std.unicode.utf16LeToUtf8(buf, src[0..n_u16]) catch return error.NameTooLong;
    if (written >= buf.len) return error.NameTooLong;
    return written;
}

/// Windows 的目录流状态。`FindFirstFileW` 给的是一个有状态枚举器，
/// 一次只交一条，所以这里只要记住「已从 FindNext 拿到但还没交给调用方」
/// 的那一条即可——不存在 Linux/BSD 那种整批前移丢条目的问题。
const WinDirStream = struct {
    handle: HANDLE,
    /// 待交付的条目。`valid == false` 表示没有预取。
    pending: WIN32_FIND_DATAW = undefined,
    valid: bool = false,
};

/// 打开目录。返回的是自建的流对象指针（不是 Win32 HANDLE），
/// 由 `closeDir` 释放。
pub fn openDir(st_alloc: std.mem.Allocator, path: []const u8) anyerror!root.Handle {
    var joined_buf: [1100]u8 = undefined;
    if (path.len + 3 > joined_buf.len) return error.NameTooLong;
    @memcpy(joined_buf[0..path.len], path);
    @memcpy(joined_buf[path.len..][0..2], "\\*");

    var wbuf: [1100]u16 = undefined;
    const w = try widePath(joined_buf[0 .. path.len + 2], &wbuf);

    var data: WIN32_FIND_DATAW = undefined;
    const h = fl32.FindFirstFileW(w.ptr, &data);
    if (h == invalidHandle()) {
        return switch (fl32.GetLastError()) {
            ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND => error.FileNotFound,
            else => error.OpenFailed,
        };
    }

    const stream = st_alloc.create(WinDirStream) catch {
        _ = fl32.FindClose(h);
        return error.OutOfMemory;
    };
    stream.* = .{ .handle = h, .pending = data, .valid = true };
    return @intFromPtr(stream);
}

/// 从目录流读下一批条目。
pub fn readDirHandle(st_alloc: std.mem.Allocator, dir: root.Handle, buf: []root.DirEntry) anyerror!usize {
    _ = st_alloc;
    if (buf.len == 0) return 0;
    const stream: *WinDirStream = @ptrFromInt(dir);

    var count: usize = 0;
    while (count < buf.len) {
        var data: WIN32_FIND_DATAW = undefined;
        if (stream.valid) {
            data = stream.pending;
            stream.valid = false;
        } else {
            if (!fl32.FindNextFileW(stream.handle, &data).toBool()) break; // 读完
        }
        const name_u16 = std.mem.sliceTo(&data.cFileName, 0);
        if (std.mem.eql(u16, name_u16, &.{'.'}) or std.mem.eql(u16, name_u16, &.{ '.', '.' })) continue;
        var utf8: [256]u8 = undefined;
        const n = std.unicode.utf16LeToUtf8(&utf8, name_u16) catch continue;
        if (n == 0 or n > buf[count].name.len) continue;
        @memcpy(buf[count].name[0..n], utf8[0..n]);
        buf[count].len = n;
        buf[count].is_dir = data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0;
        count += 1;
    }
    return count;
}

/// 关闭目录流。幂等。
pub fn closeDir(st_alloc: std.mem.Allocator, dir: root.Handle) void {
    const stream: *WinDirStream = @ptrFromInt(dir);
    _ = fl32.FindClose(stream.handle);
    st_alloc.destroy(stream);
}
