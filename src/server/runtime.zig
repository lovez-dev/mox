//! Completion-driven connections; buffers survive all operation and close results.

const std = @import("std");
const builtin = @import("builtin");
const io = @import("mox_io");
const t = io.types;
const types = @import("../types.zig");
const http = @import("../http.zig");
const routing = @import("../router.zig");
const wire = @import("session.zig");
const ws = @import("../websocket/protocol.zig");
const framing = @import("proxy_framing.zig");
const proxy = @import("proxy_protocol.zig");
const metrics = @import("metrics.zig");
const Observation = @import("observation.zig").Observation;
const Budget = @import("memory.zig").Budget;
const Admission = @import("admission.zig").Admission;

pub fn serve(config: types.Config) !void {
    if (config.max_connections == 0 or config.max_connections > 1_000_000) return error.InvalidConfiguration;
    if (config.control) |control| {
        if (control.state.cmpxchgStrong(.idle, .running, .acq_rel, .acquire) != null) return error.ControlAlreadyUsed;
    }
    defer if (config.control) |control| control.state.store(.stopped, .release);
    switch (config.backend) {
        .default => try run(io.DefaultLoop, config),
        .epoll => if (builtin.os.tag == .linux) try run(io.Loop(io.backends.Epoll), config) else return error.UnsupportedBackend,
        .uring => if (builtin.os.tag == .linux) try run(io.Loop(io.backends.Uring), config) else return error.UnsupportedBackend,
        .kqueue => if (builtin.os.tag == .macos or builtin.os.tag == .freebsd) try run(io.Loop(io.backends.Kqueue), config) else return error.UnsupportedBackend,
        .iocp => if (builtin.os.tag == .windows) try run(io.Loop(io.backends.Iocp), config) else return error.UnsupportedBackend,
    }
}

fn run(comptime Loop: type, config: types.Config) !void {
    var server: Server(Loop) = undefined;
    try server.init(config);
    defer server.deinit();
    try server.run();
}

fn Server(comptime Loop: type) type {
    return struct {
        const Self = @This();
        const Mode = enum { reading, response, stream, file, websocket, sse, proxy };

        config: types.Config,
        loop: Loop,
        budget: Budget,
        router: routing.Router,
        admission: Admission,
        connections: std.ArrayList(*Connection) = .empty,
        listener: ?t.Handle = null,
        listener_pending: usize = 0,
        accepting: bool = false,
        draining: bool = false,
        drain_until: u64 = 0,
        retry_accept: u64 = 0,

        const Connection = struct {
            server: *Self,
            handle: ?t.Handle,
            file: ?t.Handle = null,
            upstream: ?t.Handle = null,
            pending: usize = 0,
            closing: bool = false,
            mode: Mode = .reading,
            receiving: bool = false,
            sending: bool = false,
            keep_alive: bool = false,
            arena: std.heap.ArenaAllocator,
            input: std.ArrayList(u8) = .empty,
            output: std.ArrayList(u8) = .empty,
            // Callbacks may queue bytes without relocating a buffer still used by sendAll.
            tx: std.ArrayList(u8) = .empty,
            scratch: [16 * 1024]u8 = undefined,
            file_buffer: [64 * 1024]u8 = undefined,
            request: ?http.Request = null,
            params: types.Params = .{},
            entry: ?routing.Entry = null,
            body_state: ?*anyopaque = null,
            body_initialized: bool = false,
            body_received: usize = 0,
            consumed: usize = 0,
            chunk_decoder: http.ChunkedDecoder = .{},
            admitted: bool = false,
            observation: Observation = .{},
            response: types.Response = .{},
            stream_done: bool = false,
            file_size: u64 = 0,
            file_offset: u64 = 0,
            ws_handler: ?types.WsHandler = null,
            fragments: std.ArrayList(u8) = .empty,
            fragment_opcode: ?types.WsOpcode = null,
            utf8: ws.Utf8 = .{},
            ws_closing: bool = false,
            sse_tick: u32 = 1000,
            sse_due: u64 = 0,
            sse_finished: bool = false,
            ws_deadline: u64 = 0,
            proxy_input: std.ArrayList(u8) = .empty,
            proxy_request: []const u8 = "",
            proxy_deadline: ?u64 = null,

            fn allocator(c: *Connection) std.mem.Allocator {
                return c.server.budget.allocator();
            }

            fn options(c: *Connection) t.SubmitOptions {
                const cfg = c.server.config;
                // HTTP deadlines end at upgrade. Session liveness follows peer I/O and explicit shutdown.
                if (c.mode == .websocket or c.mode == .sse) return .{ .tag = @intFromPtr(c) };
                const deadline: ?u64 = if (c.observation.active and cfg.request_timeout_ms != 0)
                    c.observation.started_ms * 1_000_000 + @as(u64, cfg.request_timeout_ms) * 1_000_000
                else if (cfg.idle_timeout_ms != 0) c.server.loop.now() + @as(u64, cfg.idle_timeout_ms) * 1_000_000 else null;
                return .{ .tag = @intFromPtr(c), .deadline = deadline };
            }

            fn context(c: *Connection) types.Context {
                return .{ .gpa = c.arena.allocator(), .request = &c.request.?, .params = &c.params, .body = c.request.?.body };
            }

            fn receive(c: *Connection) !void {
                if (c.closing or c.receiving) return;
                _ = try c.server.loop.recv(c.handle.?, &c.scratch, c.options());
                c.pending += 1;
                c.receiving = true;
            }

            fn flush(c: *Connection) !void {
                if (c.closing or c.sending or c.output.items.len == 0) return;
                std.mem.swap(std.ArrayList(u8), &c.output, &c.tx);
                _ = try c.server.loop.sendAll(c.handle.?, c.tx.items, c.options());
                c.pending += 1;
                c.sending = true;
            }

            fn closeHandle(c: *Connection, handle: *?t.Handle) void {
                if (handle.*) |h| {
                    // The reserved close completion follows every operation referencing this handle.
                    c.server.loop.close(h, .cancel, @intFromPtr(c)) catch |err| if (err != error.NativeFailure) @panic("invalid live handle");
                    c.pending += 1;
                    handle.* = null;
                }
            }

            fn close(c: *Connection) void {
                if (c.closing) return;
                c.closing = true;
                c.closeHandle(&c.handle);
                c.closeHandle(&c.file);
                c.closeHandle(&c.upstream);
            }

            fn removeInput(c: *Connection, count: usize) void {
                std.mem.copyForwards(u8, c.input.items[0 .. c.input.items.len - count], c.input.items[count..]);
                c.input.items.len -= count;
            }

            fn finishObservation(c: *Connection, complete: bool) void {
                if (c.observation.finish(c.server.loop.now() / 1_000_000, complete)) |event| {
                    if (c.server.config.on_request_complete) |callback| callback(event);
                }
                if (c.admitted) {
                    c.server.admission.release();
                    c.admitted = false;
                }
            }

            fn releaseRequest(c: *Connection, end: types.Stream.End) void {
                if (c.response.stream) |stream| {
                    c.response.stream = null;
                    if (stream.close) |callback| callback(stream.state, end);
                }
                if (c.body_initialized) {
                    c.body_initialized = false;
                    if (c.entry.?.body_stream_deinit) |callback| {
                        var ctx = c.context();
                        callback(&ctx, c.body_state);
                    }
                }
            }

            fn finish(c: *Connection) !void {
                c.releaseRequest(.complete);
                c.finishObservation(true);
                if (!c.keep_alive or c.server.draining) {
                    c.close();
                    return;
                }
                c.removeInput(c.consumed);
                _ = c.arena.reset(.free_all);
                c.request = null;
                c.entry = null;
                c.params = .{};
                c.body_state = null;
                c.body_received = 0;
                c.consumed = 0;
                c.response = .{};
                c.chunk_decoder = .{};
                c.mode = .reading;
                try c.process();
            }

            fn fail(c: *Connection, status: std.http.Status) anyerror!void {
                c.releaseRequest(.failed);
                c.keep_alive = false;
                try c.respond(.{ .status = status, .body = @tagName(status) });
            }

            fn process(c: *Connection) !void {
                if (c.server.draining and c.request == null) {
                    c.close();
                    return;
                }
                if (c.request == null) {
                    if (c.input.items.len != 0) c.observation.start(c.server.loop.now() / 1_000_000);
                    const limit = if (c.server.config.max_body_size == 0) std.math.maxInt(usize) else c.server.config.max_body_size;
                    switch (http.parseHeadWithLimit(c.input.items, limit)) {
                        .incomplete => {
                            try c.receive();
                            return;
                        },
                        .malformed => {
                            try c.fail(.bad_request);
                            return;
                        },
                        .expectation_failed => {
                            try c.fail(.expectation_failed);
                            return;
                        },
                        .body_too_large => {
                            try c.fail(.payload_too_large);
                            return;
                        },
                        .request => |req| {
                            const head_len = (std.mem.indexOf(u8, c.input.items, "\r\n\r\n") orelse unreachable) + 4;
                            const copy = try c.arena.allocator().dupe(u8, c.input.items[0..head_len]);
                            c.request = http.parseHeadWithLimit(copy, limit).request;
                            c.removeInput(head_len);
                            c.keep_alive = req.keep_alive;
                            c.observation.start(c.server.loop.now() / 1_000_000);
                            c.observation.identify(req.method, c.request.?.path);
                            if (c.server.admission.acquire(c.server.loop.now() / 1_000_000)) |status| {
                                try c.fail(status);
                                return;
                            }
                            c.admitted = true;
                            c.entry = c.server.router.matchEntry(req.method, c.request.?.path, &c.params);
                            if (c.entry) |entry| if (entry.on_body != null) {
                                if (req.chunked) {
                                    try c.fail(.not_implemented);
                                    return;
                                }
                                var ctx = c.context();
                                c.body_state = if (entry.body_stream_init) |callback| try callback(&ctx) else null;
                                c.body_initialized = true;
                            };
                        },
                    }
                }
                const req = &c.request.?;
                if (c.body_initialized) {
                    const size = @min(c.input.items.len, req.body_expected - c.body_received);
                    const final = c.body_received + size == req.body_expected;
                    if (size != 0 or final) {
                        var ctx = c.context();
                        c.entry.?.on_body.?(&ctx, c.body_state, c.input.items[0..size], final) catch |err| {
                            c.observation.error_name = @errorName(err);
                            try c.fail(.bad_request);
                            return;
                        };
                        c.body_received += size;
                        c.removeInput(size);
                    }
                    if (!final) {
                        try c.receive();
                        return;
                    }
                    req.body = "";
                    req.body_complete = true;
                } else if (req.chunked) {
                    const limit = if (c.server.config.max_body_size == 0) std.math.maxInt(usize) else c.server.config.max_body_size;
                    switch (c.chunk_decoder.decode(c.arena.allocator(), c.input.items, limit)) {
                        .incomplete => {
                            try c.receive();
                            return;
                        },
                        .malformed => {
                            try c.fail(.bad_request);
                            return;
                        },
                        .body_too_large => {
                            try c.fail(.payload_too_large);
                            return;
                        },
                        .done => |body| {
                            req.body = body.body;
                            req.body_complete = true;
                            c.consumed = body.consumed;
                        },
                    }
                } else {
                    if (c.input.items.len < req.body_expected) {
                        try c.receive();
                        return;
                    }
                    req.body = c.input.items[0..req.body_expected];
                    req.body_complete = true;
                    c.consumed = req.body_expected;
                }
                if (c.entry) |entry| if (entry.proxy) |options_| {
                    try c.startProxy(options_);
                    return;
                };
                var ctx = c.context();
                var response: types.Response = undefined;
                if (c.entry) |entry| {
                    response = entry.handler(&ctx) catch |err| blk: {
                        metrics.requestFailed();
                        c.observation.error_name = @errorName(err);
                        break :blk c.server.config.error_handler(&ctx, err);
                    };
                } else {
                    var methods: [16]std.http.Method = undefined;
                    const count = c.server.router.allowedMethods(req.path, &methods);
                    if (count != 0) {
                        var allow: std.ArrayList(u8) = .empty;
                        for (methods[0..count], 0..) |method, i| {
                            if (i != 0) try allow.appendSlice(ctx.gpa, ", ");
                            try allow.appendSlice(ctx.gpa, @tagName(method));
                        }
                        const headers_ = try ctx.gpa.alloc(types.Header, 1);
                        headers_[0] = .{ .name = "allow", .value = allow.items };
                        response = .{ .status = .method_not_allowed, .headers = headers_ };
                    } else response = c.server.config.not_found(&ctx) catch |err| c.server.config.error_handler(&ctx, err);
                }
                try c.respond(response);
            }

            fn headers(c: *Connection, response: types.Response, length: u64, chunked: bool) !void {
                var buffer: [http.max_head]u8 = undefined;
                const bytes = try http.serialize(.{ .status = response.status, .content_type = response.content_type, .headers = response.headers, .body_length = length, .chunked = chunked }, c.keep_alive and !c.server.draining, true, &buffer);
                try c.output.appendSlice(c.allocator(), bytes);
            }

            fn headOnly(c: *Connection) bool {
                return (if (c.request) |req| req.method == .HEAD else false) or !http.bodyAllowed(c.response.status);
            }

            fn chunkedAllowed(c: *Connection) bool {
                return c.request == null or std.mem.eql(u8, c.request.?.version, "HTTP/1.1");
            }

            fn respond(c: *Connection, response: types.Response) anyerror!void {
                c.response = response;
                c.observation.status = @intCast(@backingInt(response.status));
                c.mode = .response;
                if (@backingInt(response.status) < 200 and response.ws_handler == null) {
                    try c.fail(.internal_server_error);
                    return;
                }
                if (response.ws_handler) |handler| {
                    const req = c.request orelse return error.InvalidUpgrade;
                    const bytes = wire.websocketUpgrade(c.arena.allocator(), &req) catch {
                        try c.fail(.bad_request);
                        return;
                    };
                    c.ws_handler = handler;
                    c.mode = .websocket;
                    c.observation.status = 101;
                    try c.output.appendSlice(c.allocator(), bytes);
                } else if (response.sse_handler != null and !c.headOnly()) {
                    if (!c.chunkedAllowed()) {
                        try c.fail(.http_version_not_supported);
                        return;
                    }
                    c.mode = .sse;
                    c.keep_alive = false;
                    var response_ = response;
                    response_.content_type = "text/event-stream";
                    try c.headers(response_, 0, c.chunkedAllowed());
                } else if (response.stream != null) {
                    if (!c.chunkedAllowed() and !c.headOnly()) {
                        try c.fail(.http_version_not_supported);
                        return;
                    }
                    c.mode = if (c.headOnly()) .response else .stream;
                    c.stream_done = false;
                    try c.headers(response, 0, c.chunkedAllowed());
                } else if (response.file_path.len != 0) {
                    if (c.server.config.assets) |assets| {
                        if (assets.readFile(std.mem.trimStart(u8, response.file_path, "/")) catch null) |data| {
                            try c.headers(response, data.len, false);
                            if (!c.headOnly()) try c.output.appendSlice(c.allocator(), data);
                            try c.flush();
                            return;
                        }
                    }
                    c.mode = .file;
                    _ = try c.server.loop.openFileAsync(response.file_path, .{}, c.options());
                    c.pending += 1;
                    return;
                } else {
                    try c.headers(response, response.body.len, false);
                    if (!c.headOnly()) try c.output.appendSlice(c.allocator(), response.body);
                }
                try c.flush();
            }

            fn afterSend(c: *Connection) !void {
                if (c.output.items.len != 0) {
                    try c.flush();
                    return;
                }
                switch (c.mode) {
                    .response => try c.finish(),
                    .stream => {
                        if (c.stream_done) {
                            try c.finish();
                            return;
                        }
                        var writer: types.StreamWriter = .{ .buffer = &c.file_buffer };
                        const stream = c.response.stream.?;
                        stream.next(stream.state, &writer) catch |err| {
                            c.observation.error_name = @errorName(err);
                            c.releaseRequest(.failed);
                            c.close();
                            return;
                        };
                        if (writer.len == 0 and !writer.finished) {
                            c.releaseRequest(.failed);
                            return error.EmptyStreamChunk;
                        }
                        if (writer.len != 0) try wire.appendChunk(c.allocator(), &c.output, c.file_buffer[0..writer.len]);
                        if (writer.finished) {
                            try wire.finishChunks(c.allocator(), &c.output);
                            c.stream_done = true;
                        }
                        try c.flush();
                    },
                    .file => {
                        if (c.headOnly() or c.file_offset == c.file_size) {
                            c.closeHandle(&c.file);
                            try c.finish();
                            return;
                        }
                        const length: usize = @intCast(@min(c.file_buffer.len, c.file_size - c.file_offset));
                        _ = try c.server.loop.readAt(c.file.?, c.file_buffer[0..length], c.file_offset, c.options());
                        c.pending += 1;
                    },
                    .websocket => {
                        if (c.ws_closing and c.ws_deadline == 0) c.close() else try c.processWs();
                    },
                    .sse => {
                        try c.receive();
                        try c.pumpSse();
                    },
                    else => {},
                }
            }

            fn wsSend(ptr: *anyopaque, opcode: types.WsOpcode, data: []const u8) types.WsSendError!void {
                const c: *Connection = @ptrCast(@alignCast(ptr));
                if (c.closing or c.ws_closing) return error.Closed;
                if (data.len > c.server.config.ws_max_message_size) return error.MessageTooLarge;
                if (opcode == .text and !std.unicode.utf8ValidateSlice(data)) return error.InvalidUtf8;
                wire.appendFrame(c.allocator(), &c.output, opcode, data, c.server.config.ws_max_queue_size -| c.tx.items.len) catch |err| return switch (err) {
                    error.QueueFull => error.QueueFull,
                    else => error.OutOfMemory,
                };
            }

            fn wsClose(ptr: *anyopaque) void {
                const c: *Connection = @ptrCast(@alignCast(ptr));
                c.endWs(1000);
            }

            fn endWs(c: *Connection, code: u16) void {
                if (c.ws_closing or c.closing) return;
                var payload: [2]u8 = undefined;
                std.mem.writeInt(u16, &payload, code, .big);
                wire.appendFrame(c.allocator(), &c.output, .close, &payload, c.server.config.ws_max_queue_size -| c.tx.items.len) catch {
                    c.close();
                    return;
                };
                c.ws_closing = true;
                c.ws_deadline = c.server.loop.now() + 5_000_000_000;
            }

            fn processWs(c: *Connection) !void {
                if (c.consumed != 0) {
                    c.removeInput(c.consumed);
                    c.consumed = 0;
                }
                while (true) {
                    const frame = ws.parseWithLimit(c.input.items, c.server.config.ws_max_message_size) catch |err| {
                        c.endWs(if (err == error.MessageTooLarge) 1009 else 1002);
                        break;
                    } orelse break;
                    ws.unmask(frame);
                    const handle: types.WsConn = .{ .ptr = c, .vtable = &.{ .send = wsSend, .close = wsClose } };
                    switch (frame.opcode) {
                        .close => {
                            ws.validateClose(frame.payload) catch |err| {
                                c.endWs(if (err == error.InvalidUtf8) 1007 else 1002);
                                break;
                            };
                            const already_sent = c.ws_closing;
                            c.ws_closing = true;
                            c.ws_deadline = 0;
                            if (!already_sent) try wire.appendFrame(c.allocator(), &c.output, .close, frame.payload, c.server.config.ws_max_queue_size -| c.tx.items.len);
                            c.ws_handler.?(handle, .{ .opcode = .close, .data = frame.payload });
                            c.removeInput(frame.consumed);
                            break;
                        },
                        .ping, .pong => {
                            if (frame.opcode == .ping) try wire.appendFrame(c.allocator(), &c.output, .pong, frame.payload, c.server.config.ws_max_queue_size -| c.tx.items.len);
                            c.ws_handler.?(handle, .{ .opcode = frame.opcode, .data = frame.payload });
                        },
                        .text, .binary, .continuation => {
                            if (c.ws_closing) {
                                c.removeInput(frame.consumed);
                                continue;
                            }
                            if ((frame.opcode == .continuation) != (c.fragment_opcode != null)) {
                                c.endWs(1002);
                                break;
                            }
                            const opcode = c.fragment_opcode orelse frame.opcode;
                            if (opcode == .text and (!c.utf8.feed(frame.payload) or (frame.final and c.utf8.remaining != 0))) {
                                c.endWs(1007);
                                break;
                            }
                            if (frame.payload.len > c.server.config.ws_max_message_size -| c.fragments.items.len) {
                                c.endWs(1009);
                                break;
                            }
                            if (c.fragment_opcode != null or !frame.final) {
                                try c.fragments.appendSlice(c.allocator(), frame.payload);
                                c.fragment_opcode = opcode;
                                if (frame.final) {
                                    c.ws_handler.?(handle, .{ .opcode = opcode, .data = c.fragments.items });
                                    c.fragments.clearRetainingCapacity();
                                    c.fragment_opcode = null;
                                }
                            } else c.ws_handler.?(handle, .{ .opcode = opcode, .data = frame.payload });
                            if (frame.final) c.utf8 = .{};
                        },
                        else => unreachable,
                    }
                    c.removeInput(frame.consumed);
                }
                try c.flush();
                if (c.ws_deadline != 0 and c.server.loop.now() >= c.ws_deadline) c.close();
                if (!c.closing and !c.receiving) try c.receive();
                if (c.ws_closing and c.ws_deadline == 0 and !c.sending) c.close();
            }

            fn sseSend(ptr: *anyopaque, event: []const u8, data: []const u8) void {
                const c: *Connection = @ptrCast(@alignCast(ptr));
                if (c.closing or c.sse_finished) return;
                var encoded: std.ArrayList(u8) = .empty;
                defer encoded.deinit(c.allocator());
                wire.appendSse(c.allocator(), &encoded, event, data) catch {
                    c.close();
                    return;
                };
                if (encoded.items.len > 64 * 1024 -| c.output.items.len) {
                    c.close();
                    return;
                }
                wire.appendChunk(c.allocator(), &c.output, encoded.items) catch c.close();
            }

            fn sseTick(ptr: *anyopaque, ms: u32) void {
                const c: *Connection = @ptrCast(@alignCast(ptr));
                c.sse_tick = ms;
            }

            fn sseClose(ptr: *anyopaque) void {
                const c: *Connection = @ptrCast(@alignCast(ptr));
                c.sse_finished = true;
            }

            fn pumpSse(c: *Connection) !void {
                if (c.sse_finished) {
                    if (c.stream_done) {
                        try c.finish();
                        return;
                    }
                    try wire.finishChunks(c.allocator(), &c.output);
                    c.stream_done = true;
                    try c.flush();
                    return;
                }
                c.sse_due = 0;
                const keep = c.response.sse_handler.?(.{ .ptr = c, .vtable = &.{ .send = sseSend, .set_tick = sseTick, .close = sseClose } });
                if (c.closing) return;
                if (!keep or c.sse_finished) {
                    c.sse_finished = true;
                    try wire.finishChunks(c.allocator(), &c.output);
                    c.stream_done = true;
                } else if (c.output.items.len == 0 and c.sse_tick != 0) c.sse_due = c.server.loop.now() + @as(u64, c.sse_tick) * 1_000_000;
                try c.flush();
            }

            fn startProxy(c: *Connection, options_: types.ProxyOptions) !void {
                c.mode = .proxy;
                c.keep_alive = false;
                c.proxy_deadline = if (options_.timeout_ms == 0) null else c.server.loop.now() + @as(u64, options_.timeout_ms) * 1_000_000;
                if (c.options().deadline) |deadline| c.proxy_deadline = if (c.proxy_deadline) |proxy_deadline| @min(deadline, proxy_deadline) else deadline;
                c.proxy_request = try proxy.buildRequest(c.arena.allocator(), c.request.?);
                c.upstream = c.server.loop.openTcp(options_.address.family) catch {
                    try c.fail(.bad_gateway);
                    return;
                };
                _ = c.server.loop.connect(c.upstream.?, options_.address, .{ .tag = @intFromPtr(c), .deadline = c.proxy_deadline }) catch {
                    c.closeHandle(&c.upstream);
                    try c.fail(.bad_gateway);
                    return;
                };
                c.pending += 1;
            }

            fn proxyReceive(c: *Connection) !void {
                _ = try c.server.loop.recv(c.upstream.?, &c.file_buffer, .{ .tag = @intFromPtr(c), .deadline = c.proxy_deadline });
                c.pending += 1;
            }

            fn completed(c: *Connection, result: t.Completion) !void {
                if (result.kind == .close) return;
                if (c.closing) {
                    if (result.opened) |h| {
                        c.file = h;
                        c.closeHandle(&c.file);
                    }
                    return;
                }
                const is_upstream = if (c.upstream) |h| h.index == result.handle.index and h.generation == result.handle.generation else false;
                if (is_upstream) {
                    if (result.status != .ok and result.status != .eof) {
                        c.closeHandle(&c.upstream);
                        try c.fail(if (result.status == .timed_out) .gateway_timeout else .bad_gateway);
                        return;
                    }
                    switch (result.kind) {
                        .connect => {
                            _ = try c.server.loop.sendAll(c.upstream.?, c.proxy_request, .{ .tag = @intFromPtr(c), .deadline = c.proxy_deadline });
                            c.pending += 1;
                        },
                        .send => try c.proxyReceive(),
                        .recv => {
                            const limit = c.entry.?.proxy.?.max_response_bytes;
                            if (result.bytes > limit -| c.proxy_input.items.len) {
                                c.closeHandle(&c.upstream);
                                try c.fail(.bad_gateway);
                                return;
                            }
                            try c.proxy_input.appendSlice(c.allocator(), c.file_buffer[0..result.bytes]);
                            const done = framing.complete(c.proxy_input.items, result.status == .eof or result.bytes == 0, c.request.?.method == .HEAD) catch {
                                c.closeHandle(&c.upstream);
                                try c.fail(.bad_gateway);
                                return;
                            };
                            if (done) {
                                c.closeHandle(&c.upstream);
                                const forwarded = proxy.forwardResponse(c.arena.allocator(), c.proxy_input.items) catch {
                                    try c.fail(.bad_gateway);
                                    return;
                                };
                                c.mode = .response;
                                c.observation.status = finalProxyStatus(c.proxy_input.items);
                                try c.output.appendSlice(c.allocator(), forwarded);
                                try c.flush();
                            } else try c.proxyReceive();
                        },
                        else => unreachable,
                    }
                    return;
                }
                if (result.status != .ok and !(result.kind == .read and result.status == .eof)) {
                    if (result.kind == .open and result.status != .timed_out and result.status != .canceled) {
                        try c.fail(.not_found);
                        return;
                    }
                    c.close();
                    return;
                }
                switch (result.kind) {
                    .recv => {
                        c.receiving = false;
                        if (result.bytes == 0) {
                            c.close();
                            return;
                        }
                        if (c.mode == .sse) {
                            c.close();
                            return;
                        }
                        if (c.mode == .reading) c.observation.start(c.server.loop.now() / 1_000_000);
                        try c.input.appendSlice(c.allocator(), c.scratch[0..result.bytes]);
                        if (c.mode == .websocket) try c.processWs() else try c.process();
                    },
                    .send => {
                        c.sending = false;
                        c.tx.clearRetainingCapacity();
                        try c.afterSend();
                    },
                    .open => {
                        c.file = result.opened orelse return error.MissingFile;
                        _ = try c.server.loop.stat(c.file.?, c.options());
                        c.pending += 1;
                    },
                    .stat => {
                        if (result.file_info.kind != .file) {
                            c.closeHandle(&c.file);
                            try c.fail(.not_found);
                            return;
                        }
                        c.file_size = result.file_info.size;
                        c.file_offset = 0;
                        try c.headers(c.response, c.file_size, false);
                        try c.flush();
                    },
                    .read => {
                        if (result.bytes == 0 or result.bytes > c.file_size - c.file_offset) {
                            c.close();
                            return;
                        }
                        c.file_offset += result.bytes;
                        try c.output.appendSlice(c.allocator(), c.file_buffer[0..result.bytes]);
                        try c.flush();
                    },
                    else => unreachable,
                }
            }
        };

        fn init(self: *Self, config: types.Config) !void {
            self.* = .{ .config = config, .loop = undefined, .budget = .{ .backing = config.gpa, .limit = config.max_memory_bytes }, .router = undefined, .admission = .{ .max_inflight = config.max_inflight_requests, .max_per_second = config.max_requests_per_second } };
            self.router = try routing.Router.init(self.budget.allocator(), config.routes);
            errdefer self.router.deinit();
            try self.loop.init(io.mem.PageAllocator.allocator(), .{ .operations = @intCast(config.max_connections * 4 + 16), .resources = @intCast(config.max_connections * 3 + 1), .events = 128 });
            errdefer self.loop.deinit() catch {};
            self.listener = try self.loop.listen(config.address, 256);
        }

        fn accept(self: *Self) !void {
            if (self.draining or self.accepting or self.connections.items.len >= self.config.max_connections or self.loop.now() < self.retry_accept) return;
            _ = try self.loop.accept(self.listener.?, .{});
            self.accepting = true;
            self.listener_pending += 1;
        }

        fn beginDrain(self: *Self, immediate: bool) void {
            if (!self.draining) {
                self.draining = true;
                self.drain_until = self.loop.now() + @as(u64, self.config.shutdown_timeout_ms) * 1_000_000;
                if (self.config.control) |control| control.state.store(.draining, .release);
                if (self.listener) |h| {
                    self.loop.close(h, .cancel, 0) catch |err| if (err != error.NativeFailure) @panic("invalid listener");
                    self.listener = null;
                    self.listener_pending += 1;
                }
            }
            for (self.connections.items) |c| if (immediate or c.request == null) c.close();
        }

        fn run(self: *Self) !void {
            if (self.config.ready) |callback| callback(try self.loop.localAddress(self.listener.?));
            try self.accept();
            var failure: ?anyerror = null;
            while (!self.draining or self.connections.items.len != 0 or self.listener_pending != 0) {
                if (self.config.control) |control| switch (control.command.load(.acquire)) {
                    .none => {},
                    .shutdown => self.beginDrain(false),
                    .close => self.beginDrain(true),
                };
                if (self.draining and self.loop.now() >= self.drain_until) self.beginDrain(true);
                for (self.connections.items) |c| {
                    if (!c.closing and c.mode == .sse and c.sse_due != 0 and self.loop.now() >= c.sse_due) c.pumpSse() catch c.close();
                    if (!c.closing and c.mode == .websocket and c.ws_deadline != 0 and self.loop.now() >= c.ws_deadline) c.close();
                }
                var results: [128]t.Completion = undefined;
                const count = self.loop.poll(&results, .{ .until = self.loop.now() + 20_000_000 }) catch |err| {
                    failure = err;
                    self.beginDrain(true);
                    continue;
                };
                for (results[0..count]) |result| {
                    if (result.tag == 0) {
                        self.listener_pending -= 1;
                        if (result.kind == .accept) {
                            self.accepting = false;
                            if (result.accepted) |h| {
                                const c = self.budget.allocator().create(Connection) catch {
                                    self.loop.close(h, .cancel, 0) catch |err| if (err != error.NativeFailure) return err;
                                    self.listener_pending += 1;
                                    continue;
                                };
                                c.* = .{ .server = self, .handle = h, .arena = std.heap.ArenaAllocator.init(self.budget.allocator()) };
                                self.connections.append(self.budget.allocator(), c) catch {
                                    self.budget.allocator().destroy(c);
                                    self.loop.close(h, .cancel, 0) catch |err| if (err != error.NativeFailure) return err;
                                    self.listener_pending += 1;
                                    continue;
                                };
                                metrics.connectionOpened();
                                self.loop.noDelay(h, true) catch {};
                                if (self.draining) c.close() else c.receive() catch c.close();
                            } else if (!self.draining) self.retry_accept = self.loop.now() + @as(u64, self.config.accept_backoff_ms) * 1_000_000;
                        }
                    } else {
                        const c: *Connection = @ptrFromInt(result.tag);
                        c.pending -= 1;
                        c.completed(result) catch |err| {
                            c.observation.error_name = @errorName(err);
                            c.close();
                        };
                    }
                }
                self.reap();
                self.accept() catch |err| {
                    failure = err;
                    self.beginDrain(true);
                };
            }
            if (self.config.control) |control| control.state.store(.stopped, .release);
            if (failure) |err| return err;
        }

        fn reap(self: *Self) void {
            var i: usize = 0;
            while (i < self.connections.items.len) {
                const c = self.connections.items[i];
                if (!c.closing or c.pending != 0) {
                    i += 1;
                    continue;
                }
                c.releaseRequest(.cancelled);
                c.finishObservation(false);
                c.arena.deinit();
                c.input.deinit(c.allocator());
                c.output.deinit(c.allocator());
                c.tx.deinit(c.allocator());
                c.fragments.deinit(c.allocator());
                c.proxy_input.deinit(c.allocator());
                metrics.connectionClosed();
                _ = self.connections.swapRemove(i);
                self.budget.allocator().destroy(c);
            }
        }

        fn deinit(self: *Self) void {
            // Exceptional exits use the same retirement rule as graceful and forced shutdown.
            self.beginDrain(true);
            while (self.connections.items.len != 0 or self.listener_pending != 0) {
                var results: [128]t.Completion = undefined;
                const count = self.loop.poll(&results, .forever) catch continue;
                for (results[0..count]) |result| {
                    if (result.tag == 0) {
                        self.listener_pending -= 1;
                        if (result.accepted) |h| {
                            self.loop.close(h, .cancel, 0) catch |err| if (err != error.NativeFailure) @panic("invalid accepted handle");
                            self.listener_pending += 1;
                        }
                    } else {
                        const c: *Connection = @ptrFromInt(result.tag);
                        c.pending -= 1;
                        c.completed(result) catch c.close();
                    }
                }
                self.reap();
            }
            self.loop.deinit() catch @panic("unretired I/O resources");
            self.connections.deinit(self.budget.allocator());
            self.router.deinit();
            std.debug.assert(self.budget.used == 0);
            if (self.config.control) |control| control.state.store(.stopped, .release);
        }
    };
}

fn finalProxyStatus(bytes: []const u8) u16 {
    // Framing has already validated every informational head and the final response.
    var offset: usize = 0;
    while (true) {
        const status = std.fmt.parseInt(u16, bytes[offset + 9 ..][0..3], 10) catch unreachable;
        if (status >= 200) return status;
        offset = (std.mem.indexOfPos(u8, bytes, offset, "\r\n\r\n") orelse unreachable) + 4;
    }
}

test "proxy observation skips informational status heads" {
    try std.testing.expectEqual(@as(u16, 201), finalProxyStatus("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 201 Created\r\ncontent-length: 0\r\n\r\n"));
}
