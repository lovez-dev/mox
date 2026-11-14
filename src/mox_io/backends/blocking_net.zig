//! 将平台同步 socket 原语接入 Io；无运行时状态或平台选择。
const std = @import("std");
const types = @import("../types.zig");
const contract = @import("../io.zig");
pub fn adapt(comptime System: type) contract.BlockingNet {
    return .{
        .connectBlocking = struct {
            fn call(userdata: ?*anyopaque, socket: types.Handle, address: std.Io.net.IpAddress) anyerror!void {
                _ = userdata;
                return System.connectSocket(socket, address);
            }
        }.call,
        .acceptBlocking = struct {
            fn call(userdata: ?*anyopaque, socket: types.Handle) anyerror!types.Accepted {
                _ = userdata;
                const accepted = try System.acceptSocket(socket);
                return .{ .socket = accepted.socket, .address = accepted.address };
            }
        }.call,
        .localAddress = struct {
            fn call(userdata: ?*anyopaque, socket: types.Handle) anyerror!std.Io.net.IpAddress {
                _ = userdata;
                return System.localAddress(socket);
            }
        }.call,
        .sendBlocking = struct {
            fn call(userdata: ?*anyopaque, socket: types.Handle, bytes: []const u8) anyerror!usize {
                _ = userdata;
                return System.sendBlocking(socket, bytes);
            }
        }.call,
        .recvBlocking = struct {
            fn call(userdata: ?*anyopaque, socket: types.Handle, buf: []u8) anyerror!usize {
                _ = userdata;
                return System.recvBlocking(socket, buf);
            }
        }.call,
    };
}
