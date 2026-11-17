//! Memory filesystem ownership, quota, failure and data-preservation contracts.

const std = @import("std");

const testing = std.testing;
const mox_io = @import("mox_io");

const MemoryFs = mox_io.fs.MemoryFs;
const Adapter = @import("../support/allocator.zig");

test "memory fs directories, paths and allocation accounting" {
    var provider: Adapter = .{ .parent = testing.allocator };
    var outer: mox_io.mem.TrackingAllocator = .{ .parent = provider.allocator() };
    var fs: MemoryFs = undefined;
    try fs.init(outer.allocator(), .{ .nodes = 16, .open_files = 4 });
    errdefer fs.deinit() catch {};
    try fs.makePath("assets/css");
    try fs.makePath("/assets/css");
    try fs.writeFile("assets/css/main.css", "body {}");
    try fs.writeFile("Case", "upper");
    try fs.writeFile("case", "lower");
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("body {}", try fs.readFile("/assets/css/main.css", &buffer));
    try testing.expectEqualStrings("upper", try fs.readFile("Case", &buffer));
    try testing.expectEqualStrings("lower", try fs.readFile("case", &buffer));
    try testing.expectEqual(mox_io.fs.Kind.directory, (try fs.stat("/")).kind);
    try testing.expectEqual(@as(usize, 3), fs.stats().directories);
    try testing.expectEqual(@as(usize, 3), fs.stats().files);
    try testing.expectEqual(@as(usize, 17), fs.stats().data_bytes);
    try testing.expectEqual(fs.stats().memory.live_bytes, outer.stats().live_bytes);
    try testing.expectError(error.DirectoryNotEmpty, fs.removeDir("assets"));
    try testing.expectError(error.NotDirectory, fs.makePath("Case/child"));
    try testing.expectError(error.FileNotFound, fs.writeFile("missing/child", "x"));
    try testing.expectError(error.IsDirectory, fs.readFile("assets", &buffer));
    try testing.expectError(error.BufferTooSmall, fs.readFile("Case", buffer[0..1]));
    try testing.expectError(error.Busy, fs.removeDir(""));
    try fs.deleteFile("assets/css/main.css");
    try fs.removeDir("assets/css");
    try fs.removeDir("assets");
    try fs.deinit();
    try testing.expectEqual(@as(usize, 0), outer.stats().live_bytes);
    try testing.expectEqual(@as(usize, 0), fs.stats().capacity_bytes);
    try testing.expectEqual(fs.stats().memory.allocations, fs.stats().memory.releases);
    try testing.expectError(error.InvalidState, fs.makeDir("after-close"));
}

test "memory fs holes, cursors and truncate regrowth are zero initialized" {
    var provider: Adapter = .{ .parent = testing.allocator };
    var fs: MemoryFs = undefined;
    try fs.init(provider.allocator(), .{ .nodes = 4, .open_files = 2 });
    defer fs.deinit() catch @panic("filesystem cleanup failed");
    const file = try fs.open("data", .{ .access = .read_write, .creation = .create_new });
    defer file.close() catch @panic("file cleanup failed");
    try file.reserve(128);
    const allocations = fs.stats().memory.allocations;
    try testing.expectEqual(@as(usize, 3), try file.write("abc"));
    try file.seek(6);
    _ = try file.write("z");
    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings("abc\x00\x00\x00z", try fs.readFile("data", &buffer));
    try file.truncate(2);
    try file.truncate(8);
    try testing.expectEqualStrings("ab\x00\x00\x00\x00\x00\x00", try fs.readFile("data", &buffer));
    try file.seek(1);
    try testing.expectEqual(@as(usize, 2), try file.read(buffer[0..2]));
    try testing.expectEqualStrings("b\x00", buffer[0..2]);
    try testing.expectEqual(@as(usize, 0), try file.readAt(&buffer, ~@as(u64, 0)));
    try testing.expectError(error.FileTooLarge, file.writeAt("x", ~@as(u64, 0)));
    try testing.expectEqual(@as(usize, 0), try file.writeAt("", ~@as(u64, 0)));
    try testing.expectEqual(allocations, fs.stats().memory.allocations);
}

test "memory fs unlink retains open data and stale handles cannot alias replacements" {
    var provider: Adapter = .{ .parent = testing.allocator };
    var fs: MemoryFs = undefined;
    try fs.init(provider.allocator(), .{ .nodes = 4, .open_files = 2 });
    defer fs.deinit() catch @panic("filesystem cleanup failed");
    try fs.writeFile("file", "old");
    const first = try fs.open("file", .{});
    const second = try fs.open("file", .{});
    try testing.expectError(error.Busy, fs.deinit());
    try fs.deleteFile("file");
    try testing.expectError(error.FileNotFound, fs.stat("file"));
    try fs.writeFile("file", "new");
    var buffer: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 3), try second.read(&buffer));
    try testing.expectEqualStrings("old", buffer[0..3]);
    try testing.expectEqualStrings("new", try fs.readFile("file", &buffer));
    try first.close();
    try testing.expectEqual(@as(usize, 1), fs.stats().unlinked_files);
    try testing.expectEqual(@as(usize, 6), fs.stats().data_bytes);
    try second.close();
    try testing.expectEqual(@as(usize, 0), fs.stats().unlinked_files);
    try testing.expectEqual(@as(usize, 3), fs.stats().data_bytes);
    const replacement = try fs.open("file", .{});
    defer replacement.close() catch @panic("file cleanup failed");
    try testing.expectError(error.StaleHandle, first.read(&buffer));
    try testing.expectError(error.StaleHandle, second.close());
}

test "memory fs handle capacity and access failures preserve files" {
    var provider: Adapter = .{ .parent = testing.allocator };
    var fs: MemoryFs = undefined;
    try fs.init(provider.allocator(), .{ .nodes = 3, .open_files = 1 });
    defer fs.deinit() catch @panic("filesystem cleanup failed");
    try fs.writeFile("file", "kept");
    const reader = try fs.open("file", .{});
    try testing.expectError(error.AccessDenied, reader.write("x"));
    try testing.expectError(error.AccessDenied, reader.truncate(0));
    try testing.expectError(error.Capacity, fs.open("file", .{ .access = .write, .creation = .truncate_existing }));
    try testing.expectError(error.Capacity, fs.open("new", .{ .creation = .create_new }));
    try testing.expectError(error.FileNotFound, fs.stat("new"));
    var buffer: [8]u8 = undefined;
    try testing.expectEqualStrings("kept", try fs.readFile("file", &buffer));
    try reader.close();
    try testing.expectError(error.InvalidOptions, fs.open("file", .{ .creation = .create_always }));
    try testing.expectError(error.PathAlreadyExists, fs.open("file", .{ .creation = .create_new }));
    const writer = try fs.open("file", .{ .access = .write, .creation = .create_always });
    try testing.expectEqual(@as(u64, 0), (try writer.stat()).size);
    try testing.expectError(error.AccessDenied, writer.read(&buffer));
    try writer.close();
    try fs.makeDir("directory");
    try testing.expectError(error.Capacity, fs.makeDir("full"));
    try fs.removeDir("directory");
    try fs.makeDir("reused");
}

test "memory fs quotas include unlinked data and failed creates roll back" {
    var provider: Adapter = .{ .parent = testing.allocator };
    var fs: MemoryFs = undefined;
    try fs.init(provider.allocator(), .{ .nodes = 8, .open_files = 2, .max_file_size = 8, .max_data_bytes = 10 });
    defer fs.deinit() catch @panic("filesystem cleanup failed");
    try fs.writeFile("a", "123456");
    try fs.writeFile("b", "1234");
    const a = try fs.open("a", .{ .access = .read_write });
    defer a.close() catch @panic("file cleanup failed");
    const b = try fs.open("b", .{ .access = .read_write });
    defer b.close() catch @panic("file cleanup failed");
    try testing.expectError(error.QuotaExceeded, a.writeAt("8", 7));
    try testing.expectError(error.QuotaExceeded, fs.writeFile("c", "x"));
    try testing.expectError(error.FileNotFound, fs.stat("c"));
    try testing.expectEqual(@as(usize, 2), fs.stats().files);
    try fs.deleteFile("b");
    try testing.expectError(error.QuotaExceeded, a.truncate(8));
    try b.truncate(2);
    _ = try a.writeAt("8", 7);
    try testing.expectEqual(@as(usize, 10), fs.stats().data_bytes);
    try testing.expectError(error.FileTooLarge, a.truncate(9));
    try fs.writeFile("empty", "");
}

test "memory fs directory iteration distinguishes adjacent prefixes and detects mutation" {
    var provider: Adapter = .{ .parent = testing.allocator };
    var fs: MemoryFs = undefined;
    try fs.init(provider.allocator(), .{ .nodes = 16, .open_files = 0 });
    defer fs.deinit() catch @panic("filesystem cleanup failed");
    try fs.makePath("a/nested");
    try fs.writeFile("a-", "adjacent");
    try fs.writeFile("a_b", "after");
    try fs.writeFile("a/z", "z");
    try fs.writeFile("a/b", "b");
    try fs.writeFile("a/nested/file", "nested");
    var iterator = try fs.iterate("a");
    try testing.expectEqualStrings("b", (try iterator.next()).?.name);
    try testing.expectEqualStrings("nested", (try iterator.next()).?.name);
    try testing.expectEqualStrings("z", (try iterator.next()).?.name);
    try testing.expect(try iterator.next() == null);
    iterator = try fs.iterate("a");
    try fs.writeFile("a/b", "updated");
    try testing.expectEqualStrings("b", (try iterator.next()).?.name);
    try fs.deleteFile("a/z");
    try testing.expectError(error.StaleIterator, iterator.next());
}

test "memory fs allocation failures release every owned allocation" {
    try testing.checkAllAllocationFailures(testing.allocator, exerciseAllocations, .{});
}

fn exerciseAllocations(allocator: std.mem.Allocator) !void {
    var provider: Adapter = .{ .parent = allocator };
    var fs: MemoryFs = undefined;
    try fs.init(provider.allocator(), .{ .nodes = 16, .open_files = 2 });
    defer fs.deinit() catch @panic("filesystem cleanup failed");
    try fs.makePath("a/b");
    try fs.writeFile("a/b/file", "original");
    const file = try fs.open("a/b/file", .{ .access = .read_write });
    defer file.close() catch @panic("file cleanup failed");
    try file.reserve(1024);
    try file.truncate(2048);
    try fs.deleteFile("a/b/file");
    try fs.writeFile("a/b/file", "replacement");
}

test "memory fs failed growth preserves content and failed writes leave no entry" {
    for (0..3) |failure| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        var provider: Adapter = .{ .parent = failing.allocator() };
        var fs: MemoryFs = undefined;
        try fs.init(provider.allocator(), .{ .nodes = 8, .open_files = 2 });
        defer fs.deinit() catch @panic("filesystem cleanup failed");
        try fs.writeFile("file", "original");
        const before = fs.stats();
        failing.fail_index = failing.alloc_index + if (failure == 2) @as(usize, 1) else 0;
        const content: [1024]u8 = @splat(0xaa);
        try testing.expectError(error.OutOfMemory, fs.writeFile(if (failure == 0) "file" else "new", &content));
        var buffer: [16]u8 = undefined;
        try testing.expectEqualStrings("original", try fs.readFile("file", &buffer));
        try testing.expectError(error.FileNotFound, fs.stat("new"));
        try testing.expectEqual(before.memory.live_bytes, fs.stats().memory.live_bytes);
        try testing.expectEqual(before.data_bytes, fs.stats().data_bytes);
        try testing.expectEqual(before.files, fs.stats().files);
    }
}

test "memory fs random writes and truncations match a bounded byte model" {
    var provider: Adapter = .{ .parent = testing.allocator };
    var fs: MemoryFs = undefined;
    try fs.init(provider.allocator(), .{ .nodes = 2, .open_files = 1, .max_file_size = 64 });
    defer fs.deinit() catch @panic("filesystem cleanup failed");
    const file = try fs.open("file", .{ .access = .read_write, .creation = .create_new });
    defer file.close() catch @panic("file cleanup failed");
    try file.reserve(64);
    const allocations = fs.stats().memory.allocations;
    var model: [64]u8 = @splat(0);
    var length: usize = 0;
    var state: u64 = 0x123456789abcdef;
    var output: [64]u8 = undefined;
    for (0..1000) |_| {
        state = state *% 6364136223846793005 +% 1;
        const at: usize = @intCast((state >> 32) % 65);
        if (state & 1 == 0) {
            try file.truncate(at);
            if (at > length) @memset(model[length..at], 0);
            length = at;
        } else {
            const count: usize = @intCast((state >> 16) % (65 - at));
            const input: [64]u8 = @splat(@truncate(state >> 8));
            _ = try file.writeAt(input[0..count], at);
            if (count != 0) {
                if (at > length) @memset(model[length..at], 0);
                @memcpy(model[at..][0..count], input[0..count]);
                length = @max(length, at + count);
            }
        }
        try testing.expectEqualSlices(u8, model[0..length], try fs.readFile("file", &output));
        try testing.expectEqual(length, fs.stats().data_bytes);
    }
    try testing.expectEqual(allocations, fs.stats().memory.allocations);
}
