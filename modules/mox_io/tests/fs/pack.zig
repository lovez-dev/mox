//! Round trips, deterministic ordering and source-tree failure cases.

const std = @import("std");

const testing = std.testing;
const Io = std.Io;
const mox_io = @import("mox_io");
const Pack = @import("mox_io_pack");

test "embed packer preserves files, empty directories and binary data" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try populate(tmp.dir, false);
    var plan = try Pack.init(testing.allocator, testing.io, tmp.dir, .{});
    defer plan.deinit();
    var output: Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try plan.write(testing.io, tmp.dir, &output.writer);
    const fs = try mox_io.fs.EmbeddedFs.init(output.written());
    try testing.expectEqual(@as(usize, 4), fs.stats().files);
    try testing.expectEqual(@as(usize, 4), fs.stats().directories);
    try testing.expectEqualStrings("\x00\xff\x01\x80", try fs.readFile("a/nested/blob"));
    try testing.expectEqualStrings("", try fs.readFile("a/z"));
    var iterator = try fs.iterate("a");
    try testing.expectEqualStrings("nested", iterator.next().?.name);
    try testing.expectEqualStrings("z", iterator.next().?.name);
    try testing.expect(iterator.next() == null);
    iterator = try fs.iterate("empty");
    try testing.expect(iterator.next() == null);
    try testing.expectEqual(try plan.size(), output.written().len);
    try testing.expectError(error.IsDirectory, fs.open("a", .{}));

    // A valid path must refer to an earlier directory, not just any earlier entry.
    const child = fs.image.find("a/nested/blob").?;
    mox_io.fs.image.write(u64, output.written()[mox_io.fs.image.header_size + child * mox_io.fs.image.entry_size + 32 ..][0..8], mox_io.fs.image.root_parent);
    try testing.expectError(error.InvalidImage, mox_io.fs.EmbeddedFs.init(output.written()));
}

test "embed packer output is independent of insertion order and source location" {
    var first = testing.tmpDir(.{ .iterate = true });
    defer first.cleanup();
    var second = testing.tmpDir(.{ .iterate = true });
    defer second.cleanup();
    try populate(first.dir, false);
    try populate(second.dir, true);
    var left = try Pack.init(testing.allocator, testing.io, first.dir, .{});
    defer left.deinit();
    var right = try Pack.init(testing.allocator, testing.io, second.dir, .{});
    defer right.deinit();
    var a: Io.Writer.Allocating = .init(testing.allocator);
    defer a.deinit();
    var b: Io.Writer.Allocating = .init(testing.allocator);
    defer b.deinit();
    try left.write(testing.io, first.dir, &a.writer);
    try right.write(testing.io, second.dir, &b.writer);
    try testing.expectEqualSlices(u8, a.written(), b.written());
}

test "embed packer streams files larger than its buffer and rejects changed sizes" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const data = try testing.allocator.alloc(u8, 128 * 1024 + 7);
    defer testing.allocator.free(data);
    for (data, 0..) |*byte, index| byte.* = @truncate(index *% 37 +% 11);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "large", .data = data });
    var plan = try Pack.init(testing.allocator, testing.io, tmp.dir, .{});
    defer plan.deinit();
    var output: Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try plan.write(testing.io, tmp.dir, &output.writer);
    const fs = try mox_io.fs.EmbeddedFs.init(output.written());
    try testing.expectEqualSlices(u8, data, try fs.readFile("large"));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "large", .data = "changed" });
    var buffer: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try testing.expectError(error.FileChanged, plan.write(testing.io, tmp.dir, &writer));
}

test "embed packer limits account for metadata and the empty root" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try testing.expectError(error.ImageTooLarge, Pack.init(testing.allocator, testing.io, tmp.dir, .{ .max_bytes = 39 }));
    var empty = try Pack.init(testing.allocator, testing.io, tmp.dir, .{ .max_bytes = 40, .max_entries = 0 });
    defer empty.deinit();
    var bytes: [40]u8 = undefined;
    var writer: Io.Writer = .fixed(&bytes);
    try empty.write(testing.io, tmp.dir, &writer);
    const fs = try mox_io.fs.EmbeddedFs.init(&bytes);
    try testing.expectEqual(@as(usize, 0), fs.stats().files);
    try testing.expectEqual(@as(usize, 1), fs.stats().directories);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "file", .data = "" });
    try testing.expectError(error.ImageTooLarge, Pack.init(testing.allocator, testing.io, tmp.dir, .{ .max_bytes = 40 }));
    try testing.expectError(error.TooManyEntries, Pack.init(testing.allocator, testing.io, tmp.dir, .{ .max_entries = 0 }));
}

test "embed packer metadata allocation failures release all paths and directory handles" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try populate(tmp.dir, false);
    try testing.checkAllAllocationFailures(testing.allocator, planWithAllocator, .{tmp.dir});
}

test "embed packer rejects symbolic links instead of following them" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "outside", .data = "private" });
    const source = try tmp.dir.createDirPathOpen(testing.io, "source", .{ .open_options = .{ .iterate = true } });
    defer source.close(testing.io);
    source.symLink(testing.io, "../outside", "link", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    try testing.expectError(error.UnsupportedFileType, Pack.init(testing.allocator, testing.io, source, .{}));
}

fn populate(directory: Io.Dir, reverse: bool) !void {
    const io = testing.io;
    if (reverse) try directory.createDirPath(io, "empty");
    try directory.createDirPath(io, "a/nested");
    const files = [_]struct { name: []const u8, bytes: []const u8 }{
        .{ .name = "a-", .bytes = "before" },
        .{ .name = "a_b", .bytes = "after" },
        .{ .name = "a/z", .bytes = "" },
        .{ .name = "a/nested/blob", .bytes = "\x00\xff\x01\x80" },
    };
    for (0..files.len) |index| {
        const file = files[if (reverse) files.len - 1 - index else index];
        try directory.writeFile(io, .{ .sub_path = file.name, .data = file.bytes });
    }
    if (!reverse) try directory.createDirPath(io, "empty");
}

fn planWithAllocator(allocator: std.mem.Allocator, directory: Io.Dir) !void {
    var plan = try Pack.init(allocator, testing.io, directory, .{});
    defer plan.deinit();
}
