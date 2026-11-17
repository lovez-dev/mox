//! Epoll readiness polling and eventfd wake handling.

const eventfd = @import("../../os/linux/eventfd.zig");
const s = @import("../../os/abi/linux.zig");
const net = @import("linux_net.zig");
const c = @import("../common.zig");
const t = @import("../../types.zig");
const ReadyEvent = @import("../readiness.zig").ReadyEvent;
const Arena = @import("../../mem/arena.zig");
const Layout = @import("../../mem/layout.zig").Layout;
const Error = @import("../../error.zig").Error;

const Native = @This();

queue: i32,
wake_fd: i32,
raw: []s.EpollEvent,
last_error: i32 = 0,

pub const socket = net.socket;
pub const localAddress = net.localAddress;
pub const attempt = net.attempt;
pub const fileWork = @import("linux_file.zig").work;

pub fn layout(sizer: *Layout, options: t.Options) Error!void {
    try sizer.add(s.EpollEvent, options.events);
}

pub fn init(self: *Native, arena: *Arena, options: t.Options) Error!void {
    const queue = s.epollCreate();
    if (s.errno(queue) != 0) return error.BackendUnavailable;
    errdefer _ = s.close(@intCast(queue));
    const wake_fd = s.eventfd();
    if (s.errno(wake_fd) != 0) return error.NativeFailure;
    errdefer _ = s.close(@intCast(wake_fd));
    self.* = .{ .queue = @intCast(queue), .wake_fd = @intCast(wake_fd), .raw = try arena.allocate(s.EpollEvent, options.events) };

    const event: s.EpollEvent = .{ .events = 1 | 0x80000000, .data = 0 };
    try self.check(s.epollControl(self.queue, 1, self.wake_fd, &event));
}

pub fn deinit(self: *Native) void {
    _ = s.close(self.wake_fd);
    _ = s.close(self.queue);
}

fn check(self: *Native, result: isize) Error!void {
    self.last_error = s.errno(result);
    if (self.last_error != 0) return error.NativeFailure;
}

pub fn add(self: *Native, descriptor: usize, cookie: usize) Error!void {
    // Adopted sockets must satisfy the same nonblocking contract as library sockets.
    const fd: i32 = @intCast(descriptor);
    const status = s.fcntl(fd, 3, 0);
    const flags = s.fcntl(fd, 1, 0);
    try self.check(status);
    try self.check(flags);
    if (@as(usize, @intCast(status)) & 0x800 == 0) try self.check(s.fcntl(fd, 4, @as(usize, @intCast(status)) | 0x800));
    if (@as(usize, @intCast(flags)) & 1 == 0) try self.check(s.fcntl(fd, 2, @as(usize, @intCast(flags)) | 1));
    const event: s.EpollEvent = .{ .events = 1 | 0x2000 | 0x80000000, .data = cookie };
    try self.check(s.epollControl(self.queue, 1, @intCast(descriptor), &event));
}
pub const noDelay = net.noDelay;

pub fn remove(self: *Native, descriptor: usize, _: bool) Error!void {
    const result = s.epollControl(self.queue, 2, @intCast(descriptor), null);
    const code = s.errno(result);
    if (code != 2 and code != 9) try self.check(result);
}

pub fn setWrite(self: *Native, descriptor: usize, cookie: usize, needed: bool) Error!void {
    // EPOLLOUT is enabled only while a write or connect is pending.
    const event: s.EpollEvent = .{ .events = 1 | 0x2000 | 0x80000000 | @as(u32, if (needed) 4 else 0), .data = cookie };
    try self.check(s.epollControl(self.queue, 3, @intCast(descriptor), &event));
}

pub fn poll(self: *Native, duration: ?u64) Error![]const s.EpollEvent {
    const milliseconds: i32 = if (duration) |ns| @intCast(@min(ns / 1_000_000 + @intFromBool(ns % 1_000_000 != 0), 0x7fffffff)) else -1;
    const result = s.epollWait(self.queue, self.raw, milliseconds);
    if (s.errno(result) == 4) return self.raw[0..0];
    try self.check(result);
    return self.raw[0..@intCast(result)];
}

pub fn decode(event: s.EpollEvent) ReadyEvent {
    // Errors and hangups must retry both directions to produce terminal I/O results.
    return .{ .cookie = event.data, .read = event.events & (1 | 8 | 16 | 0x2000) != 0, .write = event.events & (4 | 8 | 16) != 0 };
}

pub fn wake(self: *Native) void {
    eventfd.signal(self.wake_fd);
}

pub fn drainWake(self: *Native) void {
    eventfd.drain(self.wake_fd);
}

pub const closeNative = @import("linux_file.zig").closeNative;

pub fn openFile(path: []const u8, create: bool, writable: bool, scratch: []u8) Error!usize {
    return @import("../../os/linux/file.zig").openFile(path, t.FileOpenOptions.legacy(create, writable), scratch);
}
