//! Embed command, generated module and downstream build regressions.

const std = @import("std");

const testing = std.testing;
const Io = std.Io;
const mox_io = @import("mox_io");
const paths = @import("build-test-paths");

test "embed command round trips and preserves output when packing fails" {
    const io = testing.io;
    const executable = try absolute(paths.embed_executable);
    defer testing.allocator.free(executable);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets/nested/empty");
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/nested/file", .data = "\x00\xffbinary" });
    try command(tmp.dir, &.{ executable, "assets", "-o", "image.lzfs" }, .{});
    const original = try tmp.dir.readFileAlloc(io, "image.lzfs", testing.allocator, .unlimited);
    defer testing.allocator.free(original);
    const fs = try mox_io.fs.EmbeddedFs.init(original);
    try testing.expectEqualStrings("\x00\xffbinary", try fs.readFile("nested/file"));
    try testing.expectEqual(@as(usize, 3), fs.stats().directories);
    try command(tmp.dir, &.{ executable, "assets", "-o", "image.lzfs", "--max-bytes", "40" }, .{ .success = false, .stderr_contains = "ImageTooLarge" });
    const preserved = try tmp.dir.readFileAlloc(io, "image.lzfs", testing.allocator, .unlimited);
    defer testing.allocator.free(preserved);
    try testing.expectEqualSlices(u8, original, preserved);
    try command(tmp.dir, &.{ executable, "assets", "--module", "module" }, .{});
    const source = try tmp.dir.readFileAlloc(io, "module/root.zig", testing.allocator, .unlimited);
    defer testing.allocator.free(source);
    try testing.expect(std.mem.indexOf(u8, source, "@embedFile(\"assets.lzfs\")") != null);
    const generated = try tmp.dir.readFileAlloc(io, "module/assets.lzfs", testing.allocator, .unlimited);
    defer testing.allocator.free(generated);
    try testing.expectEqualSlices(u8, original, generated);
}

test "embed command rejects invalid arguments and output inside the input tree" {
    const io = testing.io;
    const executable = try absolute(paths.embed_executable);
    defer testing.allocator.free(executable);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets");
    try command(tmp.dir, &.{ executable, "--help" }, .{ .stdout_contains = "Usage: mox-io-embed" });
    try command(tmp.dir, &.{ executable, "--unknown" }, .{ .success = false, .stderr_contains = "InvalidArguments" });
    try command(tmp.dir, &.{ executable, "assets", "-o", "assets/image.lzfs" }, .{ .success = false, .stderr_contains = "OutputInsideInput" });
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "assets/image.lzfs", .{}));
}

test "embed build helper tracks nested edits, additions, removals and empty directories" {
    const io = testing.io;
    const compiler = try absolute(paths.zig_executable);
    defer testing.allocator.free(compiler);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try consumer(tmp.dir);
    try tmp.dir.createDirPath(io, "assets/nested");
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/nested/message.txt", .data = "one" });
    const argv: []const []const u8 = &.{ compiler, "build", "run", "--summary", "all" };
    try command(tmp.dir, argv, .{ .stdout = "one\nfiles=1 directories=2\n" });
    try command(tmp.dir, argv, .{ .stdout = "one\nfiles=1 directories=2\n", .stderr_contains = "mox-io-embed (embedded) cached" });
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/nested/message.txt", .data = "two" });
    try command(tmp.dir, argv, .{ .stdout = "two\nfiles=1 directories=2\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/nested/extra", .data = "extra" });
    try command(tmp.dir, argv, .{ .stdout = "two\nfiles=2 directories=2\n" });
    try tmp.dir.createDirPath(io, "assets/nested/empty");
    try command(tmp.dir, argv, .{ .stdout = "two\nfiles=2 directories=3\n" });
    try tmp.dir.deleteFile(io, "assets/nested/extra");
    try command(tmp.dir, argv, .{ .stdout = "two\nfiles=1 directories=3\n" });
    try tmp.dir.deleteDir(io, "assets/nested/empty");
    try command(tmp.dir, argv, .{ .stdout = "two\nfiles=1 directories=2\n" });
    try tmp.dir.createDirPath(io, "assets/nested/new");
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/nested/new/file", .data = "new" });
    try command(tmp.dir, argv, .{ .stdout = "two\nfiles=2 directories=3\n" });
    try tmp.dir.deleteTree(io, "assets/nested/new");
    try command(tmp.dir, argv, .{ .stdout = "two\nfiles=1 directories=2\n" });
}

test "embed build helper follows generated directory dependencies" {
    const compiler = try absolute(paths.zig_executable);
    defer testing.allocator.free(compiler);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try consumer(tmp.dir);
    try command(tmp.dir, &.{ compiler, "build", "run", "-Dgenerated=true", "-Dmessage=alpha" }, .{ .stdout = "alpha\nfiles=1 directories=2\n" });
    try command(tmp.dir, &.{ compiler, "build", "run", "-Dgenerated=true", "-Dmessage=beta" }, .{ .stdout = "beta\nfiles=1 directories=2\n" });
}

fn absolute(name: []const u8) ![:0]const u8 {
    return Io.Dir.cwd().realPathFileAlloc(testing.io, name, testing.allocator);
}

const Expected = struct { success: bool = true, stdout: ?[]const u8 = null, stdout_contains: ?[]const u8 = null, stderr_contains: ?[]const u8 = null };

fn command(directory: Io.Dir, argv: []const []const u8, expected: Expected) !void {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(testing.allocator);
    try args.appendSlice(testing.allocator, argv);
    var cache_path: ?[]const u8 = null;
    defer if (cache_path) |value| testing.allocator.free(value);
    if (argv.len > 1 and std.mem.eql(u8, argv[1], "build")) {
        // Nested builds inherit the parent's cache volume and explicit overrides.
        const cache_root = try absolute(paths.cache_root);
        defer testing.allocator.free(cache_root);
        var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
        const here = buffer[0..try directory.realPath(testing.io, &buffer)];
        cache_path = try std.fmt.allocPrint(testing.allocator, "{s}/embed-consumers/{x}", .{ cache_root, std.hash.Wyhash.hash(0, here) });
        try args.appendSlice(testing.allocator, &.{ "--cache-dir", cache_path.? });
    }
    const result = try std.process.run(testing.allocator, testing.io, .{ .argv = args.items, .cwd = .{ .dir = directory } });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    const success = result.term == .exited and result.term.exited == 0;
    if (success != expected.success) {
        testing.failPrint("stdout:\n{s}\nstderr:\n{s}\n", .{ result.stdout, result.stderr });
        return error.UnexpectedExit;
    }
    if (expected.stdout) |text| try testing.expectEqualStrings(text, result.stdout);
    if (expected.stdout_contains) |text| try testing.expect(std.mem.indexOf(u8, result.stdout, text) != null);
    if (expected.stderr_contains) |text| try testing.expect(std.mem.indexOf(u8, result.stderr, text) != null);
}

fn consumer(directory: Io.Dir) !void {
    const root = try absolute(paths.project_root);
    defer testing.allocator.free(root);
    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const here = buffer[0..try directory.realPath(testing.io, &buffer)];
    const relative = try std.fs.path.relativeAlloc(testing.allocator, root, null, here, root);
    defer testing.allocator.free(relative);
    const manifest = try std.fmt.allocPrint(testing.allocator,
        \\.{{
        \\    .name = .mox_io_embed_example,
        \\    .version = "0.1.0",
        \\    .fingerprint = 0x0ef4f61a91bb6d14,
        \\    .dependencies = .{{ .mox_io = .{{ .path = "{f}" }} }},
        \\    .paths = .{{
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "main.zig",
        \\        "assets",
        \\    }},
        \\}}
        \\
    , .{std.zig.fmtString(relative)});
    defer testing.allocator.free(manifest);
    try directory.writeFile(testing.io, .{ .sub_path = "build.zig.zon", .data = manifest });
    try directory.writeFile(testing.io, .{ .sub_path = "build.zig", .data = consumer_build });
    try directory.writeFile(testing.io, .{ .sub_path = "main.zig", .data = consumer_main });
    try directory.createDirPath(testing.io, "assets");
}

const consumer_build =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const dependency = b.dependency("mox_io", .{ .target = target });
    \\    const generated = b.option(bool, "generated", "Use generated inputs") orelse false;
    \\    const message = b.option([]const u8, "message", "Generated contents") orelse "generated";
    \\    const files = b.addWriteFiles();
    \\    _ = files.add("nested/message.txt", message);
    \\    const assets = @import("mox_io").embed(b, .{ .directory = if (generated) files.getDirectory() else b.path("assets") });
    \\    const exe = b.addExecutable(.{
    \\        .name = "consumer",
    \\        .root_module = b.createModule(.{
    \\            .root_source_file = b.path("main.zig"),
    \\            .target = target,
    \\            .imports = &.{ .{ .name = "mox_io", .module = dependency.module("mox_io") }, .{ .name = "assets", .module = assets } },
    \\        }),
    \\    });
    \\    b.step("run", "Read embedded files").dependOn(&b.addRunArtifact(exe).step);
    \\}
    \\
;

const consumer_main =
    \\const std = @import("std");
    \\const mox_io = @import("mox_io");
    \\pub fn main(init: std.process.Init) !void {
    \\    const fs = try mox_io.fs.EmbeddedFs.init(@import("assets").image);
    \\    var buffer: [1024]u8 = undefined;
    \\    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    \\    try writer.interface.print("{s}\nfiles={d} directories={d}\n", .{ try fs.readFile("nested/message.txt"), fs.stats().files, fs.stats().directories });
    \\    try writer.interface.flush();
    \\}
    \\
;
