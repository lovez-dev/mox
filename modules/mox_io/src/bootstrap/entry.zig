//! Optional process entry points for standalone programs using mox_io's runtime helpers.

const builtin = @import("builtin");
const os = @import("../os/root.zig");

/// POSIX uses the system C startup with our C entry. Windows uses our own entry.
pub fn Boot(comptime run: fn () u8) type {
    return struct {
        pub fn main(_: c_int, _: [*][*:0]u8) callconv(.c) c_int {
            return run();
        }

        pub fn WinMainCRTStartup() callconv(.winapi) noreturn {
            os.exit(run());
        }

        pub fn exportEntry() void {
            // Export only when the consumer explicitly selects this standalone runtime.
            @import("builtins.zig").install();
            if (builtin.os.tag == .windows) {
                @export(&WinMainCRTStartup, .{ .name = "mox_io_start" });
            } else {
                @export(&main, .{ .name = "main" });
            }
        }
    };
}
