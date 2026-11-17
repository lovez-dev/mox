//! Thread-safe shutdown commands and observable server state.

const std = @import("std");

/// One control per serve() invocation. Keep it alive until serve() returns.
/// Commands are thread-safe, nonblocking and sticky; construct a fresh control
/// to restart. A close request always takes precedence over shutdown.
pub const ServerControl = struct {
    pub const State = enum(u8) { idle, running, draining, stopped };
    pub const Command = enum(u8) { none, shutdown, close };
    command: std.atomic.Value(Command) = .init(.none),
    state: std.atomic.Value(State) = .init(.idle),

    pub fn shutdown(self: *ServerControl) void {
        _ = self.command.cmpxchgStrong(.none, .shutdown, .acq_rel, .acquire);
    }

    pub fn close(self: *ServerControl) void {
        self.command.store(.close, .release);
    }

    pub fn getState(self: *const ServerControl) State {
        return self.state.load(.acquire);
    }
};

test "close takes precedence over repeated shutdown requests" {
    var control: ServerControl = .{};
    control.shutdown();
    control.close();
    control.shutdown();
    try std.testing.expectEqual(ServerControl.Command.close, control.command.load(.acquire));
    try std.testing.expectEqual(ServerControl.State.idle, control.getState());
}
