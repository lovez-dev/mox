const std = @import("std");

/// 外部消费者：通过 `zig` 包管理器依赖 mox，验证 `addModule` 暴露的模块
/// 能被 `b.dependency(...).module(...)` 正确拿到并编译。
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep = b.dependency("mox", .{ .target = target, .optimize = optimize });
    const mox = dep.module("mox");
    const mox_io = dep.module("mox_io");

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
    b.installArtifact(exe);
}
