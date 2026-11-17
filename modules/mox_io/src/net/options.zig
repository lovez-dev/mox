//! Socket configuration shared by all native backends.

const posix_abi = @import("../os/abi/posix.zig");
const win_abi = @import("../os/abi/windows.zig");
const builtin = @import("builtin");
const t = @import("../types.zig");
const Error = @import("../error.zig").Error;

const windows = builtin.os.tag == .windows;
const linux = builtin.os.tag == .linux;
const Win = win_abi;
const Posix = posix_abi;

pub const Option = enum { keep_alive, reuse_address, reuse_port, send_buffer, receive_buffer };

pub const Shutdown = enum { read, write, both };

fn number(option: Option) Error!i32 {
    return switch (option) {
        .keep_alive => if (linux) 9 else 8,
        .reuse_address => if (linux) 2 else 4,
        .reuse_port => if (windows) error.BackendUnavailable else if (linux) @as(i32, 15) else 0x200,
        .send_buffer => if (linux) 7 else 0x1001,
        .receive_buffer => if (linux) 8 else 0x1002,
    };
}

pub fn set(native: usize, option: Option, value: i32) Error!void {
    switch (option) {
        .keep_alive, .reuse_address, .reuse_port => if (value != 0 and value != 1) return error.InvalidOptions,
        .send_buffer, .receive_buffer => if (value <= 0) return error.InvalidOptions,
    }

    const name = try number(option);
    const code = if (windows) Win.setsockopt(native, 0xffff, name, &value, 4) else Posix.setsockopt(@intCast(native), if (linux) 1 else 0xffff, name, &value, 4);
    if (code != 0) return error.NativeFailure;
}

pub fn get(native: usize, option: Option) Error!i32 {
    const name = try number(option);
    var value: i32 = 0;
    if (windows) {
        var size: i32 = 4;
        if (Win.getsockopt(native, 0xffff, name, &value, &size) != 0) return error.NativeFailure;
    } else {
        var size: u32 = 4;
        if (Posix.getsockopt(@intCast(native), if (linux) 1 else 0xffff, name, &value, &size) != 0) return error.NativeFailure;
    }
    return value;
}

pub fn shutdown(native: usize, how: Shutdown) Error!void {
    const direction: i32 = switch (how) {
        .read => 0,
        .write => 1,
        .both => 2,
    };

    const code = if (windows) Win.shutdown(native, direction) else Posix.shutdown(@intCast(native), direction);
    if (code != 0) return error.NativeFailure;
}

/// Bind an already configured TCP socket before converting it into a listener.
pub fn listen(native: usize, address: t.Address, backlog: u32) Error!void {
    var storage: [128]u8 align(8) = undefined;
    const length = @import("../os/socket_address.zig").encode(address, &storage);

    const bound = if (windows) Win.bind(native, &storage, @intCast(length)) else Posix.bind(@intCast(native), &storage, length);
    if (bound != 0) return error.NativeFailure;
    const queued = if (windows) Win.listen(native, @intCast(backlog)) else Posix.listen(@intCast(native), @intCast(backlog));
    if (queued != 0) return error.NativeFailure;
}
