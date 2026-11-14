//! WebSocket 握手与帧收发；连接所有权和回收由 runtime 管理。
const std = @import("std");
const mox_io = @import("mox_io");
const http = @import("../http.zig");
const types = @import("../types.zig");
const runtime = @import("runtime.zig");
const Connection = runtime.Connection;
const Loop = mox_io.Loop;
const Completion = mox_io.Completion;
const NetRecv = mox_io.NetRecv;
const NetSend = mox_io.NetSend;
const respond = runtime.respond;
const destroyConn = runtime.destroyConn;
const disarmIdle = runtime.disarmIdle;

/// WebSocket 握手魔数（RFC 6455 §1.3）。
const WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
/// 101 Switching Protocols 响应模板（固定头，不经过 respond 路径）。
const WS_HANDSHAKE_HEAD =
    "HTTP/1.1 101 Switching Protocols\r\n" ++
    "Upgrade: websocket\r\n" ++
    "Connection: Upgrade\r\n" ++
    "Sec-WebSocket-Accept: ";

/// 接受到 WebSocket 升级请求：验证头、计算 Accept、发 101、转为 ws 状态。
pub fn upgrade(conn: *Connection, req: *const http.Request, handler: types.WsHandler) void {
    // 检查必要头部
    const key = req.header("sec-websocket-key") orelse {
        respond(conn, .{ .status = .bad_request, .body = "missing Sec-WebSocket-Key\n" }, false);
        return;
    };
    const upgrade_hdr = req.header("upgrade") orelse "";
    if (!std.ascii.eqlIgnoreCase(upgrade_hdr, "websocket")) {
        respond(conn, .{ .status = .bad_request, .body = "not a WebSocket upgrade\n" }, false);
        return;
    }

    // 计算 Sec-WebSocket-Accept = Base64(SHA1(key + MAGIC))
    var accept_buf: [32]u8 = undefined;
    const accept = computeAccept(key, &accept_buf);

    // 组装 101 响应
    var hsbuf: [256]u8 = undefined;
    const hs = std.fmt.bufPrint(&hsbuf, "{s}{s}\r\n\r\n", .{ WS_HANDSHAKE_HEAD, accept }) catch {
        respond(conn, .{ .status = .internal_server_error, .body = "ws handshake too large\n" }, false);
        return;
    };

    // 切换状态并保存 handler
    conn.ws_handler = handler;
    conn.ws_recv_len = 0;
    conn.state = .ws;
    disarmIdle(conn);

    // 把握手响应复制到 send_owned 缓冲发出
    const wire = conn.alloc.dupe(u8, hs) catch {
        respond(conn, .{ .status = .internal_server_error, .body = "out of memory\n" }, false);
        return;
    };
    conn.send_owned = wire;
    // 101 发完后 onSend → wsPostHandshake（不再走 HTTP keep-alive 路径）
    conn.keep_alive = false; // 标记：onSend 不 postRecv
    conn.send_wire = wire;
    conn.sent_len = 0;
    conn.send = NetSend.init(conn.socket, wire);
    conn.send.c.callback = wsOnHandshakeSent;
    conn.loop.add(&conn.send.c);
}

/// 101 握手发完后，立刻投递 WS 帧 recv。
fn wsOnHandshakeSent(loop: *Loop, c: *Completion) void {
    _ = loop;
    const conn: *Connection = @fieldParentPtr("send", @as(*NetSend, @fieldParentPtr("c", c)));
    if (conn.send_owned) |b| {
        conn.alloc.free(b);
        conn.send_owned = null;
    }
    conn.send_wire = &.{};
    conn.sent_len = 0;
    if (conn.send.getResult()) |_| {} else |_| {
        destroyConn(conn);
        return;
    }
    wsPostRecv(conn);
}

/// 投递 WS 帧 recv（持续接收）。
fn wsPostRecv(conn: *Connection) void {
    conn.state = .ws;
    conn.recv = NetRecv.init(conn.socket, conn.ws_recv_buf[conn.ws_recv_len..]);
    conn.recv.c.callback = wsOnRecv;
    conn.loop.add(&conn.recv.c);
}

/// WS 帧数据到达：解析并派发给 ws_handler。
fn wsOnRecv(loop: *Loop, c: *Completion) void {
    _ = loop;
    const conn: *Connection = @fieldParentPtr("recv", @as(*NetRecv, @fieldParentPtr("c", c)));
    const n = conn.recv.getResult() catch {
        destroyConn(conn);
        return;
    };
    if (n == 0) {
        destroyConn(conn);
        return;
    }
    conn.ws_recv_len += n;

    var pos: usize = 0;
    while (true) {
        const buf = conn.ws_recv_buf[0..conn.ws_recv_len];
        // 最小帧头 2 字节
        if (buf.len - pos < 2) break;
        const b0 = buf[pos];
        const b1 = buf[pos + 1];
        // final = b0 >> 7, opcode = b0 & 0xf
        const opcode: types.WsOpcode = @fromBackingInt(@intCast(b0 & 0x0f));
        const masked = (b1 & 0x80) != 0;
        var payload_len: usize = b1 & 0x7f;
        var hdr_len: usize = 2;
        if (payload_len == 126) {
            if (buf.len - pos < 4) break;
            payload_len = std.mem.readInt(u16, buf[pos + 2 ..][0..2], .big);
            hdr_len = 4;
        } else if (payload_len == 127) {
            if (buf.len - pos < 10) break;
            payload_len = @intCast(std.mem.readInt(u64, buf[pos + 2 ..][0..8], .big));
            hdr_len = 10;
        }
        const mask_len: usize = if (masked) 4 else 0;
        const total = hdr_len + mask_len + payload_len;
        if (buf.len - pos < total) break;
        // 解掩码（原地）
        const payload = buf[pos + hdr_len + mask_len ..][0..payload_len];
        if (masked) {
            const mask = buf[pos + hdr_len ..][0..4];
            for (payload, 0..) |*byte, i| byte.* ^= mask[i % 4];
        }
        const msg = types.WsMessage{ .opcode = opcode, .data = payload };
        // 调用 ws_handler
        if (conn.ws_handler) |wsh| {
            const ws_conn = types.WsConn{ .ptr = conn, .vtable = &ws_vtable };
            wsh(ws_conn, msg);
        }
        // close 帧：关连接
        if (opcode == .close) {
            destroyConn(conn);
            return;
        }
        pos += total;
    }

    // 把未处理的字节移到头部
    const remaining = conn.ws_recv_len - pos;
    if (pos > 0 and remaining > 0) {
        std.mem.copyForwards(u8, conn.ws_recv_buf[0..remaining], conn.ws_recv_buf[pos..conn.ws_recv_len]);
    }
    conn.ws_recv_len = remaining;

    if (conn.state == .ws) wsPostRecv(conn);
}

/// WsVtable 实现：发送帧。
fn wsSend(ptr: *anyopaque, opcode: types.WsOpcode, data: []const u8) void {
    const conn: *Connection = @ptrCast(@alignCast(ptr));
    if (conn.state != .ws) return;
    // 编码帧到 ws_send_buf（服务端不加掩码）
    var buf = &conn.ws_send_buf;
    var hdr_len: usize = 2;
    buf[0] = 0x80 | @backingInt(opcode); // FIN + opcode
    if (data.len < 126) {
        buf[1] = @intCast(data.len);
    } else if (data.len < 65536) {
        buf[1] = 126;
        std.mem.writeInt(u16, buf[2..4], @intCast(data.len), .big);
        hdr_len = 4;
    } else {
        buf[1] = 127;
        std.mem.writeInt(u64, buf[2..10], @intCast(data.len), .big);
        hdr_len = 10;
    }
    const total = hdr_len + data.len;
    if (total > buf.len) return; // 超缓冲区：静默丢弃（生产应分片）
    @memcpy(buf[hdr_len..][0..data.len], data);
    // 同步发送（WS 帧发送走同一 conn.send / startSend 路径）
    // 为简化：先用 send_owned 路径（alloc 分配，onSend 释放，发完后继续 wsPostRecv）
    const wire = conn.alloc.dupe(u8, buf[0..total]) catch return;
    conn.send_owned = wire;
    conn.send_wire = wire;
    conn.sent_len = 0;
    conn.send = NetSend.init(conn.socket, wire);
    conn.send.c.callback = wsOnFrameSent;
    conn.loop.add(&conn.send.c);
}

fn wsOnFrameSent(loop: *Loop, c: *Completion) void {
    _ = loop;
    const conn: *Connection = @fieldParentPtr("send", @as(*NetSend, @fieldParentPtr("c", c)));
    if (conn.send_owned) |b| {
        conn.alloc.free(b);
        conn.send_owned = null;
    }
    conn.send_wire = &.{};
    conn.sent_len = 0;
    _ = conn.send.getResult() catch {
        destroyConn(conn);
        return;
    };
    // 发完后不重新 recv（recv 已在飞），什么都不做。
}

/// WsVtable 实现：发 close 帧并销毁连接。
fn wsClose(ptr: *anyopaque) void {
    const conn: *Connection = @ptrCast(@alignCast(ptr));
    destroyConn(conn);
}

const ws_vtable = types.WsVtable{
    .send = wsSend,
    .close = wsClose,
};

// ============================================================================
// SSE 实现
// ============================================================================

/// SSE 响应头（Content-Type + no-cache + keep-alive）。
pub fn computeAccept(key: []const u8, out: *[32]u8) []const u8 {
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key);
    sha.update(WS_MAGIC);
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    return std.base64.standard.Encoder.encode(out, &digest);
}
