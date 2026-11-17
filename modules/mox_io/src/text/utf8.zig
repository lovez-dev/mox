//! Allocation-free UTF-8 scalar decoding; callers choose their text policy.

pub const Scalar = struct { value: u32, length: usize };

/// Decode one Unicode scalar, rejecting overlong encodings and surrogates.
pub fn decode(input: []const u8) error{InvalidUtf8}!Scalar {
    if (input.len == 0) return error.InvalidUtf8;
    const first = input[0];
    const length: usize = if (first < 0x80) 1 else if (first >= 0xc2 and first <= 0xdf) 2 else if (first >= 0xe0 and first <= 0xef) 3 else if (first >= 0xf0 and first <= 0xf4) 4 else return error.InvalidUtf8;
    if (length > input.len) return error.InvalidUtf8;
    var value: u32 = first & switch (length) {
        1 => @as(u8, 0x7f),
        2 => @as(u8, 0x1f),
        3 => @as(u8, 0x0f),
        else => @as(u8, 0x07),
    };
    for (input[1..length]) |byte| {
        if (byte & 0xc0 != 0x80) return error.InvalidUtf8;
        value = (value << 6) | (byte & 63);
    }
    if (value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff) or
        (length == 3 and value < 0x800) or (length == 4 and value < 0x10000)) return error.InvalidUtf8;
    return .{ .value = value, .length = length };
}
