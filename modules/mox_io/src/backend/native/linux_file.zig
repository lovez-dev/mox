//! Explicit-offset Linux file I/O and statx metadata through raw syscalls.

const c = @import("../common.zig");
const s = @import("../../os/abi/linux.zig");

const Statx = s.Statx;
const file = @import("../../os/linux/file.zig");

pub fn closeNative(descriptor: usize, _: @import("../../types.zig").ResourceKind) c.CloseResult {
    // Linux consumes the descriptor even when final writeback reports an error.
    return .{ .native_error = s.errno(s.close(@intCast(descriptor))) };
}

pub fn work(request: *c.Request, scratch: []u8) c.Event {
    var event: c.Event = .{ .id = request.id };
    if (request.kind == .open) {
        const result = file.open(request.path, request.file_options, scratch) catch |err| {
            return .{ .id = request.id, .status = .failed, .library_error = err };
        };
        if (s.errno(result) != 0) return .{ .id = request.id, .status = .failed, .native_error = s.errno(result) };
        event.accepted_native = @intCast(result);
        return event;
    }
    const descriptor: i32 = @intCast(request.native);
    if (request.kind == .close) {
        const code = s.errno(s.close(descriptor));
        // Linux consumes the fd even if final writeback reports an error.
        return .{ .id = request.id, .closed_handle = request.handle, .native_error = code, .status = if (code == 0) .ok else .failed };
    }
    var metadata: Statx = undefined;
    const empty: [1:0]u8 = .{0};

    const result = while (true) {
        const value = switch (request.kind) {
            .read => s.pread(descriptor, request.read_buffer, request.offset),
            .write => s.pwrite(descriptor, request.write_buffer, request.offset),
            .sync => s.fsync(descriptor),
            .stat => s.statx(descriptor, &empty, s.at_empty_path, s.statx_basic_stats, &metadata),
            else => return .{ .id = request.id, .status = .failed, .library_error = error.BackendUnavailable },
        };
        if (s.errno(value) != 4) break value;
    };
    event.native_error = s.errno(result);
    if (event.native_error != 0) {
        event.status = .failed;
        return event;
    }
    if (request.kind == .stat) {
        event.file_info = .{ .kind = switch (metadata.mode & 0xf000) {
            0x8000 => .file,
            0x4000 => .directory,
            else => .other,
        }, .size = metadata.size, .allocated_size = metadata.blocks *| 512, .modified = .{ .seconds = metadata.modified.seconds, .nanoseconds = metadata.modified.nanoseconds }, .permissions = metadata.mode & 0xfff };
    } else {
        event.bytes = @intCast(result);
        if (request.kind == .read and result == 0) event.status = .eof;
    }
    return event;
}
