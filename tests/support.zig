//! Serialize network fixtures that publish listening ports through global callbacks.

const std = @import("std");
const io = @import("mox_io");

var locked: std.atomic.Value(bool) = .init(false);

pub fn lock() void {
    while (locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) io.sync.Thread.yield();
}

pub fn unlock() void {
    locked.store(false, .release);
}
