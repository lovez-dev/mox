//! Native joinable threads with caller-owned, address-stable descriptors.

const posix_abi = @import("../os/abi/posix.zig");
const win_abi = @import("../os/abi/windows.zig");
const builtin = @import("builtin");
const Error = @import("../error.zig").Error;

const Thread = @This();

native: usize = 0,
callback: *const fn (*anyopaque) void = undefined,
context: *anyopaque = undefined,

pub const CreateThread = win_abi.CreateThread;
pub const WaitForSingleObject = win_abi.WaitForSingleObject;
pub const CloseHandle = win_abi.CloseHandle;

pub const pthread_create = posix_abi.pthread_create;
pub const pthread_join = posix_abi.pthread_join;
pub const pthread_attr_init = posix_abi.pthread_attr_init;
pub const pthread_attr_setstacksize = posix_abi.pthread_attr_setstacksize;
pub const pthread_attr_destroy = posix_abi.pthread_attr_destroy;

pub const SwitchToThread = win_abi.SwitchToThread;
pub const sched_yield = posix_abi.sched_yield;

/// Yield to another runnable thread when applying explicit backpressure.
pub fn yield() void {
    if (builtin.os.tag == .windows) {
        _ = SwitchToThread();
    } else {
        _ = sched_yield();
    }
}

/// The descriptor must remain stable until join() returns.
pub fn start(self: *Thread, callback: *const fn (*anyopaque) void, context: *anyopaque) Error!void {
    self.* = .{ .callback = callback, .context = context };
    if (builtin.os.tag == .windows) {
        // STACK_SIZE_PARAM_IS_A_RESERVATION keeps the 1 MiB reservation lazily committed.
        self.native = @intFromPtr(CreateThread(null, 1024 * 1024, windowsEntry, self, 0x10000, null) orelse return error.NativeFailure);
    } else {
        // Opaque storage is sized/aligned for pthread_attr_t on the supported targets.
        var attributes: [64]u8 align(8) = undefined;
        if (pthread_attr_init(&attributes) != 0) return error.NativeFailure;
        defer _ = pthread_attr_destroy(&attributes);
        if (pthread_attr_setstacksize(&attributes, 1024 * 1024) != 0) return error.NativeFailure;
        if (pthread_create(&self.native, &attributes, posixEntry, self) != 0) return error.NativeFailure;
    }
}

/// Join once after a successful start, from a different thread; releases the native handle.
pub fn join(self: *Thread) void {
    if (builtin.os.tag == .windows) {
        if (WaitForSingleObject(@ptrFromInt(self.native), 0xffffffff) != 0) @panic("thread join failed");
        _ = CloseHandle(@ptrFromInt(self.native));
    } else if (pthread_join(self.native, null) != 0) @panic("thread join failed");
    self.native = 0;
}

fn windowsEntry(context: ?*anyopaque) callconv(.winapi) u32 {
    const self: *Thread = @ptrCast(@alignCast(context.?));
    self.callback(self.context);
    return 0;
}

fn posixEntry(context: ?*anyopaque) callconv(.c) ?*anyopaque {
    const self: *Thread = @ptrCast(@alignCast(context.?));
    self.callback(self.context);
    return null;
}
