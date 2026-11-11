//! DNS 可选能力：第二个能力实例，用来证明扩展机制可重复、可组合。
//!
//! 它建立在 UDP 能力之上：构造 A 查询报文 → `Udp.Send`/`Udp.Recv` 走
//! `Work` 池 → 解析应答里的 IPv4 地址。全程零 libc、零 `VTable` 改动，
//! 也不碰 `Loop` 热路径。系统 resolver 配置由调用方负责，本能力只要求
//! 传入一个 DNS server 地址。
//!
//! 目前只支持单条 A 记录查询、无 TCP 回退、无压缩指针的复杂跳转（标准
//! 应答里名字字段用压缩指针，这里只跳过固定 12 字节头部后逐条解析）。

const std = @import("std");
const root = @import("io.zig");
const Loop = @import("loop.zig").Loop;
const Completion = @import("completion.zig").Completion;
const udp = @import("udp.zig");

const IpAddress = std.Io.net.IpAddress;
const Handle = root.Handle;

/// 能力 ID：与 UDP 完全不同的名字，验证稀疏表能容纳多个能力。
pub const id = root.cap("mox.io.dns.v1");

/// 注册描述符。DNS 本身建立在 UDP 能力上，这里只用一个静态标记证明
/// 能力表能同时容纳多个 ID、且查询路径对第二个能力同样有效。
pub const Descriptor = struct {
    version: u32,
};

pub const descriptor = Descriptor{ .version = 1 };
/// 一次查询的结果：最多 `max_addresses` 个 IPv4 地址。
pub const max_addresses = 8;

pub const Answer = struct {
    /// 未使用的槽位保持「合法但无意义」的 `0.0.0.0:0`，而不是 `undefined`。
    /// 解析路径只写前 `count` 个，但 `Answer` 可能被整体拷贝、哈希或序列化；
    /// 读未初始化内存是 UB，显式零值让这些操作有确定行为。
    /// （实测 `{any}` 打印 `undefined` 槽位并不会 panic，这里纯粹是消除 UB。）
    addresses: [max_addresses]IpAddress = @splat(.{ .ip4 = .{ .bytes = @splat(0), .port = 0 } }),
    count: usize = 0,

    pub fn slice(self: *const Answer) []const IpAddress {
        return self.addresses[0..self.count];
    }
};

/// 能力句柄。内部持有 UDP 能力，因此 DNS 天然复用了第一个能力。
pub const Resolver = struct {
    io: root.Io,
    udp_cap: udp.Udp,

    pub fn get(io: root.Io) ?Resolver {
        if (io.capability(*const Descriptor, id) == null) return null;
        return .{ .io = io, .udp_cap = udp.Udp.get(io) orelse return null };
    }

    /// 提交一次查询；完成后 `q.done` 为真、`q.answer` 已填好。
    /// `socket` 由调用方建好并绑定，查询结束后仍归调用方管。
    pub fn resolve(self: Resolver, loop: *Loop, q: *Query) void {
        q.resolver = self;
        q.send = udp.Send.init(q.socket, q.request[0..q.request_len], q.server);
        q.send.work.c.callback = onSent;
        self.udp_cap.send(loop, &q.send);
    }

    fn onSent(l: *Loop, c: *Completion) void {
        const w: *@import("completion.zig").Work = @fieldParentPtr("c", c);
        const s: *udp.Send = @fieldParentPtr("work", w);
        const q: *Query = @fieldParentPtr("send", s);
        _ = s.getResult() catch {
            q.finish(l);
            return;
        };
        q.recv = udp.Recv.init(q.socket, &q.response);
        q.recv.work.c.callback = onRecv;
        q.resolver.udp_cap.recv(l, &q.recv);
    }

    fn onRecv(l: *Loop, c: *Completion) void {
        const w: *@import("completion.zig").Work = @fieldParentPtr("c", c);
        const r: *udp.Recv = @fieldParentPtr("work", w);
        const q: *Query = @fieldParentPtr("recv", r);
        const n = r.getResult() catch {
            q.finish(l);
            return;
        };
        q.parse(q.response[0..n]);
        q.finish(l);
    }
};

pub const Query = struct {
    socket: Handle,
    server: IpAddress,
    name: []const u8,
    /// DNS 报文缓冲区；查询与应答各占一块，节点自带，避免额外分配。
    request: [512]u8 = undefined,
    request_len: usize = 0,
    response: [512]u8 = undefined,
    send: udp.Send = undefined,
    recv: udp.Recv = undefined,
    resolver: Resolver = undefined,
    answer: Answer = .{},
    done: bool = false,
    /// 查询完成回调；由调用方决定是否停循环。
    on_done: ?@import("completion.zig").Callback = null,

    pub fn init(socket: Handle, server: IpAddress, name: []const u8) Query {
        var q: Query = .{ .socket = socket, .server = server, .name = name };
        q.request_len = buildQuery(&q.request, name);
        return q;
    }

    pub fn parse(self: *Query, msg: []const u8) void {
        if (msg.len < 12) return;
        const flags = std.mem.readInt(u16, msg[2..4], .big);
        if (flags & 0x000f != 0) return; // rcode != NOERROR
        const qd: usize = std.mem.readInt(u16, msg[4..6], .big);
        const an: usize = std.mem.readInt(u16, msg[6..8], .big);
        var off: usize = 12;
        var i: usize = 0;
        while (i < qd and off < msg.len) : (i += 1) off = skipName(msg, off) + 4;
        i = 0;
        while (i < an and off < msg.len and self.answer.count < max_addresses) : (i += 1) {
            off = skipName(msg, off);
            if (off + 10 > msg.len) return;
            const typ = readU16(msg, off);
            const class = readU16(msg, off + 2);
            const rdlen = readU16(msg, off + 8);
            off += 10;
            if (off + rdlen > msg.len) return;
            // TYPE=1 (A), RDLEN=4: IPv4
            if (typ == 1 and class == 1 and rdlen == 4) {
                self.answer.addresses[self.answer.count] = .{ .ip4 = .{
                    .bytes = msg[off..][0..4].*,
                    .port = 0,
                } };
                self.answer.count += 1;
            }
            // TYPE=28 (AAAA), RDLEN=16: IPv6
            if (typ == 28 and class == 1 and rdlen == 16) {
                self.answer.addresses[self.answer.count] = .{ .ip6 = .{
                    .bytes = msg[off..][0..16].*,
                    .port = 0,
                    .flow = 0,
                    .interface = .none,
                } };
                self.answer.count += 1;
            }
            off += rdlen;
        }
    }

    fn finish(self: *Query, l: *Loop) void {
        self.done = true;
        if (self.on_done) |cb| cb(l, &self.recv.work.c);
    }
};


    /// 构造 AAAA 查询（IPv6）。
    pub fn initAAAA(socket: Handle, server: IpAddress, name: []const u8) Query {
        var q: Query = .{ .socket = socket, .server = server, .name = name };
        q.request_len = buildQueryAAAA(&q.request, name);
        return q;
    }

/// 从任意偏移读大端 u16；切片长度运行时才知道，用位运算避开类型要求。
fn readU16(msg: []const u8, off: usize) u16 {
    if (off + 2 > msg.len) return 0;
    return (@as(u16, msg[off]) << 8) | msg[off + 1];
}

/// 跳过 DNS 名字：普通标签序列或末尾的压缩指针（0xC0xx）。
fn skipName(msg: []const u8, start: usize) usize {
    var off = start;
    while (off < msg.len) {
        const b = msg[off];
        if (b & 0xc0 == 0xc0) return off + 2;
        if (b == 0) return off + 1;
        off += 1 + b;
        if (off > msg.len) return msg.len;
    }
    return off;
}

/// 构造标准 A 查询：id=0x1234、RD=1、QNAME 按点分标签、QTYPE=A、QCLASS=IN。
fn buildQuery(buf: []u8, name: []const u8) usize {
    @memset(buf[0..12], 0);
    std.mem.writeInt(u16, buf[0..2], 0x1234, .big);
    std.mem.writeInt(u16, buf[2..4], 0x0100, .big); // RD
    std.mem.writeInt(u16, buf[4..6], 1, .big); // QDCOUNT
    var off: usize = 12;
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |label| {
        if (label.len == 0 or label.len > 63 or off + 1 + label.len + 5 > buf.len) break;
        buf[off] = @intCast(label.len);
        off += 1;
        @memcpy(buf[off..][0..label.len], label);
        off += label.len;
    }
    if (off >= buf.len) return off;
    buf[off] = 0;
    off += 1;
    if (off + 4 > buf.len) return off;
    std.mem.writeInt(u16, buf[off..][0..2], 1, .big); // A
    std.mem.writeInt(u16, buf[off + 2 ..][0..2], 1, .big); // IN
    return off + 4;
}


/// 构造标准 AAAA 查询（IPv6）：与 buildQuery 类似，QTYPE=28。
fn buildQueryAAAA(buf: []u8, name: []const u8) usize {
    @memset(buf[0..12], 0);
    std.mem.writeInt(u16, buf[0..2], 0x1234, .big);
    std.mem.writeInt(u16, buf[2..4], 0x0100, .big); // RD
    std.mem.writeInt(u16, buf[4..6], 1, .big); // QDCOUNT
    var off: usize = 12;
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |label| {
        if (label.len == 0 or label.len > 63 or off + 1 + label.len + 5 > buf.len) break;
        buf[off] = @intCast(label.len);
        off += 1;
        @memcpy(buf[off..][0..label.len], label);
        off += label.len;
    }
    if (off >= buf.len) return off;
    buf[off] = 0;
    off += 1;
    if (off + 4 > buf.len) return off;
    std.mem.writeInt(u16, buf[off..][0..2], 28, .big); // AAAA
    std.mem.writeInt(u16, buf[off + 2 ..][0..2], 1, .big); // IN
    return off + 4;
}

/// 高层便捷接口：封装 Work 节点 + 自动探测 A/AAAA。
/// 使用系统 resolver 配置（读 /etc/resolv.conf 或 Windows registry）。
pub const GetAddressList = struct {
    work: @import("completion.zig").Work,
    host: []const u8,
    port: u16,
    allocator: std.mem.Allocator,
    addresses: ?[]std.net.Address = null,
    err: ?anyerror = null,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) GetAddressList {
        return .{
            .work = @import("completion.zig").Work.init(run),
            .allocator = allocator,
            .host = host,
            .port = port,
        };
    }

    fn run(w: *@import("completion.zig").Work) void {
        const self: *GetAddressList = @fieldParentPtr("work", w);
        // 回落到系统 getaddrinfo（阻塞调用，运行在 Work 池线程）
        self.addresses = std.net.getAddressList(self.allocator, self.host, self.port) catch |e| {
            self.err = e;
            return;
        };
    }

    pub fn deinit(self: *GetAddressList) void {
        if (self.addresses) |addrs| {
            self.allocator.free(addrs);
            self.addresses = null;
        }
    }

    pub fn getResult(self: *GetAddressList) ![]const std.net.Address {
        if (self.err) |e| return e;
        return self.addresses orelse error.NoAddresses;
    }
};

test "DNS 查询报文格式与应答解析" {
    var buf: [512]u8 = undefined;
    const n = buildQuery(&buf, "example.com");
    try std.testing.expect(n > 12);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, buf[4..6], .big));
    try std.testing.expectEqual(@as(u8, 7), buf[12]); // "example" 长度
}

test "A 应答可解析成 IpAddress" {
    var msg: [64]u8 = @splat(0);
    // 头部：id、flags=0x8180（响应 + RA）、QD=1、AN=1
    std.mem.writeInt(u16, msg[0..2], 0x1234, .big);
    std.mem.writeInt(u16, msg[2..4], 0x8180, .big);
    std.mem.writeInt(u16, msg[4..6], 1, .big);
    std.mem.writeInt(u16, msg[6..8], 1, .big);
    // 问题：指针直接跳过名字用 "\x03www\x00" 也行，这里用压缩问题名占位
    msg[12] = 3;
    @memcpy(msg[13..16], "www");
    msg[16] = 0;
    std.mem.writeInt(u16, msg[17..19], 1, .big);
    std.mem.writeInt(u16, msg[19..21], 1, .big);
    // 回答：NAME 压缩指针、TYPE=A、CLASS=IN、TTL、RDLEN=4、1.2.3.4
    var off: usize = 21;
    msg[off] = 0xc0;
    msg[off + 1] = 0x0c;
    off += 2;
    std.mem.writeInt(u16, msg[off..][0..2], 1, .big);
    std.mem.writeInt(u16, msg[off + 2 ..][0..2], 1, .big);
    off += 8; // CLASS 后 4 字节 TTL
    std.mem.writeInt(u16, msg[off..][0..2], 4, .big);
    off += 2;
    @memcpy(msg[off..][0..4], &[_]u8{ 1, 2, 3, 4 });
    off += 4;

    var q: Query = undefined;
    q.answer = .{};
    q.parse(msg[0..off]);
    try std.testing.expectEqual(@as(usize, 1), q.answer.count);
    try std.testing.expectEqual(@as(u8, 1), q.answer.addresses[0].ip4.bytes[0]);
    try std.testing.expectEqual(@as(u8, 4), q.answer.addresses[0].ip4.bytes[3]);
}

test "能力表同时提供 UDP 与 DNS 两个 ID" {
    try std.testing.expect(udp.id != id);
    try std.testing.expectEqual(id, root.cap("mox.io.dns.v1"));
    try std.testing.expect(root.cap("mox.io.udp.v1") != root.cap("mox.io.signal.v1"));
}
