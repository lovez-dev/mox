//! A typed TCP endpoint supporting concurrent receive and send directions.

const t = @import("../types.zig");
const Error = @import("../error.zig").Error;

pub fn Tcp(comptime LoopType: type) type {
    return struct {
        const Self = @This();

        loop: *LoopType,
        handle: t.Handle,

        pub fn connect(self: Self, address: t.Address, options: t.SubmitOptions) Error!t.OpId {
            return self.loop.connect(self.handle, address, options);
        }

        pub fn recv(self: Self, bytes: []u8, options: t.SubmitOptions) Error!t.OpId {
            return self.loop.recv(self.handle, bytes, options);
        }

        pub fn recvExact(self: Self, bytes: []u8, options: t.SubmitOptions) Error!t.OpId {
            return self.loop.recvExact(self.handle, bytes, options);
        }

        pub fn send(self: Self, bytes: []const u8, options: t.SubmitOptions) Error!t.OpId {
            return self.loop.send(self.handle, bytes, options);
        }

        pub fn sendAll(self: Self, bytes: []const u8, options: t.SubmitOptions) Error!t.OpId {
            return self.loop.sendAll(self.handle, bytes, options);
        }

        pub fn noDelay(self: Self, enabled: bool) Error!void {
            return self.loop.noDelay(self.handle, enabled);
        }

        pub fn shutdown(self: Self, how: @import("options.zig").Shutdown) Error!void {
            return self.loop.shutdownSocket(self.handle, how);
        }

        pub fn setOption(self: Self, option: @import("options.zig").Option, value: i32) Error!void {
            return self.loop.socketOption(self.handle, option, value);
        }

        pub fn getOption(self: Self, option: @import("options.zig").Option) Error!i32 {
            return self.loop.getSocketOption(self.handle, option);
        }

        pub fn close(self: Self, mode: t.CloseMode, tag: usize) Error!void {
            return self.loop.close(self.handle, mode, tag);
        }

        pub fn stream(self: Self) @import("../io/stream.zig").Stream(LoopType) {
            return .tcp(self.loop, self.handle);
        }
    };
}
