//! Owner-local clock state avoids repeated Windows frequency queries.

const builtin = @import("builtin");
const os = @import("../os/root.zig");
const w = @import("../os/windows.zig");

const Clock = @This();

frequency: u64 = 0,
cached: u64 = 0,

pub fn init() Clock {
    var self: Clock = .{};
    if (builtin.os.tag == .windows) {
        var frequency: i64 = 0;
        if (w.QueryPerformanceFrequency(&frequency) == 0 or frequency <= 0) @panic("performance counter unavailable");
        self.frequency = @intCast(frequency);
    }
    _ = self.sample();
    return self;
}

/// Return fresh monotonic nanoseconds without modifying cached owner state.
pub fn now(self: *const Clock) u64 {
    if (builtin.os.tag != .windows) return os.now();
    var counter: i64 = 0;
    if (w.QueryPerformanceCounter(&counter) == 0) @panic("performance counter unavailable");
    const ticks: u64 = @intCast(counter);
    return (ticks / self.frequency) * 1_000_000_000 + (ticks % self.frequency) * 1_000_000_000 / self.frequency;
}

pub fn sample(self: *Clock) u64 {
    self.cached = self.now();
    return self.cached;
}
