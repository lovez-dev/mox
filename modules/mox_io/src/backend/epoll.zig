//! epoll uses the shared readiness engine and native Linux syscalls.

pub const Driver = @import("readiness.zig").Driver(@import("native/epoll.zig"));
