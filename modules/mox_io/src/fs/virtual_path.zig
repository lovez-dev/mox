//! Portable, case-sensitive paths shared by the memory filesystems.

const bytes = @import("../mem/bytes.zig");
const utf8_decoder = @import("../text/utf8.zig");

pub const max_length = 4096;
pub const Error = error{ InvalidPath, NameTooLong };

pub const Order = enum { less, equal, greater };

/// Accept an optional root slash without allocating. Dot components are rejected.
pub fn canonical(input: []const u8) Error![]const u8 {
    const path = if (input.len != 0 and input[0] == '/') input[1..] else input;
    if (path.len > max_length) return error.NameTooLong;
    if (path.len == 0) return path;
    var start: usize = 0;
    for (path, 0..) |byte, index| {
        if (byte == 0 or byte == '\\' or byte == ':') return error.InvalidPath;
        if (byte == '/') {
            try component(path[start..index]);
            start = index + 1;
        }
    }
    try component(path[start..]);
    try utf8(path);
    return path;
}

pub fn parent(path: []const u8) []const u8 {
    var index = path.len;
    while (index != 0) {
        index -= 1;
        if (path[index] == '/') return path[0..index];
    }
    return "";
}

pub fn basename(path: []const u8) []const u8 {
    const prefix = parent(path);
    return if (prefix.len == 0) path else path[prefix.len + 1 ..];
}

pub fn compare(left: []const u8, right: []const u8) Order {
    for (left[0..@min(left.len, right.len)], right[0..@min(left.len, right.len)]) |a, b| {
        if (a < b) return .less;
        if (a > b) return .greater;
    }
    return if (left.len < right.len) .less else if (left.len > right.len) .greater else .equal;
}

/// Compare against the entire "directory/" prefix, including adjacent names.
pub fn compareDirectory(candidate: []const u8, directory: []const u8) Order {
    if (directory.len == 0) return .equal;
    const prefix = compare(candidate[0..@min(candidate.len, directory.len)], directory);
    if (prefix != .equal) return prefix;
    if (candidate.len == directory.len) return .less;
    return if (candidate[directory.len] < '/') .less else if (candidate[directory.len] > '/') .greater else .equal;
}

fn component(value: []const u8) Error!void {
    if (value.len == 0 or bytes.equal(value, ".") or bytes.equal(value, "..")) return error.InvalidPath;
}

fn utf8(input: []const u8) Error!void {
    var index: usize = 0;
    while (index < input.len) {
        const scalar = utf8_decoder.decode(input[index..]) catch return error.InvalidPath;
        index += scalar.length;
    }
}
