//! Coalesced Linux wakeups shared by epoll and io_uring.

const s = @import("../abi/linux.zig");

pub fn signal(descriptor: i32) void {
    const value: u64 = 1;
    const bytes: [*]const u8 = @ptrCast(&value);
    while (true) {
        const code = s.errno(s.write(descriptor, bytes[0..8]));
        if (code == 4) continue;
        // A saturated counter already guarantees a pending wakeup.
        if (code != 0 and code != 11) @panic("eventfd wake failed");
        return;
    }
}

pub fn drain(descriptor: i32) void {
    var value: u64 = 0;
    const bytes: [*]u8 = @ptrCast(&value);
    while (true) {
        const code = s.errno(s.read(descriptor, bytes[0..8]));
        // One non-semaphore read consumes the entire accumulated counter.
        // Avoid a second read just to get EAGAIN; a later signal remains readable.
        // Only EINTR needs a retry because no counter value was consumed.
        if (code != 4) return;
    }
}
