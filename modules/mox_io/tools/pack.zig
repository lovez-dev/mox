//! Deterministic image generation; only metadata is retained while file data streams.

const std = @import("std");
const mox_io = @import("mox_io");

const image = mox_io.fs.image;
const path = mox_io.fs.path.virtual;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Plan = @This();

pub const Options = struct {
    max_bytes: u64 = 4 * 1024 * 1024 * 1024,
    max_entries: u32 = 1_000_000,
};

const Entry = struct {
    path: []const u8,
    kind: mox_io.fs.Kind,
    size: u64,
    parent: u64 = image.root_parent,
};

const Frame = struct { dir: Io.Dir, iterator: Io.Dir.Iterator, prefix: []const u8, owned: bool };

allocator: Allocator,
entries: std.ArrayList(Entry) = .empty,
path_bytes: u64 = 0,
data_bytes: u64 = 0,

pub fn init(allocator: Allocator, io: Io, root: Io.Dir, options: Options) !Plan {
    var self: Plan = .{ .allocator = allocator };
    errdefer self.deinit();
    var stack: std.ArrayList(Frame) = .empty;
    defer {
        for (stack.items) |frame| if (frame.owned) frame.dir.close(io);
        stack.deinit(allocator);
    }
    try stack.append(allocator, .{ .dir = root, .iterator = root.iterate(), .prefix = "", .owned = false });
    while (stack.items.len != 0) {
        const frame = &stack.items[stack.items.len - 1];
        const item = try frame.iterator.next(io) orelse {
            const finished = stack.pop().?;
            if (finished.owned) finished.dir.close(io);
            continue;
        };
        if (self.entries.items.len >= options.max_entries) return error.TooManyEntries;
        const metadata = try frame.dir.statFile(io, item.name, .{ .follow_symlinks = false });
        const kind: mox_io.fs.Kind = switch (metadata.kind) {
            .file => .file,
            .directory => .directory,
            else => return error.UnsupportedFileType,
        };

        const key = if (frame.prefix.len == 0)
            try allocator.dupe(u8, item.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ frame.prefix, item.name });
        self.entries.append(allocator, .{ .path = key, .kind = kind, .size = if (kind == .file) metadata.size else 0 }) catch |err| {
            allocator.free(key);
            return err;
        };

        const normalized = try path.canonical(key);
        if (normalized.len != key.len) return error.InvalidPath;
        self.path_bytes = try add(self.path_bytes, key.len);
        if (kind == .file) self.data_bytes = try add(self.data_bytes, metadata.size);
        if (try self.size() > options.max_bytes) return error.ImageTooLarge;
        if (kind == .directory) {
            const child = try frame.dir.openDir(io, item.name, .{ .iterate = true, .follow_symlinks = false });
            stack.append(allocator, .{ .dir = child, .iterator = child.iterate(), .prefix = key, .owned = true }) catch |err| {
                child.close(io);
                return err;
            };
        }
    }
    if (try self.size() > options.max_bytes) return error.ImageTooLarge;
    std.mem.sort(Entry, self.entries.items, {}, lessThan);
    for (self.entries.items, 0..) |*item, index| {
        if (index != 0 and path.compare(self.entries.items[index - 1].path, item.path) != .less) return error.DuplicatePath;
        const parent_name = path.parent(item.path);
        if (parent_name.len != 0) {
            const parent = self.find(parent_name) orelse return error.FileChanged;
            if (parent >= index or self.entries.items[parent].kind != .directory) return error.FileChanged;
            item.parent = parent;
        }
    }
    return self;
}

pub fn deinit(self: *Plan) void {
    for (self.entries.items) |entry| self.allocator.free(entry.path);
    self.entries.deinit(self.allocator);
}

pub fn size(self: Plan) !u64 {
    const index_size = std.math.mul(u64, self.entries.items.len, image.entry_size) catch return error.ImageTooLarge;
    return add(try add(image.header_size, index_size), try add(self.path_bytes, self.data_bytes));
}

pub fn write(self: Plan, io: Io, root: Io.Dir, writer: *Io.Writer) !void {
    var header: [image.header_size]u8 = undefined;
    @memcpy(header[0..8], image.magic);
    image.write(u32, header[8..12], image.version);
    image.write(u32, header[12..16], image.entry_size);
    image.write(u64, header[16..24], self.entries.items.len);
    image.write(u64, header[24..32], self.path_bytes);
    image.write(u64, header[32..40], self.data_bytes);
    try writer.writeAll(&header);
    var path_offset: u64 = 0;
    var data_offset: u64 = 0;
    for (self.entries.items) |item| {
        var record: [image.entry_size]u8 = undefined;
        image.write(u64, record[0..8], path_offset);
        image.write(u32, record[8..12], @intCast(item.path.len));
        image.write(u32, record[12..16], if (item.kind == .file) 0 else 1);
        image.write(u64, record[16..24], data_offset);
        image.write(u64, record[24..32], item.size);
        image.write(u64, record[32..40], item.parent);
        try writer.writeAll(&record);
        path_offset += item.path.len;
        data_offset += item.size;
    }
    for (self.entries.items) |item| try writer.writeAll(item.path);
    var buffer: [64 * 1024]u8 = undefined;
    for (self.entries.items) |item| {
        if (item.kind != .file) continue;
        const file = try openFile(root, io, item.path);
        defer file.close(io);
        const before = try file.stat(io);
        if (before.kind != .file or before.size != item.size) return error.FileChanged;
        var offset: u64 = 0;
        while (offset < item.size) {
            const count: usize = @intCast(@min(buffer.len, item.size - offset));
            const read = try file.readPositional(io, &.{buffer[0..count]}, offset);
            if (read == 0) return error.FileChanged;
            try writer.writeAll(buffer[0..read]);
            offset += read;
        }

        const after = try file.stat(io);
        if (after.size != before.size or after.mtime.nanoseconds != before.mtime.nanoseconds) return error.FileChanged;
    }
}

fn find(self: Plan, name: []const u8) ?usize {
    var low: usize = 0;
    var high = self.entries.items.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (path.compare(self.entries.items[middle].path, name)) {
            .less => low = middle + 1,
            .greater => high = middle,
            .equal => return middle,
        }
    }
    return null;
}

/// Refuse links in every path component, even on hosts without resolve_beneath.
fn openFile(root: Io.Dir, io: Io, name: []const u8) !Io.File {
    var directory = root;
    var owned = false;
    defer if (owned) directory.close(io);
    var start: usize = 0;
    for (name, 0..) |byte, index| {
        if (byte != '/') continue;
        const next = try directory.openDir(io, name[start..index], .{ .follow_symlinks = false });
        if (owned) directory.close(io);
        directory = next;
        owned = true;
        start = index + 1;
    }
    return directory.openFile(io, name[start..], .{ .allow_directory = false, .follow_symlinks = false });
}

fn lessThan(_: void, left: Entry, right: Entry) bool {
    return path.compare(left.path, right.path) == .less;
}

fn add(left: u64, right: u64) !u64 {
    return std.math.add(u64, left, right) catch error.ImageTooLarge;
}
