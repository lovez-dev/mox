//! 高层 TCP 门面：**薄封装**，不含新行为。
//!
//! 背景：`mox_io` 里已经有完整的底层原语（`platform.createTcpSocket` /
//! `bindSocket` / `listenSocket` / `acceptSocket` / `connectSocket` /
//! `setSockOpt` …），它们散在三个后端文件里，调用方要自己记住「先
//! `setReuseAddress` 再 `bind` 再 `listen`」这类顺序约束。本模块把这些
//! 顺序固化成几个类型，让常见 TCP 用法不用手写样板。
//!
//! **明确不做的事**（避免与 `mox_io` 的定位冲突）：
//!
//! - 不引入新的 I/O 模型。这里的方法全是**同步阻塞**调用，走后端自带的
//!   阻塞原语；异步路径请用 `Loop` + `NetRecv` / `NetSend` / `NetAccept` /
//!   `NetConnect` 节点。
//! - 不改动 `Loop` / `VTable` 的任何签名。`net.zig` 只是站在它们之上的
//!   便利层，删掉它整个库照常工作。
//! - 不做 DNS 解析、不做 TLS、不做连接池。DNS 走 `dns.zig` 能力表。
//!
//! **平台差异**：`platform` 是编译期选定的后端别名（Linux → `linux`，
//! Windows → `windows`，macOS/FreeBSD → `kqueue`）。本模块只用三个后端
//! **都实现**的同步原语，所以跨平台行为一致；错误则由各后端自己映射成
//! 具体的 `error`（例如 `error.ConnectFailed` / `error.BindFailed`）。

const std = @import("std");
const types = @import("types.zig");
const io_mod = @import("io.zig");

const platform = @import("platform.zig").platform;

/// IP 地址。本模块不重新定义，直接用标准库的类型。
pub const Address = std.Io.net.IpAddress;

/// 套接字句柄。与 `types.Handle` 同类型（Windows 上就是 `SOCKET`）。
pub const Handle = types.Handle;

/// 一次 `accept` 的结果：连接 + 对端地址。
pub const Accepted = struct {
    socket: Handle,
    address: Address,
};

/// 已连接的 TCP 套接字。
///
/// 这是个**薄包装**：内部只有一个句柄 + 一个 `Io`（用于取后端能力）。
/// 它不拥有任何资源语义上的额外状态，`close()` 就是关句柄。
pub const Tcp = struct {
    io: io_mod.Io,
    socket: Handle,

    /// 建一个已连接的 TCP 套接字。
    ///
    /// `connect` 是阻塞的；异步版本见 `Loop` 的 `NetConnect` 节点。
    pub fn connect(io: io_mod.Io, address: Address) !Tcp {
        const s = try platform.createTcpSocket(address);
        errdefer platform.closeSocket(s);
        try platform.connectSocket(s, address);
        return .{ .io = io, .socket = s };
    }

    /// 底层句柄。异步提交（`NetRecv` / `NetSend`）需要它。
    pub fn handle(self: Tcp) Handle {
        return self.socket;
    }

    /// 启用 TCP_NODELAY（关掉 Nagle 合并）。延迟敏感的协议应该开。
    pub fn setNoDelay(self: Tcp, on: bool) !void {
        try platform.setSockOpt(self.socket, .tcp_nodelay, @intFromBool(on));
    }

    /// 设置内核接收缓冲字节数。`0` 表示交由系统自适应。
    pub fn setRecvBuf(self: Tcp, bytes: u32) !void {
        try platform.setSockOpt(self.socket, .recv_buf, bytes);
    }

    /// 设置内核发送缓冲字节数。`0` 表示交由系统自适应。
    pub fn setSendBuf(self: Tcp, bytes: u32) !void {
        try platform.setSockOpt(self.socket, .send_buf, bytes);
    }

    /// 阻塞发送全部字节（内部循环直到写完或出错）。
    ///
    /// **同步调用**：会阻塞调用线程。事件循环里请用 `NetSend` 节点。
    pub fn sendAll(self: Tcp, bytes: []const u8) !void {
        var sent: usize = 0;
        while (sent < bytes.len) {
            const n = try platform.sendBlocking(self.socket, bytes[sent..]);
            if (n == 0) return error.SendFailed; // 对端已关，不会再有进展
            sent += n;
        }
    }

    /// 阻塞接收一次。返回 0 表示对端正常关闭。
    ///
    /// **同步调用**：会阻塞调用线程。事件循环里请用 `NetRecv` 节点。
    pub fn recv(self: Tcp, buf: []u8) !usize {
        return platform.recvBlocking(self.socket, buf);
    }

    /// 半关闭发送方向：对端仍能读完已发出的数据，之后再 `close` 才是优雅收尾。
    pub fn shutdownSend(self: Tcp) !void {
        try platform.shutdownSend(self.socket);
    }

    /// 关闭套接字。**吞掉错误**（重复关闭不算失败）。
    pub fn close(self: Tcp) void {
        platform.closeSocket(self.socket);
    }

    /// 关闭套接字并回报失败。重复关闭报 `error.NotOpen`。
    pub fn closeChecked(self: Tcp) !void {
        const f = self.io.vtable.closeChecked orelse {
            platform.closeSocket(self.socket);
            return;
        };
        try f(self.io.userdata, self.socket);
    }

    /// 本地地址（绑定后的实际地址，含端口）。
    pub fn localAddress(self: Tcp) !Address {
        return platform.localAddress(self.socket);
    }
};

/// 监听中的 TCP 套接字。
pub const Listener = struct {
    io: io_mod.Io,
    socket: Handle,

    /// 建一个监听套接字。`address` 的端口为 0 时由系统分配，
    /// 用 `localAddress()` 拿到实际端口。
    ///
    /// 顺序固定为「reuse → bind → listen」，调用方不用记。
    pub fn listen(io: io_mod.Io, address: Address, backlog: c_int) !Listener {
        const s = try platform.createTcpSocket(address);
        errdefer platform.closeSocket(s);
        try platform.setReuseAddress(s, true);
        try platform.bindSocket(s, address);
        try platform.listenSocket(s, backlog);
        return .{ .io = io, .socket = s };
    }

    /// 底层句柄。异步 `NetAccept` 需要它。
    pub fn handle(self: Listener) Handle {
        return self.socket;
    }

    /// 本地地址（实际绑定的地址与端口）。
    pub fn localAddress(self: Listener) !Address {
        return platform.localAddress(self.socket);
    }

    /// 阻塞接受一个连接。
    ///
    /// **同步调用**：会阻塞调用线程。事件循环里请用 `NetAccept` 节点。
    pub fn accept(self: Listener) !Accepted {
        const r = try platform.acceptSocket(self.socket);
        return .{ .socket = r.socket, .address = r.address };
    }

    /// 关闭监听套接字。**吞掉错误**。
    pub fn close(self: Listener) void {
        platform.closeSocket(self.socket);
    }
};

/// 一次性的「建监听 → 拿端口」便捷函数，回环地址 + 系统分配端口。
///
/// 用途：测试与临时服务。生产代码用 `Listener.listen` 显式指定地址。
pub fn listenLoopback(io: io_mod.Io, backlog: c_int) !Listener {
    const addr = try Address.parse("127.0.0.1", 0);
    return Listener.listen(io, addr, backlog);
}

// ---- 轻量自检 -------------------------------------------------------------

test "net: 薄门面能建监听、accept、收发" {
    var io = try platform.create(std.testing.allocator);
    defer io.vtable.deinit(io.userdata);

    var listener = try listenLoopback(io, 16);
    defer listener.close();
    const bound = try listener.localAddress();
    try std.testing.expect(bound.getPort() != 0);

    const Client = struct {
        fn run(addr: Address) void {
            const c = platform.createTcpSocket(addr) catch return;
            defer platform.closeSocket(c);
            platform.connectSocket(c, addr) catch return;
            _ = platform.sendBlocking(c, "ping") catch {};
            // 等一拍再关，给服务端留出读的时间。
            var buf: [16]u8 = undefined;
            _ = platform.recvBlocking(c, &buf) catch {};
        }
    };
    const t = try std.Thread.spawn(.{}, Client.run, .{bound});
    defer t.join();

    const accepted = try listener.accept();
    defer platform.closeSocket(accepted.socket);

    var buf: [16]u8 = undefined;
    const n = try platform.recvBlocking(accepted.socket, &buf);
    try std.testing.expectEqualStrings("ping", buf[0..n]);
}
