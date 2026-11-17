//! Fixed-capacity owner-local FIFO storage.

/// An owner-only, fixed-capacity FIFO; callers provide any required synchronization.
pub fn Queue(comptime T: type) type {
    return struct {
        storage: []T,
        head: usize = 0,
        count: usize = 0,

        pub fn push(self: *@This(), value: T) bool {
            if (self.count == self.storage.len) return false;
            var tail = self.head + self.count;
            if (tail >= self.storage.len) tail -= self.storage.len;
            self.storage[tail] = value;
            self.count += 1;
            return true;
        }

        pub fn pop(self: *@This()) ?T {
            if (self.count == 0) return null;
            const value = self.storage[self.head];
            self.head += 1;
            if (self.head == self.storage.len) self.head = 0;
            self.count -= 1;
            return value;
        }
    };
}
