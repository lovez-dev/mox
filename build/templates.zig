//! Discover source templates and attach immutable inputs to the build graph.
const std = @import("std");

pub const Entry = struct { path: []const u8, model: []const u8 };
pub const Options = struct {
    directory: std.Build.LazyPath,
    models: *std.Build.Module,
    mox: *std.Build.Module,
    entries: []const Entry,
};

pub fn add(b: *std.Build, options: Options) *std.Build.Module {
    return generate(b, options) catch |err| std.process.fatal("cannot compile templates from {f}: {t}", .{ options.directory, err });
}

fn generate(b: *std.Build, options: Options) !*std.Build.Module {
    const gpa = b.allocator;
    const source: std.Build.Cache.Path = switch (options.directory) {
        .src_path => |p| try p.owner.root.join(gpa, p.sub_path),
        .dependency => |p| try p.dependency.builder.root.join(gpa, p.sub_path),
        .cwd_relative => |p| .initCwd(p),
        .relative => |p| switch (p.base) {
            .cwd => .initCwd(p.sub_path),
            else => return error.UnsupportedDirectoryPath,
        },
        .generated => return error.GeneratedTemplateDirectoriesUnsupported,
    };
    const root = try source.root_dir.handle.openDir(b.graph.io, if (source.sub_path.len == 0) "." else source.sub_path, .{ .iterate = true, .follow_symlinks = false });
    defer root.close(b.graph.io);
    var paths: std.ArrayList([]const u8) = .empty;
    var count: usize = 0;
    try discover(b, options.directory, root, "", &paths, &count, 0);
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn less(_: void, a: []const u8, c: []const u8) bool {
            return std.mem.lessThan(u8, a, c);
        }
    }.less);
    const files = b.addWriteFiles();
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(gpa, "const t = @import(\"mox\").template;\nconst models = @import(\"models\");\nconst Views = t.Bundle(&.{\n");
    for (paths.items) |path| {
        const copied = b.fmt("views/{s}", .{path});
        _ = files.addCopyFile(options.directory.path(b, path), copied);
        try text.appendSlice(gpa, try std.fmt.allocPrint(gpa, ".{{ .path = \"{f}\", .text = @embedFile(\"{f}\") }},\n", .{ std.zig.fmtString(path), std.zig.fmtString(copied) }));
    }
    try text.appendSlice(gpa, "}, &.{\n");
    if (options.entries.len > 1024) return error.TooManyEntries;
    for (options.entries) |entry| {
        try text.appendSlice(gpa, try std.fmt.allocPrint(gpa, ".{{ .path = \"{f}\", .Model = @field(models, \"{f}\") }},\n", .{ std.zig.fmtString(entry.path), std.zig.fmtString(entry.model) }));
    }
    try text.appendSlice(gpa, "});\ncomptime { _ = Views; }\npub const get = Views.get;\n");
    const module = b.createModule(.{ .root_source_file = files.add("views.zig", text.items) });
    module.addImport("mox", options.mox);
    module.addImport("models", options.models);
    return module;
}

fn discover(b: *std.Build, directory: std.Build.LazyPath, dir: std.Io.Dir, prefix: []const u8, paths: *std.ArrayList([]const u8), count: *usize, depth: usize) !void {
    if (depth > 32) return error.DirectoryDepthExceeded;
    b.dependOnDirectoryContents(if (prefix.len == 0) directory else directory.path(b, prefix));
    var iterator = dir.iterate();
    while (try iterator.next(b.graph.io)) |item| {
        count.* += 1;
        if (count.* > 4096) return error.TooManyDirectoryEntries;
        const kind = if (item.kind == .unknown) (try dir.statFile(b.graph.io, item.name, .{ .follow_symlinks = false })).kind else item.kind;
        const path = if (prefix.len == 0) b.dupe(item.name) else b.fmt("{s}/{s}", .{ prefix, item.name });
        if (std.mem.indexOfAny(u8, item.name, "\\:\x00\r\n") != null) return error.InvalidTemplatePath;
        switch (kind) {
            .directory => {
                const child = try dir.openDir(b.graph.io, item.name, .{ .iterate = true, .follow_symlinks = false });
                defer child.close(b.graph.io);
                try discover(b, directory, child, path, paths, count, depth + 1);
            },
            .file => {
                if (std.mem.endsWith(u8, item.name, ".html")) {
                    if (paths.items.len == 1024) return error.TooManyTemplates;
                    try paths.append(b.allocator, path);
                }
            },
            else => return error.TemplateFilesystemLinksUnsupported,
        }
    }
}
