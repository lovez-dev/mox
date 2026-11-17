//! Allocation-free stream adapters over the completion API.

const t = @import("../types.zig");
const Error = @import("../error.zig").Error;

pub fn Stream(comptime LoopType: type) type {
    return struct {
        const Self = @This();

        loop: *LoopType,
        handle: t.Handle,
        mode: enum { tcp, file },
        cursor: u64 = 0,
        reading: ?t.OpId = null,
        writing: ?t.OpId = null,

        pub fn tcp(loop: *LoopType, handle: t.Handle) Self {
            return .{ .loop = loop, .handle = handle, .mode = .tcp };
        }

        pub fn file(loop: *LoopType, handle: t.Handle, offset: u64) Self {
            return .{ .loop = loop, .handle = handle, .mode = .file, .cursor = offset };
        }

        pub fn read(self: *Self, buffer: []u8, options: t.SubmitOptions) Error!t.OpId {
            return self.submitRead(buffer, options, false);
        }

        pub fn readExact(self: *Self, buffer: []u8, options: t.SubmitOptions) Error!t.OpId {
            return self.submitRead(buffer, options, true);
        }

        fn submitRead(self: *Self, buffer: []u8, options: t.SubmitOptions, full: bool) Error!t.OpId {
            if (self.reading != null or (self.mode == .file and self.writing != null)) return error.DirectionBusy;
            const id = if (self.mode == .tcp)
                (if (full) try self.loop.recvExact(self.handle, buffer, options) else try self.loop.recv(self.handle, buffer, options))
            else
                (if (full) try self.loop.readExactAt(self.handle, buffer, self.cursor, options) else try self.loop.readAt(self.handle, buffer, self.cursor, options));
            self.reading = id;
            return id;
        }

        pub fn write(self: *Self, bytes: []const u8, options: t.SubmitOptions) Error!t.OpId {
            return self.submitWrite(bytes, options, false);
        }

        pub fn writeAll(self: *Self, bytes: []const u8, options: t.SubmitOptions) Error!t.OpId {
            return self.submitWrite(bytes, options, true);
        }

        fn submitWrite(self: *Self, bytes: []const u8, options: t.SubmitOptions, full: bool) Error!t.OpId {
            if (self.writing != null or (self.mode == .file and self.reading != null)) return error.DirectionBusy;
            const id = if (self.mode == .tcp)
                (if (full) try self.loop.sendAll(self.handle, bytes, options) else try self.loop.send(self.handle, bytes, options))
            else
                (if (full) try self.loop.writeAllAt(self.handle, bytes, self.cursor, options) else try self.loop.writeAt(self.handle, bytes, self.cursor, options));
            self.writing = id;
            return id;
        }

        fn matches(expected: ?t.OpId, actual: t.OpId) bool {
            const id = expected orelse return false;
            return id.index == actual.index and id.generation == actual.generation;
        }

        /// Feed results from this stream's Loop before reusing its pending direction.
        pub fn complete(self: *Self, result: t.Completion) bool {
            if (result.handle.index != self.handle.index or result.handle.generation != self.handle.generation) return false;
            const id = result.id orelse return false;
            if (matches(self.reading, id)) self.reading = null else if (matches(self.writing, id)) self.writing = null else return false;
            // Partial progress advances file position even on EOF or cancellation.
            if (self.mode == .file) self.cursor += result.bytes;
            return true;
        }

        pub fn seek(self: *Self, offset: u64) Error!void {
            if (self.mode != .file) return error.InvalidResource;
            if (self.reading != null or self.writing != null) return error.DirectionBusy;
            if (offset > 0x7fffffffffffffff) return error.InvalidOptions;
            self.cursor = offset;
        }
    };
}
