//! Serialize descriptor setup against library-managed process creation.

const Thread = @import("../sync/thread.zig");

var held: u8 = 0;

// Covers the non-atomic interval between descriptor creation and inheritance setup.
pub fn lock() void {
    while (@cmpxchgWeak(u8, &held, 0, 1, .acquire, .monotonic) != null) Thread.yield();
}

pub fn unlock() void {
    @atomicStore(u8, &held, 0, .release);
}
