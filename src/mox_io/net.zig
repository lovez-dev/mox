//! 高层 TCP 门面：**薄封装**，不含新行为。
//!
//! 所有操作通过传入的 Io 调用，不自行选择平台。
//! 方法均为同步阻塞；事件循环内使用 Loop 与 Net* 完成节点。

const std = @import("std");
const types = @import("types.zig");
const io_mod = @import("io.zig");

/// IP 地址。本模块不重新定义，直接用标准库的类型。
pub const Address = std.Io.net.IpAddress;

/// 套接字句柄。与 `types.Handle` 同类型（Windows 上就是 `SOCKET`）。
pub const Handle = types.Handle;

/// 一次 `accept` 的结果：连接 + 对端地址。
pub const Accepted = types.Accepted;

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
        const s = try io.createSocket(address);
        errdefer io.close(s);
        try io.connectBlocking(s, address);
        return .{ .io = io, .socket = s };
    }

    /// 底层句柄。异步提交（`NetRecv` / `NetSend`）需要它。
    pub fn handle(self: Tcp) Handle {
        return self.socket;
    }

    /// 启用 TCP_NODELAY（关掉 Nagle 合并）。延迟敏感的协议应该开。
    pub fn setNoDelay(self: Tcp, on: bool) !void {
        try self.io.setSockOpt(self.socket, .tcp_nodelay, @intFromBool(on));
    }

    /// 设置内核接收缓冲字节数。`0` 表示交由系统自适应。
    pub fn setRecvBuf(self: Tcp, bytes: u32) !void {
        try self.io.setSockOpt(self.socket, .recv_buf, bytes);
    }

    /// 设置内核发送缓冲字节数。`0` 表示交由系统自适应。
    pub fn setSendBuf(self: Tcp, bytes: u32) !void {
        try self.io.setSockOpt(self.socket, .send_buf, bytes);
    }

    /// 阻塞发送全部字节（内部循环直到写完或出错）。
    ///
    /// **同步调用**：会阻塞调用线程。事件循环里请用 `NetSend` 节点。
    pub fn sendAll(self: Tcp, bytes: []const u8) !void {
        var sent: usize = 0;
        while (sent < bytes.len) {
            const n = try self.io.sendBlocking(self.socket, bytes[sent..]);
            if (n == 0) return error.SendFailed; // 对端已关，不会再有进展
            sent += n;
        }
    }

    /// 阻塞接收一次。返回 0 表示对端正常关闭。
    ///
    /// **同步调用**：会阻塞调用线程。事件循环里请用 `NetRecv` 节点。
    pub fn recv(self: Tcp, buf: []u8) !usize {
        return self.io.recvBlocking(self.socket, buf);
    }

    /// 半关闭发送方向：对端仍能读完已发出的数据，之后再 `close` 才是优雅收尾。
    pub fn shutdownSend(self: Tcp) !void {
        try self.io.shutdownSend(self.socket);
    }

    /// 关闭套接字。**吞掉错误**（重复关闭不算失败）。
    pub fn close(self: Tcp) void {
        self.io.close(self.socket);
    }

    /// 关闭套接字并回报失败。重复关闭报 `error.NotOpen`。
    pub fn closeChecked(self: Tcp) !void {
        try self.io.closeChecked(self.socket);
    }

    /// 本地地址（绑定后的实际地址，含端口）。
    pub fn localAddress(self: Tcp) !Address {
        return self.io.localAddress(self.socket);
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
        const s = try io.createSocket(address);
        errdefer io.close(s);
        try io.setReuseAddress(s, true);
        try io.bind(s, address);
        try io.listen(s, backlog);
        return .{ .io = io, .socket = s };
    }

    /// 底层句柄。异步 `NetAccept` 需要它。
    pub fn handle(self: Listener) Handle {
        return self.socket;
    }

    /// 本地地址（实际绑定的地址与端口）。
    pub fn localAddress(self: Listener) !Address {
        return self.io.localAddress(self.socket);
    }

    /// 阻塞接受一个连接。
    ///
    /// **同步调用**：会阻塞调用线程。事件循环里请用 `NetAccept` 节点。
    pub fn accept(self: Listener) !Accepted {
        const r = try self.io.acceptBlocking(self.socket);
        return .{ .socket = r.socket, .address = r.address };
    }

    /// 关闭监听套接字。**吞掉错误**。
    pub fn close(self: Listener) void {
        self.io.close(self.socket);
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
    const io = try @import("platform.zig").platform.create(std.testing.allocator, .{});
    defer io.vtable.deinit(io.userdata);
    const listener = try listenLoopback(io, 16);
    defer listener.close();
    const bound = try listener.localAddress();
    try std.testing.expect(bound.getPort() != 0);
    const Client = struct {
        fn run(client_io: io_mod.Io, address: Address) void {
            const client = Tcp.connect(client_io, address) catch return;
            defer client.close();
            client.sendAll("ping") catch return;
        }
    };
    const thread = try std.Thread.spawn(.{}, Client.run, .{ io, bound });
    defer thread.join();
    const accepted = try listener.accept();
    const tcp = Tcp{ .io = io, .socket = accepted.socket };
    defer tcp.close();
    var buf: [16]u8 = undefined;
    const count = try tcp.recv(&buf);
    try std.testing.expectEqualStrings("ping", buf[0..count]);
}

test "net: TCP 的连接、短写续发、接收和关闭均使用传入的 Io" {
    const backend = try @import("platform.zig").platform.create(std.testing.allocator, .{});
    defer backend.vtable.deinit(backend.userdata);
    const Fake = struct {
        connected: bool = false,
        sent: usize = 0,
        received: bool = false,
        closed: bool = false,

        fn state(ctx: ?*anyopaque) *@This() {
            return @ptrCast(@alignCast(ctx.?));
        }
        fn create(_: ?*anyopaque, _: Address) !Handle {
            return 123;
        }
        fn connect(ctx: ?*anyopaque, socket: Handle, _: Address) !void {
            try std.testing.expectEqual(@as(Handle, 123), socket);
            state(ctx).connected = true;
        }
        fn send(ctx: ?*anyopaque, _: Handle, bytes: []const u8) !usize {
            const count = @min(bytes.len, 2);
            state(ctx).sent += count;
            return count;
        }
        fn recv(ctx: ?*anyopaque, _: Handle, buf: []u8) !usize {
            state(ctx).received = true;
            @memcpy(buf[0..2], "ok");
            return 2;
        }
        fn close(ctx: ?*anyopaque, _: Handle) void {
            state(ctx).closed = true;
        }
    };
    var fake: Fake = .{};
    var table = backend.vtable.*;
    var blocking = table.blockingNet.?.*;
    table.createSocket = Fake.create;
    table.close = Fake.close;
    blocking.connectBlocking = Fake.connect;
    blocking.sendBlocking = Fake.send;
    blocking.recvBlocking = Fake.recv;
    table.blockingNet = &blocking;
    const io = io_mod.Io{ .userdata = &fake, .vtable = &table };
    const tcp = try Tcp.connect(io, try Address.parse("127.0.0.1", 0));
    try tcp.sendAll("hello");
    var buf: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try tcp.recv(&buf));
    tcp.close();
    try std.testing.expect(fake.connected and fake.received and fake.closed);
    try std.testing.expectEqual(@as(usize, 5), fake.sent);
    try std.testing.expectEqualStrings("ok", &buf);
}
