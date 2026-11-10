const std = @import("std");

/// mox_io vs zio.ev 的同构性能对照。
///
/// 三个依赖互不污染主包：`mox` 是本地上级目录（path 依赖，永远测工作树代码），
/// `oktest` 与 `zio` 钉死到具体 commit。这里与 mox 主 `build.zig` 完全独立，
/// 因此 `bench/` 不在主包 `.paths` 里，外部消费者 `zig fetch` 不会拉到它们。
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // 基准必须优化编译，否则数字没有意义；不听从外部 -Doptimize。
    const compare_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .fast,
        .imports = &.{
            .{ .name = "mox_io", .module = b.dependency("mox", .{}).module("mox_io") },
            .{ .name = "oktest", .module = b.dependency("oktest", .{}).module("oktest") },
            .{ .name = "zio", .module = b.dependency("zio", .{}).module("zio") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "mox-compare",
        .root_module = compare_mod,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.has_side_effects = true;
    const step = b.step("compare", "运行 mox_io / zio.ev 性能对照");
    step.dependOn(&run.step);
}
