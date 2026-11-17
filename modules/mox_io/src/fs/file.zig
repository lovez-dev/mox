//! A typed file handle; payload buffers remain owned by the caller.

const t = @import("../types.zig");
const Error = @import("../error.zig").Error;

pub fn File(comptime LoopType: type) type {
    return struct {
        const Self = @This();

        loop: *LoopType,
        handle: t.Handle,

        pub fn readAt(self: Self, bytes: []u8, offset: u64, options: t.SubmitOptions) Error!t.OpId {
            return self.loop.readAt(self.handle, bytes, offset, options);
        }

        pub fn readExactAt(self: Self, bytes: []u8, offset: u64, options: t.SubmitOptions) Error!t.OpId {
            return self.loop.readExactAt(self.handle, bytes, offset, options);
        }

        pub fn writeAt(self: Self, bytes: []const u8, offset: u64, options: t.SubmitOptions) Error!t.OpId {
            return self.loop.writeAt(self.handle, bytes, offset, options);
        }

        pub fn writeAllAt(self: Self, bytes: []const u8, offset: u64, options: t.SubmitOptions) Error!t.OpId {
            return self.loop.writeAllAt(self.handle, bytes, offset, options);
        }

        pub fn sync(self: Self, options: t.SubmitOptions) Error!t.OpId {
            return self.loop.sync(self.handle, options);
        }

        pub fn stat(self: Self, options: t.SubmitOptions) Error!t.OpId {
            return self.loop.stat(self.handle, options);
        }

        pub fn close(self: Self, mode: t.CloseMode, tag: usize) Error!void {
            return self.loop.close(self.handle, mode, tag);
        }

        pub fn stream(self: Self, offset: u64) @import("../io/stream.zig").Stream(LoopType) {
            return .file(self.loop, self.handle, offset);
        }
    };
}
