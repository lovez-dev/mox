//! A downstream package imports the library and its embed build helper.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dependency = b.dependency("mox", .{ .target = target, .optimize = optimize });
    const assets = @import("mox").embed(b, .{ .directory = b.path("assets") });
    const executable = b.addExecutable(.{
        .name = "mox-consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    executable.root_module.addImport("mox", dependency.module("mox"));
    executable.root_module.addImport("assets", assets);
    const models = b.createModule(.{ .root_source_file = b.path("src/models.zig"), .target = target, .optimize = optimize });
    models.addImport("mox", dependency.module("mox"));
    const views = @import("mox").templates(b, .{
        .directory = b.path("views"),
        .models = models,
        .mox = dependency.module("mox"),
        .entries = &.{.{ .path = "page.html", .model = "Page" }},
    });
    executable.root_module.addImport("views", views);
    b.installArtifact(executable);
    b.step("run", "Verify the downstream library and generated asset module").dependOn(&b.addRunArtifact(executable).step);
}
