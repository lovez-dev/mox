//! Native BSD/Darwin socket ABI; sockaddr starts with length and family bytes.

const posix_abi = @import("../../os/abi/posix.zig");
const builtin = @import("builtin");
const t = @import("../../types.zig");
const c = @import("../common.zig");
const Error = @import("../../error.zig").Error;

const darwin = builtin.os.tag == .macos;
const family6 = @import("../../os/socket_address.zig").family6;

const no_signal: i32 = if (darwin) 0 else 0x20000;
pub const Iovec = posix_abi.Iovec;
pub const Message = posix_abi.Message;
pub const __error = posix_abi.__error;
pub const close = posix_abi.close;
pub const fcntl = posix_abi.fcntl;
pub const socket = posix_abi.socket;
pub const bind = posix_abi.bind;
pub const listen = posix_abi.listen;
pub const getsockname = posix_abi.getsockname;
pub const getsockopt = posix_abi.getsockopt;
pub const setsockopt = posix_abi.setsockopt;
pub const accept = posix_abi.accept;
pub const connect = posix_abi.connect;
pub const recv = posix_abi.recv;
pub const send = posix_abi.send;
pub const recvmsg = posix_abi.recvmsg;
pub const sendto = posix_abi.sendto;

pub fn errno() i32 {
    return __error().*;
}

pub fn configure(descriptor: i32) Error!void {
    const flags = fcntl(descriptor, 3);
    if (flags < 0 or fcntl(descriptor, 4, @as(c_int, flags | 4)) < 0 or fcntl(descriptor, 2, @as(c_int, 1)) < 0) return error.NativeFailure;
    if (darwin) {
        const enabled: c_int = 1;
        if (setsockopt(descriptor, 0xffff, 0x1022, &enabled, 4) != 0) return error.NativeFailure;
    }
}
pub const encode = @import("../../os/socket_address.zig").encode;
pub const decode = @import("../../os/socket_address.zig").decode;

pub fn createSocket(kind: t.ResourceKind, family: t.Address.Family, address: ?t.Address, backlog: u32) Error!usize {
    const descriptor = socket(if (family == .ipv4) 2 else family6, if (kind == .udp) 2 else 1, if (kind == .udp) 17 else 6);
    if (descriptor < 0) return error.NativeFailure;
    errdefer _ = close(descriptor);
    try configure(descriptor);
    if (address) |value| {
        var storage: [128]u8 align(8) = undefined;
        const length = encode(value, &storage);
        if (bind(descriptor, &storage, length) != 0) return error.NativeFailure;
    }
    if (kind == .listener and listen(descriptor, @intCast(@min(backlog, 0x7fffffff))) != 0) return error.NativeFailure;
    return @intCast(descriptor);
}

pub fn localAddress(descriptor: usize) Error!t.Address {
    var storage: [128]u8 align(8) = undefined;
    var length: u32 = 128;
    if (getsockname(@intCast(descriptor), &storage, &length) != 0) return error.NativeFailure;
    return decode(&storage);
}

pub fn noDelay(native: usize, enabled: bool) Error!void {
    const value: i32 = @intFromBool(enabled);
    if (setsockopt(@intCast(native), 6, 1, &value, 4) != 0) return error.NativeFailure;
}

pub fn attempt(request: *c.Request, connect_started: bool) struct { pending: bool = false, event: c.Event } {
    const descriptor: i32 = @intCast(request.native);
    var event: c.Event = .{ .id = request.id };
    var storage: [128]u8 align(8) = undefined;
    var length: u32 = 128;
    var vector: Iovec = .{ .base = request.read_buffer.ptr, .length = request.read_buffer.len };
    var message: Message = .{ .name = &storage, .name_length = 128, .vectors = &vector, .vector_count = 1 };
    // EINTR retries immediately: no readiness edge is guaranteed for an interruption.
    const result: isize = while (true) {
        const value: isize = switch (request.kind) {
            .accept => accept(descriptor, &storage, &length),
            .connect => if (!connect_started) connect(descriptor, &storage, encode(request.address, &storage)) else value: {
                var code: i32 = 0;
                var size: u32 = 4;
                if (getsockopt(descriptor, 0xffff, 0x1007, &code, &size) != 0) break :value -1;
                if (code != 0) {
                    __error().* = code;
                    break :value -1;
                }
                break :value 0;
            },
            .recv => recv(descriptor, request.read_buffer.ptr, request.read_buffer.len, 0),
            .send => send(descriptor, request.write_buffer.ptr, request.write_buffer.len, no_signal),
            .recv_from => recvmsg(descriptor, &message, 0),
            .send_to => sendto(descriptor, request.write_buffer.ptr, request.write_buffer.len, no_signal, &storage, encode(request.address, &storage)),
            else => {
                return .{ .event = .{ .id = request.id, .status = .failed, .native_error = 45 } };
            },
        };
        if (value >= 0 or errno() != 4) break value;
    };
    if (result < 0) {
        const code = errno();
        if (code == 56 and request.kind == .connect) return .{ .event = event };
        if (code == 35 or code == 36 or code == 37) return .{ .pending = true, .event = event };
        event.status = .failed;
        event.native_error = code;
    } else switch (request.kind) {
        .accept => {
            configure(@intCast(result)) catch {
                event.status = .failed;
                event.native_error = errno();
                _ = close(@intCast(result));
                return .{ .event = event };
            };
            event.accepted_native = @intCast(result);
            event.peer = decode(&storage);
        },
        .connect => {},
        .recv_from => {
            event.bytes = @intCast(result);
            event.peer = decode(&storage);
            event.truncated = message.flags & 0x10 != 0;
        },
        else => {
            event.bytes = @intCast(result);
            if (request.kind == .recv and result == 0) event.status = .eof;
        },
    }
    return .{ .event = event };
}
