//! A typed datagram socket; empty datagrams remain successful messages.

const t = @import("../types.zig");
const Error = @import("../error.zig").Error;

pub fn Udp(comptime LoopType: type) type {
    return struct {
        const Self = @This();

        loop: *LoopType,
        handle: t.Handle,

        pub fn recvFrom(self: Self, bytes: []u8, options: t.SubmitOptions) Error!t.OpId {
            return self.loop.recvFrom(self.handle, bytes, options);
        }

        pub fn sendTo(self: Self, bytes: []const u8, address: t.Address, options: t.SubmitOptions) Error!t.OpId {
            return self.loop.sendTo(self.handle, bytes, address, options);
        }

        pub fn localAddress(self: Self) Error!t.Address {
            return self.loop.localAddress(self.handle);
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
    };
}
