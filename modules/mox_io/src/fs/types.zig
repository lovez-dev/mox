//! Portable file options and metadata values.

pub const Kind = enum { file, directory, other };

pub const DirectoryEntry = struct { name: []const u8, kind: Kind };

pub const Access = enum { read, write, read_write };

pub const Creation = enum { open_existing, open_or_create, create_new, truncate_existing, create_always };

pub const OpenOptions = struct {
    access: Access = .read,
    creation: Creation = .open_existing,

    /// POSIX creation mode before applying the process umask.
    permissions: u16 = 0o600,

    pub fn legacy(create: bool, writable: bool) OpenOptions {
        return .{ .access = if (writable) .read_write else .read, .creation = if (create) .create_always else .open_existing };
    }
};

/// Unix seconds and a subsecond part; this avoids nanosecond epoch overflow.
pub const Timestamp = struct { seconds: i64 = 0, nanoseconds: u32 = 0 };

pub const Info = struct {
    kind: Kind = .other,
    size: u64 = 0,
    allocated_size: u64 = 0,
    modified: Timestamp = .{},

    /// Windows has no equivalent POSIX mode.
    permissions: ?u16 = null,
};
