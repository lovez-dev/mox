const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mox = b.addModule("mox", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // I/O 层是独立模块（`mox_io`），既可单独导入，
    // 也可供框架导入。
    const mox_io = b.addModule("mox_io", .{
        .root_source_file = b.path("src/io/io.zig"),
        .target = target,
        .optimize = optimize,
    });
    mox.addImport("mox_io", mox_io);

    // 一个极简示例服务器，用于端到端 HTTP 验证。
    const exe = b.addExecutable(.{
        .name = "example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/basic.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("mox", mox);
    b.installArtifact(exe);

    const test_step = b.step("test", "Run tests");

    const mod_tests = b.addTest(.{ .root_module = mox });
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);

    // 三个后端（IOCP / io_uring / kqueue）都已就绪，所有目标都跑 `mox_io` 测试。
    const io_tests = b.addTest(.{ .root_module = mox_io });
    test_step.dependOn(&b.addRunArtifact(io_tests).step);

    // 性能基线：`zig build bench -Drounds=<往返次数>`。
    const bench_options = b.addOptions();
    bench_options.addOption(usize, "rounds", b.option(usize, "rounds", "TCP echo 往返次数") orelse 2000);
    bench_options.addOption(usize, "conns", b.option(usize, "conns", "并发连接数") orelse 16);
    const bench = b.addExecutable(.{
        .name = "bench-echo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/echo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bench.root_module.addImport("mox_io", mox_io);
    bench.root_module.addOptions("build_options", bench_options);
    const run_bench = b.addRunArtifact(bench);
    b.step("bench", "运行 TCP echo 性能基线").dependOn(&run_bench.step);

    // 纯阻塞对照尺子：同一负载、不经完成循环。
    const blocking = b.addExecutable(.{
        .name = "bench-blocking",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/blocking.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    blocking.root_module.addImport("mox_io", mox_io);
    blocking.root_module.addOptions("build_options", bench_options);
    const run_blocking = b.addRunArtifact(blocking);
    b.step("bench-blocking", "运行纯阻塞 echo 对照尺子").dependOn(&run_blocking.step);

    // 多连接并发吞吐：`waitBatch` 的价值要靠每轮多个完成包才能体现。
    const concurrent = b.addExecutable(.{
        .name = "bench-concurrent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/concurrent.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    concurrent.root_module.addImport("mox_io", mox_io);
    concurrent.root_module.addOptions("build_options", bench_options);
    const run_concurrent = b.addRunArtifact(concurrent);
    b.step("bench-concurrent", "运行多连接并发吞吐尺子").dependOn(&run_concurrent.step);

    // 真包依赖验证：在 examples/consumer 里通过 `b.dependency("mox")` 编译。
    const pkg_build = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    pkg_build.setCwd(b.path("examples/consumer"));
    b.step("test-package", "验证外部消费者可通过包管理器依赖 mox").dependOn(&pkg_build.step);
}
