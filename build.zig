const std = @import("std");

/// 供外部消费者在 `build.zig` 里调用：把若干目录编译期嵌入成 VFS 模块。
///
///     const mox_build = std.Build.lazyImport(b, @This(), "mox") orelse
///         @panic("mox 依赖未就绪");
///     const embed = mox_build.addEmbed(b, .{ .dirs = &.{
///         .{ .dir = "assets", .mount = "/assets" },
///     } });
///     exe.step.dependOn(embed.step);
///     exe.root_module.addImport("mox_vfs", embed.module);
///
/// 生成模块导出 `mount(&loop)`、`get(path)`、`files`、`git_rev` 等；
/// 具体契约见 `src/embed.build.zig`。实现放在 `src/` 下是因为只有
/// `build.zig.zon` 的 `.paths` 里的文件才会随包分发给外部消费者。
pub const embed = @import("src/embed.build.zig");

pub fn addEmbed(b: *std.Build, opts: embed.Options) embed.Generated {
    return embed.add(b, opts);
}

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
        .root_source_file = b.path("src/mox_io/mox_io.zig"),
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

    // 强制 epoll 跑同一套契约测试，防止默认 io_uring 掩盖回落路径的问题。
    if (target.result.os.tag == .linux) {
        const epoll_step = b.step("test-epoll", "Run Web and I/O tests with epoll forced (Linux)");
        const epoll_io = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/mox_io/tests_epoll.zig"),
            .target = target,
            .optimize = optimize,
        }) });
        const epoll_web_module = b.createModule(.{
            .root_source_file = b.path("src/tests_epoll.zig"),
            .target = target,
            .optimize = optimize,
        });
        epoll_web_module.addImport("mox_io", mox_io);
        const epoll_web = b.addTest(.{ .root_module = epoll_web_module });
        epoll_step.dependOn(&b.addRunArtifact(epoll_io).step);
        epoll_step.dependOn(&b.addRunArtifact(epoll_web).step);
    }

    // 性能基线：`zig build bench -Drounds=<往返次数>`。
    const bench_options = b.addOptions();
    bench_options.addOption(usize, "rounds", b.option(usize, "rounds", "TCP echo 往返次数") orelse 2000);
    bench_options.addOption(usize, "conns", b.option(usize, "conns", "并发连接数") orelse 16);
    bench_options.addOption(usize, "ops", b.option(usize, "ops", "burst 尺子一次灌入的操作数") orelse 20000);
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

    // 环管理尺子：一次灌入大量操作，让 SQ/CQ 环的批量路径真正被走到。
    // `bench/echo.zig` 是单连接串行往返，每轮只有 1 个在飞操作，测不出
    // 环管理改动的任何收益——必须有这个尺子才有对比基线。
    const burst = b.addExecutable(.{
        .name = "bench-burst",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/burst.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    burst.root_module.addImport("mox_io", mox_io);
    burst.root_module.addOptions("build_options", bench_options);
    const run_burst = b.addRunArtifact(burst);
    b.step("bench-burst", "运行环管理批量吞吐尺子").dependOn(&run_burst.step);

    // 真包依赖验证：在 examples/consumer 里通过 `b.dependency("mox")` 编译。
    const pkg_build = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    pkg_build.setCwd(b.path("examples/consumer"));
    b.step("test-package", "验证外部消费者可通过包管理器依赖 mox").dependOn(&pkg_build.step);
}
