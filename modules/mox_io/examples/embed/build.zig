//! Attach directory assets through the public embed build helper.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dependency = b.dependency("mox_io", .{ .target = target, .optimize = optimize });
    const assets = @import("mox_io").embed(b, .{ .directory = b.path("assets") });

    const exe = b.addExecutable(.{
        .name = "embedded-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mox_io", .module = dependency.module("mox_io") },
                .{ .name = "assets", .module = assets },
            },
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    b.step("run", "Print a file embedded at build time").dependOn(&run.step);
}
