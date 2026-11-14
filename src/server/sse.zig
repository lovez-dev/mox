//! SSE 推送与 tick 调度；连接所有权和回收由 runtime 管理。
const std = @import("std");
const mox_io = @import("mox_io");
const http = @import("../http.zig");
const types = @import("../types.zig");
const runtime = @import("runtime.zig");
const Connection = runtime.Connection;
const Loop = mox_io.Loop;
const Completion = mox_io.Completion;
const NetSend = mox_io.NetSend;
const Timer = mox_io.Timer;
const respond = runtime.respond;
const destroyConn = runtime.destroyConn;
const disarmIdle = runtime.disarmIdle;
const disarmRequestTimeout = runtime.disarmRequestTimeout;
const noopDispose = runtime.noopDispose;

const SSE_HEADERS =
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Type: text/event-stream; charset=utf-8\r\n" ++
    "Cache-Control: no-cache\r\n" ++
    "Connection: keep-alive\r\n" ++
    "X-Accel-Buffering: no\r\n" ++
    "\r\n";

/// 开启 SSE 流：发 SSE 头，然后进入 SSE 推送循环。
pub fn start(conn: *Connection, req: *const http.Request, handler: types.SseHandler) void {
    _ = req;
    conn.sse_handler = handler;
    conn.sse_tick_ms = 1000;
    conn.sse_tick_armed = false;
    conn.state = .sse;
    disarmIdle(conn);
    disarmRequestTimeout(conn); // SSE 是长连接，不能被单次请求超时打断

    const wire = conn.alloc.dupe(u8, SSE_HEADERS) catch {
        respond(conn, .{ .status = .internal_server_error, .body = "out of memory\n" }, false);
        return;
    };
    conn.send_owned = wire;
    conn.send_wire = wire;
    conn.sent_len = 0;
    conn.send = NetSend.init(conn.socket, wire);
    conn.send.c.callback = sseOnHeadersSent;
    conn.loop.add(&conn.send.c);
}
fn sseOnHeadersSent(loop: *Loop, c: *Completion) void {
    _ = loop;
    const conn: *Connection = @fieldParentPtr("send", @as(*NetSend, @fieldParentPtr("c", c)));
    if (conn.send_owned) |b| {
        conn.alloc.free(b);
        conn.send_owned = null;
    }
    conn.send_wire = &.{};
    _ = conn.send.getResult() catch {
        destroyConn(conn);
        return;
    };
    conn.state = .sse;
    ssePump(conn);
}

/// 撤销 SSE tick 定时器。定时器还在堆里时 `Loop.cancel` 会同步摘除并回收，
/// 不会留下指向已释放 conn 的完成包；`noopDispose` 不触碰连接对象。
pub fn disarmTick(conn: *Connection) void {
    if (!conn.sse_tick_armed) return;
    conn.sse_tick_armed = false;
    conn.loop.cancel(&conn.sse_tick.c, @ptrCast(conn), noopDispose);
}

/// 武装一次 SSE tick：原地复用每连接的 `sse_tick` 节点（栈上新建会悬空）。
fn armSseTick(conn: *Connection) void {
    if (conn.sse_tick_ms == 0) return;
    disarmTick(conn);
    conn.sse_tick = Timer.init(conn.sse_tick_ms);
    conn.sse_tick.c.callback = onSseTick;
    conn.sse_tick_armed = true;
    conn.loop.add(&conn.sse_tick.c);
}

/// tick 到点：重新 pump 一次 handler。
fn onSseTick(loop: *Loop, c: *Completion) void {
    _ = loop;
    const t: *Timer = @fieldParentPtr("c", c);
    const conn: *Connection = @fieldParentPtr("sse_tick", t);
    conn.sse_tick_armed = false; // 已从定时器堆弹出
    if (conn.state != .sse or conn.sse_handler == null) {
        destroyConn(conn);
        return;
    }
    ssePump(conn);
}

/// 调用一次 sse_handler，并按结果安排下一步：
/// - 返回 false：结束流（若 send 在飞则延迟到发送完成再关）。
/// - 返回 true 且本次调用了 writer.send()：由 sseOnEventSent 重新 pump。
/// - 返回 true 且本次没有 send：武装 tick 定时器，到点重新 pump。
fn ssePump(conn: *Connection) void {
    disarmTick(conn); // 每次 pump 先撤掉上一轮可能残留的 tick
    if (conn.sse_handler == null or conn.state != .sse) {
        if (conn.state != .closing) destroyConn(conn);
        return;
    }
    const writer = types.SseWriter{ .ptr = conn, .vtable = &sse_vtable };
    // 记录调用前的状态：send 会把 state 改成 .sending。
    const state_before = conn.state;
    const keep_going = conn.sse_handler.?(writer);
    if (!keep_going) {
        if (conn.state == state_before) {
            // 没有发送在飞：立即关
            destroyConn(conn);
        } else {
            // send 在飞：清 handler，sseOnEventSent 看到 null 后关闭。
            conn.sse_handler = null;
        }
        return;
    }
    if (conn.state == .sse) {
        // handler 返回 true 但本次没有 send：靠 tick 定时器驱动下一次。
        armSseTick(conn);
    }
    // 否则 send 在飞，由 sseOnEventSent 驱动下一次 pump。
}

/// SseVtable 实现：推送一个 event。
fn sseSend(ptr: *anyopaque, event: []const u8, data: []const u8) void {
    const conn: *Connection = @ptrCast(@alignCast(ptr));
    if (conn.state != .sse) return;
    // 本次 pump 内已有 send 提交，撤销可能存在的 tick（到点回调会重复 pump）。
    disarmTick(conn);
    // 格式：event: <name>\r\ndata: <data>\r\n\r\n
    // 若 event 为空只写 data: 行
    var buf = &conn.sse_send_buf;
    var n: usize = 0;
    if (event.len > 0) {
        const s = std.fmt.bufPrint(buf[n..], "event: {s}\r\n", .{event}) catch return;
        n += s.len;
    }
    const s2 = std.fmt.bufPrint(buf[n..], "data: {s}\r\n\r\n", .{data}) catch return;
    n += s2.len;

    const wire = conn.alloc.dupe(u8, buf[0..n]) catch return;
    conn.send_owned = wire;
    conn.send_wire = wire;
    conn.sent_len = 0;
    conn.state = .sending;
    conn.send = NetSend.init(conn.socket, wire);
    conn.send.c.callback = sseOnEventSent;
    conn.loop.add(&conn.send.c);
}

fn sseOnEventSent(loop: *Loop, c: *Completion) void {
    _ = loop;
    const conn: *Connection = @fieldParentPtr("send", @as(*NetSend, @fieldParentPtr("c", c)));
    if (conn.send_owned) |b| {
        conn.alloc.free(b);
        conn.send_owned = null;
    }
    conn.send_wire = &.{};
    _ = conn.send.getResult() catch {
        disarmTick(conn);
        destroyConn(conn);
        return;
    };
    conn.state = .sse;
    if (conn.sse_handler == null) {
        disarmTick(conn);
        destroyConn(conn);
        return;
    }
    ssePump(conn);
}

fn sseSetTick(ptr: *anyopaque, interval_ms: u32) void {
    const conn: *Connection = @ptrCast(@alignCast(ptr));
    conn.sse_tick_ms = interval_ms;
    // 若当前正挂着一个 tick，用新周期立即重挂，避免旧周期再触发一次。
    if (conn.sse_tick_armed) armSseTick(conn);
}

fn sseClose(ptr: *anyopaque) void {
    const conn: *Connection = @ptrCast(@alignCast(ptr));
    disarmTick(conn);
    if (conn.state == .sending) {
        // 发送在飞，推迟到 sseOnEventSent
        conn.sse_handler = null;
    } else {
        destroyConn(conn);
    }
}

const sse_vtable = types.SseVtable{
    .send = sseSend,
    .set_tick = sseSetTick,
    .close = sseClose,
};
