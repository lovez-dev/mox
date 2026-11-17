//! Borrowed requests and native retirement results shared by drivers and workers.

const t = @import("values.zig");

/// Borrowed arguments and native identity remain stable until retirement.
pub const Request = struct {
    id: t.OpId,
    handle: t.Handle,
    native: usize,
    kind: t.Kind,
    options: t.SubmitOptions,

    read_buffer: []u8 = &.{},
    write_buffer: []const u8 = &.{},
    offset: u64 = 0,
    address: t.Address = .{},
    full: bool = false,

    path: []const u8 = &.{},
    file_options: t.FileOpenOptions = .{},
    work: ?t.Work = null,
};

/// Emitting an event guarantees that native code no longer touches the request.
pub const Event = struct {
    id: t.OpId,
    status: t.Status = .ok,
    bytes: usize = 0,
    native_error: i32 = 0,
    library_error: ?@import("../error.zig").Error = null,

    file_info: t.FileInfo = .{},
    truncated: bool = false,
    accepted_native: usize = t.invalid_native,
    peer: t.Address = .{},
    wake: bool = false,

    /// Close requests use resource reservations instead of ordinary operation slots.
    closed_handle: ?t.Handle = null,
    close_released: bool = true,
};

/// Run portable blocking work using the same retirement and wake protocol as files.
pub fn performWork(request: *Request) Event {
    const task = request.work.?;
    const count = task.run(task.context, request.native) catch |err|
        return .{ .id = request.id, .status = .failed, .library_error = err, .native_error = if (task.native_error) |code| code.* else 0 };
    return .{ .id = request.id, .bytes = count };
}
