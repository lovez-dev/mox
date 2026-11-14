//! 静态文件响应与异步读取；连接所有权和回收由 runtime 管理。
const mox_io = @import("mox_io");
const http = @import("../http.zig");
const types = @import("../types.zig");
const runtime = @import("runtime.zig");
const Connection = runtime.Connection;
const Loop = mox_io.Loop;
const Completion = mox_io.Completion;
const Response = types.Response;
const respond = runtime.respond;
const startSend = runtime.startSend;

pub fn serve(conn: *Connection, response: Response, keep_alive: bool) void {
    // file_path 若由 handler 用 ctx.gpa 分配，已由每请求 arena 统一回收；
    // 这里只复制到内联缓冲，不做 free（避免把 arena 内存交还给底层分配器）。
    const src = response.file_path;
    if (src.len == 0 or src.len >= conn.file_path_buf.len) {
        respond(conn, .{ .status = .internal_server_error, .body = "bad file path\n" }, false);
        return;
    }
    @memcpy(conn.file_path_buf[0..src.len], src);
    const path = conn.file_path_buf[0..src.len];

    const size = conn.loop.fileSize(path) catch {
        respond(conn, .{ .status = .not_found, .body = "not found\n" }, keep_alive);
        return;
    };
    conn.file_buf = conn.alloc.alloc(u8, @intCast(size)) catch {
        respond(conn, .{ .status = .internal_server_error, .body = "out of memory\n" }, false);
        return;
    };
    conn.keep_alive = keep_alive;
    conn.defer_status = response.status;
    conn.defer_ctype = response.content_type;
    conn.state = .reading_file;
    conn.file_work = mox_io.ReadFile.init(conn.loop.io, path, conn.file_buf, conn.loop.memory_fs.lookup(path));
    conn.file_work.work.c.callback = onFileRead;
    conn.loop.add(&conn.file_work.work.c);
}

fn onFileRead(loop: *Loop, c: *Completion) void {
    _ = loop;
    const w: *mox_io.Work = @fieldParentPtr("c", c);
    const conn: *Connection = @fieldParentPtr("file_work", @as(*mox_io.ReadFile, @fieldParentPtr("work", w)));
    conn.state = .handling;
    const data = conn.file_work.getResult() catch {
        conn.alloc.free(conn.file_buf);
        conn.file_buf = &.{};
        respond(conn, .{ .status = .internal_server_error, .body = "read error\n" }, false);
        return;
    };
    const wirebuf = conn.alloc.alloc(u8, data.len + 512) catch {
        conn.alloc.free(conn.file_buf);
        conn.file_buf = &.{};
        respond(conn, .{ .status = .internal_server_error, .body = "out of memory\n" }, false);
        return;
    };
    const wire = http.serialize(.{
        .status = conn.defer_status,
        .body = data,
        .content_type = conn.defer_ctype,
        .headers = &.{},
    }, conn.keep_alive, conn.head_only, wirebuf) catch {
        conn.alloc.free(wirebuf);
        conn.alloc.free(conn.file_buf);
        conn.file_buf = &.{};
        respond(conn, .{ .status = .internal_server_error, .body = "response too large\n" }, false);
        return;
    };
    conn.alloc.free(conn.file_buf);
    conn.file_buf = &.{};
    conn.send_owned = wirebuf;
    startSend(conn, wire);
}
