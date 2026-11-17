//! Small integer formatting helpers with caller-owned storage.

/// Format an unsigned integer without allocating or terminating the slice.
pub fn decimal(value: u64, output: *[20]u8) []const u8 {
    var remaining = value;
    var index: usize = output.len;
    while (true) {
        index -= 1;
        output[index] = @intCast(48 + remaining % 10);
        remaining /= 10;
        if (remaining == 0) return output[index..];
    }
}
