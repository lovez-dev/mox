//! Native file control operations for Darwin and FreeBSD.

const posix_abi = @import("../../os/abi/posix.zig");
const builtin = @import("builtin");
const c = @import("../common.zig");

const darwin = builtin.os.tag == .macos;
const Stat = posix_abi.Stat;
pub const fstat = posix_abi.fstat;
pub const @"fstat$INODE64" = posix_abi.@"fstat$INODE64";
pub const openFile = @import("../../os/bsd/file.zig").openFile;

pub fn work(request: *c.Request, scratch: []u8) c.Event {
    var event: c.Event = .{ .id = request.id };
    if (request.kind == .open) {
        event.accepted_native = openFile(request.path, request.file_options, scratch) catch |err| {
            return .{ .id = request.id, .status = .failed, .library_error = err, .native_error = if (err == error.NativeFailure) errno() else 0 };
        };
        return event;
    }
    const descriptor: i32 = @intCast(request.native);
    if (request.kind == .close) {
        const result = posix_abi.close(descriptor);
        return .{ .id = request.id, .closed_handle = request.handle, .native_error = if (result < 0) errno() else 0, .status = if (result == 0) .ok else .failed };
    }
    var metadata: Stat = undefined;
    const result = while (true) {
        const value: isize = switch (request.kind) {
            .read => posix_abi.pread(descriptor, request.read_buffer.ptr, request.read_buffer.len, @intCast(request.offset)),
            .write => posix_abi.pwrite(descriptor, request.write_buffer.ptr, request.write_buffer.len, @intCast(request.offset)),
            .sync => posix_abi.fsync(descriptor),
            .stat => if (darwin and builtin.cpu.arch == .x86_64) @"fstat$INODE64"(descriptor, &metadata) else fstat(descriptor, &metadata),
            else => return .{ .id = request.id, .status = .failed, .library_error = error.BackendUnavailable },
        };
        if (value >= 0 or errno() != 4) break value;
    };
    if (result < 0) return .{ .id = request.id, .status = .failed, .native_error = errno() };
    if (request.kind == .stat) event.file_info = .{ .kind = switch (metadata.mode & 0xf000) {
        0x8000 => .file,
        0x4000 => .directory,
        else => .other,
    }, .size = @intCast(@max(metadata.size, 0)), .allocated_size = @as(u64, @intCast(@max(metadata.blocks, 0))) *| 512, .permissions = metadata.mode & 0xfff, .modified = .{ .seconds = @intCast(metadata.modified.sec), .nanoseconds = @intCast(metadata.modified.nsec) } } else {
        event.bytes = @intCast(result);
        if (request.kind == .read and result == 0) event.status = .eof;
    }
    return event;
}

fn errno() i32 {
    return posix_abi.__error().*;
}
