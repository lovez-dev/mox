//! Documented Windows file APIs, including blocking control operations.

const win_abi = @import("../../os/abi/windows.zig");
const c = @import("../common.zig");

const w = win_abi;
const HandleInfo = win_abi.HandleInfo;
const StandardInfo = win_abi.StandardInfo;
pub const FlushFileBuffers = win_abi.FlushFileBuffers;
pub const GetFileInformationByHandle = win_abi.GetFileInformationByHandle;
pub const GetFileInformationByHandleEx = win_abi.GetFileInformationByHandleEx;
pub const openFile = @import("../../os/windows/file.zig").openFile;

pub fn work(request: *c.Request, scratch: []u8) c.Event {
    var event: c.Event = .{ .id = request.id };
    switch (request.kind) {
        .close => {
            const success = w.CloseHandle(@ptrFromInt(request.native)) != 0;
            const code: i32 = if (success) 0 else @bitCast(w.GetLastError());
            return .{ .id = request.id, .closed_handle = request.handle, .close_released = success or code == 6, .native_error = code, .status = if (success) .ok else .failed };
        },
        .open => {
            event.accepted_native = openFile(request.path, request.file_options, scratch) catch |err| {
                return .{ .id = request.id, .status = .failed, .library_error = err, .native_error = if (err == error.NativeFailure) @bitCast(w.GetLastError()) else 0 };
            };
        },
        .sync => if (FlushFileBuffers(@ptrFromInt(request.native)) == 0) {
            event.status = .failed;
            event.native_error = @bitCast(w.GetLastError());
        },
        .stat => {
            var standard: StandardInfo = undefined;
            var info: HandleInfo = undefined;
            const handle: w.Handle = @ptrFromInt(request.native);
            if (GetFileInformationByHandleEx(handle, 1, &standard, @sizeOf(StandardInfo)) == 0 or GetFileInformationByHandle(handle, &info) == 0) {
                event.status = .failed;
                event.native_error = @bitCast(w.GetLastError());
                return event;
            }
            const ticks = (@as(u64, info.modified.high) << 32) | info.modified.low;
            event.file_info = .{
                .kind = if (standard.directory != 0) .directory else .file,
                .size = @intCast(@max(standard.size, 0)),
                .allocated_size = @intCast(@max(standard.allocated, 0)),
                .modified = .{ .seconds = @as(i64, @intCast(ticks / 10_000_000)) - 11_644_473_600, .nanoseconds = @intCast((ticks % 10_000_000) * 100) },
            };
        },
        else => return .{ .id = request.id, .status = .failed, .library_error = error.BackendUnavailable },
    }
    return event;
}
