//! Fixed wire fixtures test the decoder independently of the packing tool.

const testing = @import("std").testing;
const mox_io = @import("mox_io");

const EmbeddedFs = mox_io.fs.EmbeddedFs;

const fixture = "LZIOFS\r\n" ++
    "\x01\x00\x00\x00\x28\x00\x00\x00" ++
    "\x01\x00\x00\x00\x00\x00\x00\x00" ++
    "\x02\x00\x00\x00\x00\x00\x00\x00" ++
    "\x02\x00\x00\x00\x00\x00\x00\x00" ++
    "\x00\x00\x00\x00\x00\x00\x00\x00" ++
    "\x02\x00\x00\x00\x00\x00\x00\x00" ++
    "\x00\x00\x00\x00\x00\x00\x00\x00" ++
    "\x02\x00\x00\x00\x00\x00\x00\x00" ++
    "\xff\xff\xff\xff\xff\xff\xff\xff" ++
    "hiok";

test "embedded fs mounts an unaligned image and borrows file contents" {
    var buffer: [fixture.len + 1]u8 = undefined;
    @memcpy(buffer[1..], fixture);
    const fs = try EmbeddedFs.init(buffer[1..]);
    const contents = try fs.readFile("/hi");
    try testing.expectEqualStrings("ok", contents);
    try testing.expect(contents.ptr == buffer[83..].ptr);
    try testing.expectEqual(@as(usize, 1), fs.stats().files);
    try testing.expectEqual(@as(usize, 1), fs.stats().directories);
    try testing.expectEqual(@as(usize, 2), fs.stats().data_bytes);
    try testing.expectEqual(fixture.len, fs.stats().image_bytes);
    try testing.expectEqual(@as(u64, 2), (try fs.stat("hi")).size);
    try testing.expectEqual(mox_io.fs.Kind.directory, (try fs.stat("")).kind);
    try testing.expectError(error.FileNotFound, fs.readFile("HI"));
    try testing.expectError(error.IsDirectory, fs.readFile("/"));
    try testing.expectError(error.NotDirectory, fs.iterate("hi"));
    try testing.expectError(error.ReadOnly, fs.open("hi", .{ .access = .write }));
    try testing.expectError(error.ReadOnly, fs.open("hi", .{ .creation = .create_new }));
    var iterator = try fs.iterate("/");
    try testing.expectEqualStrings("hi", iterator.next().?.name);
    try testing.expect(iterator.next() == null);
    var file = try fs.open("hi", .{});
    var output: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), file.read(output[0..1]));
    try testing.expectEqualStrings("o", output[0..1]);
    try testing.expectEqual(@as(usize, 1), file.read(&output));
    try testing.expectEqualStrings("k", output[0..1]);
    file.seek(~@as(u64, 0));
    try testing.expectEqual(@as(usize, 0), file.read(&output));
    try testing.expectEqual(@as(u64, 2), file.stat().size);
}

test "embedded fs rejects truncated and inconsistent image ranges" {
    for (0..fixture.len) |length| try testing.expectError(error.InvalidImage, EmbeddedFs.init(fixture[0..length]));
    var buffer: [fixture.len + 1]u8 = undefined;
    @memcpy(buffer[0..fixture.len], fixture);
    buffer[fixture.len] = 0;
    try testing.expectError(error.InvalidImage, EmbeddedFs.init(&buffer));
    for ([_]usize{ 0, 12, 16, 24, 32, 40, 48, 52, 56, 64, 72 }) |offset| {
        @memcpy(buffer[0..fixture.len], fixture);
        buffer[offset] ^= 0x7f;
        try testing.expectError(error.InvalidImage, EmbeddedFs.init(buffer[0..fixture.len]));
    }
    @memcpy(buffer[0..fixture.len], fixture);
    buffer[8] = 2;
    try testing.expectError(error.UnsupportedVersion, EmbeddedFs.init(buffer[0..fixture.len]));
    for ([_]usize{ 16, 24, 32, 40, 56, 64 }) |offset| {
        @memcpy(buffer[0..fixture.len], fixture);
        @memset(buffer[offset..][0..8], 0xff);
        try testing.expectError(error.InvalidImage, EmbeddedFs.init(buffer[0..fixture.len]));
    }
}

test "embedded fs rejects invalid paths inside images" {
    for ([_][]const u8{ "..", "/h", "h/", "h\\", "h:", "h\x00", "\xc0\xae", "\xffh" }) |name| {
        var buffer: [fixture.len]u8 = undefined;
        @memcpy(&buffer, fixture);
        @memcpy(buffer[80..82], name);
        try testing.expectError(error.InvalidImage, EmbeddedFs.init(&buffer));
    }
}

test "embedded fs mutated wire fields never yield out of bounds views" {
    for (0..fixture.len) |offset| {
        for (0..8) |bit| {
            var buffer: [fixture.len]u8 = undefined;
            @memcpy(&buffer, fixture);
            buffer[offset] ^= @as(u8, 1) << @intCast(bit);
            const fs = EmbeddedFs.init(&buffer) catch continue;
            for (0..fs.image.count) |index| {
                const entry = fs.image.entry(index).?;
                try testing.expect(@intFromPtr(entry.data.ptr) >= @intFromPtr(&buffer));
                try testing.expect(@intFromPtr(entry.data.ptr) + entry.data.len <= @intFromPtr(&buffer) + buffer.len);
                if (entry.kind == .file) try testing.expectEqualSlices(u8, entry.data, try fs.readFile(entry.path));
            }
        }
    }
}

test "virtual paths reject traversal and preserve valid UTF-8" {
    const path = mox_io.fs.path.virtual;
    try testing.expectEqualStrings("a/b", try path.canonical("/a/b"));
    try testing.expectEqualStrings("", try path.canonical("/"));
    try testing.expectEqualStrings("caf\xc3\xa9", try path.canonical("caf\xc3\xa9"));
    for ([_][]const u8{ "../file", "a/../b", "a/./b", "a//b", "a/", "//a", "C:/a", "a\\b", "a\x00b", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xe0\x80\x80", "\xc2" }) |invalid| {
        try testing.expectError(error.InvalidPath, path.canonical(invalid));
    }
    const too_long: [path.max_length + 1]u8 = @splat('a');
    try testing.expectError(error.NameTooLong, path.canonical(&too_long));
}

test "native and virtual paths share strict Unicode decoding with separate policies" {
    const path = mox_io.fs.path;
    var output: [16]u16 = undefined;
    const unicode = "a\xc2\x80\xe0\xa0\x80\xf0\x90\x80\x80\xf4\x8f\xbf\xbf";
    try testing.expectEqualSlices(u16, &.{ 'a', 0x80, 0x800, 0xd800, 0xdc00, 0xdbff, 0xdfff }, try path.utf16(unicode, &output));
    try testing.expectEqualStrings(unicode, try path.virtual.canonical(unicode));
    for ([_][]const u8{ "\x80", "\xc0\x80", "\xc1\xbf", "\xe0\x9f\xbf", "\xed\xa0\x80", "\xf0\x8f\xbf\xbf", "\xf4\x90\x80\x80", "\xf5\x80\x80\x80", "\xe2\x82", "\xc2a" }) |invalid| {
        try testing.expectError(error.InvalidOptions, path.utf16(invalid, &output));
        try testing.expectError(error.InvalidPath, path.virtual.canonical(invalid));
    }
    try testing.expectEqualSlices(u16, &.{ 'C', ':', '\\', 'a' }, try path.utf16("C:\\a", &output));
    try testing.expectError(error.InvalidPath, path.virtual.canonical("C:\\a"));
    try testing.expectError(error.InvalidOptions, path.utf16("a\x00b", &output));

    // Conversion reserves the sentinel even when a scalar needs a surrogate pair.
    var pair_only: [2]u16 = undefined;
    var pair_and_sentinel: [3]u16 = undefined;
    try testing.expectError(error.Capacity, path.utf16("\xf0\x90\x80\x80", &pair_only));
    const pair = try path.utf16("\xf0\x90\x80\x80", &pair_and_sentinel);
    try testing.expectEqualSlices(u16, &.{ 0xd800, 0xdc00 }, pair);
    try testing.expectEqual(@as(u16, 0), pair.ptr[pair.len]);
}

test "embedded fs permits concurrent readers with independent file cursors" {
    const fs = try EmbeddedFs.init(fixture);
    var readers: [4]Reader = undefined;
    var threads: [4]mox_io.sync.Thread = undefined;
    var started: usize = 0;
    defer for (threads[0..started]) |*thread| thread.join();
    for (&readers, &threads) |*reader, *thread| {
        reader.* = .{ .fs = &fs };
        try thread.start(readShared, reader);
        started += 1;
    }
    for (threads[0..started]) |*thread| thread.join();
    started = 0;
    for (readers) |reader| try testing.expect(!reader.failed);
}

const Reader = struct { fs: *const EmbeddedFs, failed: bool = false };

fn readShared(context: *anyopaque) void {
    const reader: *Reader = @ptrCast(@alignCast(context));
    readerWork(reader.fs) catch {
        reader.failed = true;
    };
}

fn readerWork(fs: *const EmbeddedFs) !void {
    for (0..500) |_| {
        var file = try fs.open("hi", .{});
        var buffer: [2]u8 = undefined;
        if (file.read(buffer[0..1]) != 1 or buffer[0] != 'o') return error.WrongData;
        if (file.read(buffer[1..]) != 1 or buffer[1] != 'k') return error.WrongData;
        if (!mox_io.mem.bytes.equal(try fs.readFile("hi"), "ok")) return error.WrongData;
        var iterator = try fs.iterate("");
        if (!mox_io.mem.bytes.equal(iterator.next().?.name, "hi") or iterator.next() != null) return error.WrongData;
    }
}
