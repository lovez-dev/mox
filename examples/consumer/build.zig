const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("mox", .{ .target = target, .optimize = optimize });
    const mox = dep.module("mox");
    const mox_io = dep.module("mox_io");

    const mox_build = std.Build.lazyImport(b, @This(), "mox") orelse
        @panic("mox 依赖未就绪");
    const embed = mox_build.addEmbed(b, .{
        .dirs = &.{
            .{ .dir = "assets", .mount = "/assets" },
        },
        .git_rev = true,
    });

    const exe = b.addExecutable(.{
        .name = "consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("mox", mox);
    exe.root_module.addImport("mox_io", mox_io);
    exe.root_module.addImport("mox_vfs", embed.module);
    exe.step.dependOn(embed.step);
    b.installArtifact(exe);
}
