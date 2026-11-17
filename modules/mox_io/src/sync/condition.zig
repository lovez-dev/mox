//! Native condition variable; the caller protects its predicate with a mutex.

const posix_abi = @import("../os/abi/posix.zig");
const win_abi = @import("../os/abi/windows.zig");
const builtin = @import("builtin");
const Error = @import("../error.zig").Error;
const Mutex = @import("mutex.zig");

const Condition = @This();

// Opaque storage covers CONDITION_VARIABLE and the supported pthread_cond_t ABIs.
storage: [64]u8 align(8) = @splat(0),

pub const InitializeConditionVariable = win_abi.InitializeConditionVariable;
pub const SleepConditionVariableSRW = win_abi.SleepConditionVariableSRW;
pub const WakeConditionVariable = win_abi.WakeConditionVariable;
pub const WakeAllConditionVariable = win_abi.WakeAllConditionVariable;
pub const pthread_cond_init = posix_abi.pthread_cond_init;
pub const pthread_cond_destroy = posix_abi.pthread_cond_destroy;
pub const pthread_cond_wait = posix_abi.pthread_cond_wait;
pub const pthread_cond_signal = posix_abi.pthread_cond_signal;
pub const pthread_cond_broadcast = posix_abi.pthread_cond_broadcast;

/// Keep this object stable until every waiter has returned.
pub fn init(self: *Condition) Error!void {
    self.storage = @splat(0);
    if (builtin.os.tag == .windows) InitializeConditionVariable(&self.storage) else if (pthread_cond_init(&self.storage, null) != 0) return error.NativeFailure;
}

pub fn deinit(self: *Condition) void {
    if (builtin.os.tag != .windows and pthread_cond_destroy(&self.storage) != 0) @panic("condition destroy failed");
}

/// Releases and reacquires the locked mutex; always recheck the predicate in a loop.
pub fn wait(self: *Condition, mutex: *Mutex) void {
    if (builtin.os.tag == .windows) {
        if (SleepConditionVariableSRW(&self.storage, &mutex.storage, 0xffffffff, 0) == 0) @panic("condition wait failed");
    } else if (pthread_cond_wait(&self.storage, &mutex.storage) != 0) @panic("condition wait failed");
}

pub fn signal(self: *Condition) void {
    if (builtin.os.tag == .windows) WakeConditionVariable(&self.storage) else if (pthread_cond_signal(&self.storage) != 0) @panic("condition signal failed");
}

pub fn broadcast(self: *Condition) void {
    if (builtin.os.tag == .windows) WakeAllConditionVariable(&self.storage) else if (pthread_cond_broadcast(&self.storage) != 0) @panic("condition broadcast failed");
}
