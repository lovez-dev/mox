//! Build graph integration for embedded directory images.

const std = @import("std");

pub const Options = struct {
    directory: std.Build.LazyPath,
    max_bytes: u64 = 4 * 1024 * 1024 * 1024,
    max_entries: u32 = 1_000_000,
};

pub fn addModule(b: *std.Build, tool: *std.Build.Step.Compile, options: Options) *std.Build.Module {
    const run = b.addRunArtifact(tool);
    run.addDirectoryArg(options.directory);
    trackTree(b, run, options) catch |err| std.process.fatal("cannot embed {f}: {t}", .{ options.directory, err });
    run.addArgs(&.{ "--max-bytes", b.fmt("{d}", .{options.max_bytes}), "--max-entries", b.fmt("{d}", .{options.max_entries}), "--module" });
    const output = run.addOutputDirectoryArg("embedded");
    return b.createModule(.{ .root_source_file = output.path(b, "root.zig") });
}

const Entry = struct { name: []const u8, directory: bool };

const Frame = struct { dir: std.Io.Dir, iterator: std.Io.Dir.Iterator, prefix: []const u8, owned: bool };

fn trackTree(b: *std.Build, run: *std.Build.Step.Run, options: Options) !void {
    const io = b.graph.io;
    const allocator = b.allocator;
    // Generated directories are immutable outputs, identified by their producer's cache key.
    const source: std.Build.Cache.Path = switch (options.directory) {
        .generated => return,
        .src_path => |p| try p.owner.root.join(allocator, p.sub_path),
        .dependency => |p| try p.dependency.builder.root.join(allocator, p.sub_path),
        .cwd_relative => |p| .initCwd(p),
        .relative => |p| switch (p.base) {
            .cwd => .initCwd(p.sub_path),
            else => return error.UnsupportedDirectoryPath,
        },
    };
    b.dependOnDirectoryContents(options.directory);
    const root = try source.root_dir.handle.openDir(io, if (source.sub_path.len == 0) "." else source.sub_path, .{ .iterate = true, .follow_symlinks = false });
    defer root.close(io);
    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |entry| allocator.free(entry.name);
        entries.deinit(allocator);
    }
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
        if (entries.items.len >= options.max_entries) return error.TooManyEntries;
        const kind = if (item.kind == .unknown) (try frame.dir.statFile(io, item.name, .{ .follow_symlinks = false })).kind else item.kind;
        if (kind != .file and kind != .directory) return error.UnsupportedFileType;
        const name = if (frame.prefix.len == 0)
            try allocator.dupe(u8, item.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ frame.prefix, item.name });
        entries.append(allocator, .{ .name = name, .directory = kind == .directory }) catch |err| {
            allocator.free(name);
            return err;
        };
        if (kind == .directory) {
            // Directory membership invalidates configuration, including empty directories.
            b.dependOnDirectoryContents(options.directory.path(b, name));
            const child = try frame.dir.openDir(io, item.name, .{ .iterate = true, .follow_symlinks = false });
            stack.append(allocator, .{ .dir = child, .iterator = child.iterate(), .prefix = name, .owned = true }) catch |err| {
                child.close(io);
                return err;
            };
        }
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, left: Entry, right: Entry) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    var manifest: std.ArrayList(u8) = .empty;
    defer manifest.deinit(allocator);
    for (entries.items) |entry| {
        if (!entry.directory) run.addFileInput(options.directory.path(b, entry.name));
        try manifest.append(allocator, if (entry.directory) 'd' else 'f');
        try manifest.appendSlice(allocator, entry.name);
        try manifest.append(allocator, 0);
    }
    // Content changes track files directly; topology changes alter this small cache input.
    run.addFileInput(b.addWriteFiles().add("mox-io-embed-tree", manifest.items));
}
