//! Compile-time platform selection and low-level operating system helpers.

const builtin = @import("builtin");

/// Low-level native sockaddr conversion, selected at compile time.
pub const socket_address = @import("socket_address.zig");

pub const native = switch (builtin.os.tag) {
    .windows => @import("windows.zig"),
    .linux, .macos, .freebsd => @import("posix.zig"),
    else => @compileError("unsupported operating system"),
};

pub const pageSize = native.pageSize;
pub const mapPages = native.mapPages;
pub const unmapPages = native.unmapPages;
pub const writeStderr = native.writeStderr;
pub const writeStdout = native.writeStdout;
pub const exit = native.exit;
pub const now = native.now;
pub const threadId = native.threadId;
