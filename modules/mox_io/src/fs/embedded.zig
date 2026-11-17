//! Immutable filesystem views. Mounting, lookup and reading require no allocator.

const EmbeddedFs = @This();

const Image = @import("image.zig");
const path = @import("virtual_path.zig");
const t = @import("types.zig");

pub const Error = Image.Error || path.Error || error{ FileNotFound, IsDirectory, NotDirectory, ReadOnly };

pub const Stats = struct { files: usize, directories: usize, data_bytes: usize, image_bytes: usize };

image: Image,

/// The caller retains ownership of the image, including all returned file slices.
pub fn init(bytes: []const u8) Error!EmbeddedFs {
    return .{ .image = try Image.init(bytes) };
}

pub fn readFile(self: EmbeddedFs, name: []const u8) Error![]const u8 {
    const key = try path.canonical(name);
    if (key.len == 0) return error.IsDirectory;
    const item = self.image.entry(self.image.find(key) orelse return error.FileNotFound).?;
    if (item.kind == .directory) return error.IsDirectory;
    return item.data;
}

pub fn open(self: EmbeddedFs, name: []const u8, options: t.OpenOptions) Error!File {
    if (options.access != .read or options.creation != .open_existing) return error.ReadOnly;
    return .{ .data = try self.readFile(name) };
}

pub fn stat(self: EmbeddedFs, name: []const u8) Error!t.Info {
    const key = try path.canonical(name);
    if (key.len == 0) return .{ .kind = .directory };
    const item = self.image.entry(self.image.find(key) orelse return error.FileNotFound).?;
    return .{ .kind = item.kind, .size = item.data.len, .allocated_size = item.data.len };
}

pub fn stats(self: EmbeddedFs) Stats {
    return .{ .files = self.image.files, .directories = self.image.directories, .data_bytes = self.image.data.len, .image_bytes = self.image.bytes.len };
}

/// Entries are returned in bytewise path order, with names relative to the directory.
pub fn iterate(self: EmbeddedFs, name: []const u8) Error!Iterator {
    const key = try path.canonical(name);
    if (key.len == 0) return .{ .image = self.image, .directory = "", .parent = null, .index = 0 };
    const index = self.image.find(key) orelse return error.FileNotFound;
    const item = self.image.entry(index).?;
    if (item.kind != .directory) return error.NotDirectory;
    return .{ .image = self.image, .directory = item.path, .parent = index, .index = index + 1 };
}

pub const Iterator = struct {
    image: Image,
    directory: []const u8,
    parent: ?usize,
    index: usize,

    pub fn next(self: *Iterator) ?t.DirectoryEntry {
        while (self.image.entry(self.index)) |item| {
            self.index += 1;
            switch (path.compareDirectory(item.path, self.directory)) {
                .less => continue,
                .greater => return null,
                .equal => {},
            }
            if (item.parent == self.parent) return .{ .name = path.basename(item.path), .kind = item.kind };
        }
        return null;
    }
};

pub const File = struct {
    data: []const u8,
    position: u64 = 0,

    pub fn readAt(self: File, output: []u8, offset: u64) usize {
        if (offset >= self.data.len) return 0;
        const start: usize = @intCast(offset);
        const count = @min(output.len, self.data.len - start);
        @memcpy(output[0..count], self.data[start..][0..count]);
        return count;
    }

    pub fn read(self: *File, output: []u8) usize {
        const count = self.readAt(output, self.position);
        self.position += count;
        return count;
    }

    pub fn seek(self: *File, offset: u64) void {
        self.position = offset;
    }

    pub fn stat(self: File) t.Info {
        return .{ .kind = .file, .size = self.data.len, .allocated_size = self.data.len };
    }
};
