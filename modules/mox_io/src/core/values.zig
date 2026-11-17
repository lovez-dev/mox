//! Portable I/O identities, operation values and completion records.

pub const Address = @import("../net/address.zig").Address;
pub const FileOpenOptions = @import("../fs/types.zig").OpenOptions;
pub const FileInfo = @import("../fs/types.zig").Info;

pub const none = ~@as(u32, 0);
pub const invalid_native = ~@as(usize, 0);

/// Generation checks reject references to recycled resource slots.
pub const Handle = struct { index: u32, generation: u64 };

/// Valid until the operation's terminal completion is consumed.
pub const OpId = struct { index: u32, generation: u64 };
pub const invalid_handle: Handle = .{ .index = none, .generation = 0 };

pub const ResourceKind = enum { listener, tcp, udp, file };

pub const Kind = enum { accept, connect, recv, send, recv_from, send_to, open, read, write, sync, stat, timer, close, work };

/// Borrowed context; a running callback retires before cancellation is delivered.
pub const Work = struct {
    context: ?*anyopaque,
    run: *const fn (?*anyopaque, usize) @import("../error.zig").Error!usize,
    native_error: ?*const i32 = null,
};

pub const Status = enum { ok, eof, canceled, timed_out, failed };

pub const Connection = enum { unconnected, connecting, connected, failed };

pub const SubmitOptions = struct {
    tag: usize = 0,
    /// Absolute monotonic nanoseconds. Null means no deadline.
    deadline: ?u64 = null,
};

pub const Wait = union(enum) { none, forever, until: u64 };

pub const CancelResult = enum { requested, already_completed };

pub const CloseMode = enum { cancel, drain };

/// The payload buffer can be reused when this result is delivered.
pub const Completion = struct {
    id: ?OpId,
    handle: Handle,
    kind: Kind,
    status: Status,
    tag: usize = 0,

    bytes: usize = 0,
    native_error: i32 = 0,
    library_error: ?@import("../error.zig").Error = null,
    truncated: bool = false,

    accepted: ?Handle = null,
    opened: ?Handle = null,
    file_info: FileInfo = .{},
    peer: Address = .{},
};
