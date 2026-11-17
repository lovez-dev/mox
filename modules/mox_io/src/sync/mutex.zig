//! Exclusive, non-recursive native mutex; initialize and destroy at its final address.

const posix_abi = @import("../os/abi/posix.zig");
const win_abi = @import("../os/abi/windows.zig");
const builtin = @import("builtin");
const Error = @import("../error.zig").Error;

const Mutex = @This();

// Opaque storage covers the supported SRWLOCK/pthread_mutex_t ABIs.
storage: [64]u8 align(8) = @splat(0),

pub const InitializeSRWLock = win_abi.InitializeSRWLock;
pub const AcquireSRWLockExclusive = win_abi.AcquireSRWLockExclusive;
pub const ReleaseSRWLockExclusive = win_abi.ReleaseSRWLockExclusive;
pub const pthread_mutex_init = posix_abi.pthread_mutex_init;
pub const pthread_mutex_destroy = posix_abi.pthread_mutex_destroy;
pub const pthread_mutex_lock = posix_abi.pthread_mutex_lock;
pub const pthread_mutex_unlock = posix_abi.pthread_mutex_unlock;

/// Initialize at the final address. Native synchronization objects cannot move.
pub fn init(self: *Mutex) Error!void {
    self.storage = @splat(0);
    if (builtin.os.tag == .windows) InitializeSRWLock(&self.storage) else if (pthread_mutex_init(&self.storage, null) != 0) return error.NativeFailure;
}

/// All owners and waiters must have stopped using the mutex before destruction.
pub fn deinit(self: *Mutex) void {
    if (builtin.os.tag != .windows and pthread_mutex_destroy(&self.storage) != 0) @panic("mutex destroy failed");
}

pub fn lock(self: *Mutex) void {
    if (builtin.os.tag == .windows) AcquireSRWLockExclusive(&self.storage) else if (pthread_mutex_lock(&self.storage) != 0) @panic("mutex lock failed");
}

pub fn unlock(self: *Mutex) void {
    if (builtin.os.tag == .windows) ReleaseSRWLockExclusive(&self.storage) else if (pthread_mutex_unlock(&self.storage) != 0) @panic("mutex unlock failed");
}
