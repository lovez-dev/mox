//! Version 1 uses little-endian integers and offsets, never native struct layouts.

const Image = @This();

const path = @import("virtual_path.zig");
const byte_utils = @import("../mem/bytes.zig");
const Kind = @import("types.zig").Kind;

pub const magic = "LZIOFS\r\n";
pub const version: u32 = 1;
pub const header_size = 40;
pub const entry_size = 40;
pub const root_parent = ~@as(u64, 0);

pub const Error = error{ InvalidImage, UnsupportedVersion };

pub const Entry = struct { path: []const u8, kind: Kind, data: []const u8, parent: ?usize };

bytes: []const u8,
count: usize,
paths: []const u8,
data: []const u8,
files: usize = 0,
directories: usize = 1,

/// Validate once. The backing bytes must remain immutable for the view's lifetime.
pub fn init(input: []const u8) Error!Image {
    if (input.len < header_size or !byte_utils.equal(input[0..8], magic)) return error.InvalidImage;
    if (read(u32, input[8..12]) != version) return error.UnsupportedVersion;
    if (read(u32, input[12..16]) != entry_size) return error.InvalidImage;
    const count = try size(read(u64, input[16..24]));
    const paths_size = try size(read(u64, input[24..32]));
    const data_size = try size(read(u64, input[32..40]));
    if (count > (input.len - header_size) / entry_size) return error.InvalidImage;
    const paths_start = header_size + count * entry_size;
    if (paths_size > input.len - paths_start) return error.InvalidImage;
    const data_start = paths_start + paths_size;
    if (data_size != input.len - data_start) return error.InvalidImage;
    var self: Image = .{
        .bytes = input,
        .count = count,
        .paths = input[paths_start..data_start],
        .data = input[data_start..],
    };
    // Packed offsets and sorted paths are validated before later zero-copy lookups.
    var path_offset: usize = 0;
    var data_offset: usize = 0;
    var previous: []const u8 = "";
    for (0..count) |index| {
        const record = self.getRecord(index);
        const path_length = read(u32, record[8..12]);
        const kind = read(u32, record[12..16]);
        const data_length = try size(read(u64, record[24..32]));
        if (read(u64, record[0..8]) != path_offset or path_length > paths_size - path_offset or
            read(u64, record[16..24]) != data_offset or data_length > data_size - data_offset or
            kind > 1 or (kind == 1 and data_length != 0)) return error.InvalidImage;
        const name = self.paths[path_offset..][0..path_length];
        const normalized = path.canonical(name) catch return error.InvalidImage;
        if (name.len == 0 or normalized.len != name.len or path.compare(previous, name) != .less) return error.InvalidImage;
        const parent_name = path.parent(name);
        const parent_index = read(u64, record[32..40]);
        if (parent_name.len == 0) {
            if (parent_index != root_parent) return error.InvalidImage;
        } else {
            if (parent_index >= index) return error.InvalidImage;
            const directory = self.entry(@intCast(parent_index)).?;
            if (directory.kind != .directory or !byte_utils.equal(directory.path, parent_name)) return error.InvalidImage;
        }
        if (kind == 0) self.files += 1 else self.directories += 1;
        path_offset += path_length;
        data_offset += data_length;
        previous = name;
    }
    if (path_offset != paths_size or data_offset != data_size) return error.InvalidImage;
    return self;
}

pub fn entry(self: Image, index: usize) ?Entry {
    if (index >= self.count) return null;
    const record = self.getRecord(index);
    const path_offset: usize = @intCast(read(u64, record[0..8]));
    const path_length = read(u32, record[8..12]);
    const data_offset: usize = @intCast(read(u64, record[16..24]));
    const data_length: usize = @intCast(read(u64, record[24..32]));
    const parent_index = read(u64, record[32..40]);
    return .{
        .path = self.paths[path_offset..][0..path_length],
        .kind = if (read(u32, record[12..16]) == 0) .file else .directory,
        .data = self.data[data_offset..][0..data_length],
        .parent = if (parent_index == root_parent) null else @intCast(parent_index),
    };
}

pub fn find(self: Image, name: []const u8) ?usize {
    var low: usize = 0;
    var high = self.count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (path.compare(self.entry(middle).?.path, name)) {
            .less => low = middle + 1,
            .greater => high = middle,
            .equal => return middle,
        }
    }
    return null;
}

fn getRecord(self: Image, index: usize) []const u8 {
    return self.bytes[header_size + index * entry_size ..][0..entry_size];
}

fn size(value: u64) Error!usize {
    if (value > ~@as(usize, 0)) return error.InvalidImage;
    return @intCast(value);
}

/// Byte loads also support images at unaligned addresses and big-endian targets.
pub fn read(comptime T: type, input: []const u8) T {
    var value: T = 0;
    for (input[0..@sizeOf(T)], 0..) |byte, shift| value |= @as(T, byte) << @intCast(shift * 8);
    return value;
}

pub fn write(comptime T: type, output: []u8, value: T) void {
    for (output[0..@sizeOf(T)], 0..) |*byte, shift| byte.* = @truncate(value >> @intCast(shift * 8));
}
