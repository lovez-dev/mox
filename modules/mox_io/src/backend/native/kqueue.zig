//! Kqueue readiness polling and user-event wake handling for Darwin and FreeBSD.

const builtin = @import("builtin");
const t = @import("../../types.zig");
const c = @import("../common.zig");
const net = @import("bsd_net.zig");
const ReadyEvent = @import("../readiness.zig").ReadyEvent;
const abi = @import("../../os/abi/posix.zig");

const Timespec = abi.Timespec;
const Arena = @import("../../mem/arena.zig");
const Layout = @import("../../mem/layout.zig").Layout;
const Error = @import("../../error.zig").Error;

const Native = @This();
const darwin = builtin.os.tag == .macos;
const user_filter: i16 = if (darwin) -10 else -11;
pub const Event = abi.Kevent;
pub const kqueue = abi.kqueue;
pub const kevent = abi.kevent;
queue: i32,
raw: []Event,
last_error: i32 = 0,

pub const socket = net.createSocket;
pub const localAddress = net.localAddress;
pub const attempt = net.attempt;
pub const fileWork = @import("bsd_file.zig").work;

pub fn openFile(path: []const u8, create: bool, writable: bool, scratch: []u8) Error!usize {
    return @import("../../os/bsd/file.zig").openFile(path, t.FileOpenOptions.legacy(create, writable), scratch);
}
pub const noDelay = net.noDelay;

pub fn layout(sizer: *Layout, options: t.Options) Error!void {
    try sizer.add(Event, options.events);
}

pub fn init(self: *Native, arena: *Arena, options: t.Options) Error!void {
    const queue = kqueue();
    if (queue < 0) return error.BackendUnavailable;
    errdefer _ = net.close(queue);
    // Keep the control descriptor out of child processes.
    if (net.fcntl(queue, 2, @as(c_int, 1)) < 0) return error.NativeFailure;
    self.* = .{ .queue = queue, .raw = try arena.allocate(Event, options.events) };
    try self.change(.{ .ident = 1, .filter = user_filter, .flags = 1 | 0x20 });
}

pub fn deinit(self: *Native) void {
    _ = net.close(self.queue);
}

fn change(self: *Native, event: Event) Error!void {
    // EV_RECEIPT reports registration failure without consuming queued I/O readiness.
    var input = event;
    var receipt: Event = .{};
    input.flags |= 0x40;
    const count = while (true) {
        const result = kevent(self.queue, @ptrCast(&input), 1, @ptrCast(&receipt), 1, null);
        if (result >= 0 or net.errno() != 4) break result;
    };
    self.last_error = if (count < 0) net.errno() else if (receipt.flags & 0x4000 != 0) @intCast(receipt.data) else 0;
    if (self.last_error != 0) return error.NativeFailure;
}

pub fn add(self: *Native, descriptor: usize, cookie: usize) Error!void {
    try net.configure(@intCast(descriptor));
    try self.change(.{ .ident = descriptor, .filter = -1, .flags = 1 | 0x20, .cookie = cookie });
}

pub fn remove(self: *Native, descriptor: usize, watched_write: bool) Error!void {
    self.change(.{ .ident = descriptor, .filter = -1, .flags = 2 }) catch |err| {
        if (self.last_error != 2 and self.last_error != 9) return err;
    };
    if (watched_write) self.change(.{ .ident = descriptor, .filter = -2, .flags = 2 }) catch |err| {
        if (self.last_error != 2 and self.last_error != 9) return err;
    };
}

pub fn setWrite(self: *Native, descriptor: usize, cookie: usize, needed: bool) Error!void {
    self.change(.{ .ident = descriptor, .filter = -2, .flags = if (needed) 1 | 0x20 else 2, .cookie = cookie }) catch |err| {
        if (needed or self.last_error != 2) return err;
    };
}

pub fn poll(self: *Native, duration: ?u64) Error![]const Event {
    var timeout: Timespec = .{ .sec = 0, .nsec = 0 };
    if (duration) |ns| timeout = .{ .sec = @intCast(@min(ns / 1_000_000_000, 0x7fffffff)), .nsec = @intCast(ns % 1_000_000_000) };

    const count = kevent(self.queue, null, 0, self.raw.ptr, @intCast(self.raw.len), if (duration != null) &timeout else null);
    if (count < 0) {
        self.last_error = net.errno();
        if (self.last_error == 4) return self.raw[0..0];
        return error.NativeFailure;
    }
    return self.raw[0..@intCast(count)];
}

pub fn decode(event: Event) ReadyEvent {
    return .{ .cookie = event.cookie, .read = event.filter == -1, .write = event.filter == -2 };
}

pub fn wake(self: *Native) void {
    // EVFILT_USER coalesces concurrent triggers without a helper descriptor.
    const event: Event = .{ .ident = 1, .filter = user_filter, .fflags = 0x1000000 };
    while (kevent(self.queue, @ptrCast(&event), 1, null, 0, null) < 0) {
        if (net.errno() != 4) @panic("kqueue wake failed");
    }
}

pub fn drainWake(_: *Native) void {}

pub fn closeNative(descriptor: usize, _: t.ResourceKind) c.CloseResult {
    const result = net.close(@intCast(descriptor));
    return .{ .native_error = if (result < 0) net.errno() else 0 };
}
