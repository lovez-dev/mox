//! Compute checked, aligned partitions for a single backing allocation.

pub const Layout = struct {
    size: usize = 0,

    pub fn add(self: *Layout, comptime T: type, count: usize) error{SizeOverflow}!void {
        const padding = @alignOf(T) - 1;
        const aligned = @addWithOverflow(self.size, padding);
        if (aligned[1] != 0) return error.SizeOverflow;
        const product = @mulWithOverflow(@sizeOf(T), count);
        if (product[1] != 0) return error.SizeOverflow;
        const next = @addWithOverflow(aligned[0] & ~@as(usize, padding), product[0]);
        if (next[1] != 0) return error.SizeOverflow;
        self.size = next[0];
    }
};
