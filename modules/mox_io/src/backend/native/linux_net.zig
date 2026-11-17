//! Linux socket operations and readiness attempts.

const s = @import("../../os/abi/linux.zig");
const t = @import("../../types.zig");
const c = @import("../common.zig");
const Error = @import("../../error.zig").Error;

pub const Attempt = struct { pending: bool = false, event: c.Event };

const address_abi = @import("../../os/socket_address.zig");

pub const encode = address_abi.encode;
pub const decode = address_abi.decode;

pub fn socket(kind: t.ResourceKind, family: t.Address.Family, address: ?t.Address, backlog: u32) Error!usize {
    return socketWithFlags(kind, family, address, backlog, true);
}

pub fn socketWithFlags(kind: t.ResourceKind, family: t.Address.Family, address: ?t.Address, backlog: u32, nonblocking: bool) Error!usize {
    const result = s.socket(if (family == .ipv4) address_abi.family4 else address_abi.family6, (if (kind == .udp) s.sock_dgram else s.sock_stream) | (if (nonblocking) s.sock_nonblock else 0) | s.sock_cloexec, if (kind == .udp) s.ipproto_udp else s.ipproto_tcp);
    if (s.errno(result) != 0) return error.NativeFailure;
    const native: usize = @intCast(result);
    errdefer _ = s.close(@intCast(native));
    if (address) |value| {
        var storage: [128]u8 align(8) = undefined;
        const length = encode(value, &storage);
        if (s.errno(s.bind(@intCast(native), &storage, length)) != 0) return error.NativeFailure;
    }
    if (kind == .listener and s.errno(s.listen(@intCast(native), backlog)) != 0) return error.NativeFailure;
    return native;
}

pub fn localAddress(native: usize) Error!t.Address {
    var storage: [128]u8 align(8) = undefined;
    var length: u32 = 128;
    if (s.errno(s.getsockname(@intCast(native), &storage, &length)) != 0) return error.NativeFailure;
    return decode(&storage);
}

pub fn noDelay(native: usize, enabled: bool) Error!void {
    const value: i32 = @intFromBool(enabled);
    if (s.errno(s.setsockopt(@intCast(native), s.ipproto_tcp, s.tcp_nodelay, &value, @sizeOf(i32))) != 0) return error.NativeFailure;
}

pub fn attempt(request: *c.Request, connect_started: bool) Attempt {
    while (true) {
        const value = attemptOnce(request, connect_started);
        if (value.event.native_error != 4) return value;
    }
}

fn attemptOnce(request: *c.Request, connect_started: bool) Attempt {
    var event: c.Event = .{ .id = request.id };

    const descriptor: i32 = @intCast(request.native);
    var storage: [128]u8 align(8) = undefined;
    var length: u32 = 128;
    var result: isize = 0;
    switch (request.kind) {
        .accept => {
            result = s.accept4(descriptor, &storage, &length, s.sock_nonblock | s.sock_cloexec);
            if (s.errno(result) == 0) {
                event.accepted_native = @intCast(result);
                event.peer = decode(&storage);
                return .{ .event = event };
            }
        },
        .connect => {
            if (!connect_started) {
                length = encode(request.address, &storage);
                result = s.connect(descriptor, &storage, length);
            } else {
                var native_error: i32 = 0;
                var size: u32 = 4;
                result = s.getsockopt(descriptor, s.sol_socket, s.so_error, &native_error, &size);
                if (s.errno(result) == 0 and native_error != 0) result = -@as(isize, native_error);
            }
        },
        .recv => result = s.recv_from(descriptor, request.read_buffer, 0, null, null),
        .send => result = s.send_to(descriptor, request.write_buffer, s.msg_nosignal, null, 0),
        .recv_from => result = s.recv_from(descriptor, request.read_buffer, s.msg_trunc, &storage, &length),
        .send_to => {
            length = encode(request.address, &storage);
            result = s.send_to(descriptor, request.write_buffer, s.msg_nosignal, &storage, length);
        },
        else => return .{ .event = .{ .id = request.id, .status = .failed, .native_error = 95 } },
    }
    const native_error = s.errno(result);
    if (native_error == 11 or native_error == 115 or native_error == 114) return .{ .event = event, .pending = true };
    if (native_error == 106 and request.kind == .connect) return .{ .event = event };
    if (native_error != 0) {
        event.status = .failed;
        event.native_error = native_error;
    } else {
        if (request.kind != .connect) event.bytes = @intCast(result);
        if ((request.kind == .recv) and result == 0) event.status = .eof;
        if (request.kind == .recv_from) {
            event.peer = decode(&storage);
            if (event.bytes > request.read_buffer.len) {
                event.bytes = request.read_buffer.len;
                event.truncated = true;
            }
        }
    }
    return .{ .event = event };
}
