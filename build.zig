//! Library packaging, downstream embedding and verification targets.

const std = @import("std");
const io_embed = @import("modules/mox_io/build/embed.zig");

pub const EmbedOptions = io_embed.Options;
pub const TemplateOptions = @import("build/templates.zig").Options;

/// Compile application-controlled HTML with a concrete model for every entry.
pub fn templates(b: *std.Build, options: TemplateOptions) *std.Build.Module {
    return @import("build/templates.zig").add(b, options);
}

/// Attach this module to a consumer and read its image with EmbeddedFs.
pub fn embed(b: *std.Build, options: EmbedOptions) *std.Build.Module {
    const dependency = b.dependencyFromBuildZig(@This(), .{});
    return io_embed.addModule(dependency.builder, io_embed_tool(dependency.builder), options);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const io = b.addModule("mox_io", .{
        .root_source_file = b.path("modules/mox_io/src/mox_io.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkIoSystem(io, target.result.os.tag);
    const mox = b.addModule("mox", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mox.addImport("mox_io", io);

    const check = b.step("check", "Check formatting and compile the library, tests and examples");
    b.default_step = check;
    const fmt = b.addFmt(.{
        .paths = &.{ b.path("build.zig"), b.path("build.zig.zon"), b.path("build"), b.path("modules/mox_io"), b.path("src"), b.path("tests"), b.path("examples"), b.path("bench") },
        .check = true,
    });
    check.dependOn(&fmt.step);

    const unit_tests = b.addTest(.{ .name = "mox-tests", .root_module = mox });
    const io_tests = ioTestModule(b, io, target, optimize);
    const io_unit_tests = b.addTest(.{ .name = "mox-io-tests", .root_module = io_tests });
    const test_step = b.step("test", "Run protocol, framework and mox_io integration tests");
    const template_negative = b.step("test-template-errors", "Verify rejected template syntax, models and HTML contexts");
    @import("build/template_tests.zig").add(b, mox, target, optimize, template_negative);
    test_step.dependOn(template_negative);
    const run_unit = b.addRunArtifact(unit_tests);
    run_unit.has_side_effects = true;
    test_step.dependOn(&run_unit.step);
    const run_io_tests = b.addRunArtifact(io_unit_tests);
    run_io_tests.has_side_effects = true;
    run_io_tests.setCwd(b.path("."));
    test_step.dependOn(&run_io_tests.step);
    const io_test_object = b.addTest(.{ .name = "check-mox-io-tests", .root_module = io_tests, .emit_object = true });
    check.dependOn(&io_test_object.step);
    const unit_object = b.addTest(.{ .name = "check-mox-tests", .root_module = mox, .emit_object = true });
    check.dependOn(&unit_object.step);

    const test_options = b.addOptions();
    test_options.addOption([]const u8, "backend", b.option([]const u8, "backend", "Integration backend: default, epoll, uring, kqueue or iocp") orelse "default");
    const integration_module = consumerModule(b, "tests/integration.zig", mox, target, optimize);
    integration_module.addOptions("test_options", test_options);
    integration_module.addImport("mox_io", io);
    integration_module.addImport("lovez_io", io);
    const integration = b.addTest(.{ .name = "mox-integration", .root_module = integration_module });
    const run_integration = b.addRunArtifact(integration);
    run_integration.has_side_effects = true;
    run_integration.setCwd(b.path("."));
    run_integration.step.dependOn(&run_unit.step);
    test_step.dependOn(&run_integration.step);
    const integration_object = b.addTest(.{ .name = "check-integration", .root_module = integration_module, .emit_object = true });
    check.dependOn(&integration_object.step);

    const example = b.addExecutable(.{
        .name = "mox-example",
        .root_module = consumerModule(b, "examples/basic.zig", mox, target, optimize),
    });
    const example_install = b.addInstallArtifact(example, .{});
    b.step("example", "Build the example server").dependOn(&example_install.step);
    const run_example = b.addRunArtifact(example);
    run_example.setCwd(b.path("."));
    b.step("run", "Run the example server").dependOn(&run_example.step);
    const example_object = b.addObject(.{ .name = "check-example", .root_module = example.root_module });
    check.dependOn(&example_object.step);

    const view_models = consumerModule(b, "examples/view_models.zig", mox, target, optimize);
    const views = templates(b, .{
        .directory = b.path("examples/templates"),
        .models = view_models,
        .mox = mox,
        .entries = &.{.{ .path = "home.html", .model = "Home" }},
    });
    const template_example_module = consumerModule(b, "examples/templates.zig", mox, target, optimize);
    template_example_module.addImport("views", views);
    template_example_module.addImport("view_models", view_models);
    const template_example = b.addExecutable(.{ .name = "mox-templates", .root_module = template_example_module });
    b.step("example-templates", "Build the HTML template server").dependOn(&b.addInstallArtifact(template_example, .{}).step);
    check.dependOn(&b.addObject(.{ .name = "check-template-example", .root_module = template_example_module }).step);

    const board_module = consumerModule(b, "examples/board/main.zig", mox, target, optimize);
    const board = b.addExecutable(.{ .name = "mox-board", .root_module = board_module });
    b.step("example-board", "Build the in-memory task board").dependOn(&b.addInstallArtifact(board, .{}).step);
    const run_board = b.addRunArtifact(board);
    run_board.addPassthruArgs();
    b.step("run-board", "Run the task board on loopback; optional port argument").dependOn(&run_board.step);
    check.dependOn(&b.addObject(.{ .name = "check-board", .root_module = board_module }).step);
    const board_tests = b.addTest(.{ .name = "board-tests", .root_module = consumerModule(b, "examples/board/app.zig", mox, target, optimize) });
    check.dependOn(&b.addTest(.{ .name = "check-board-tests", .root_module = board_tests.root_module, .emit_object = true }).step);
    const run_board_tests = b.addRunArtifact(board_tests);
    run_board_tests.has_side_effects = true;
    test_step.dependOn(&run_board_tests.step);

    const autobahn = b.addExecutable(.{
        .name = "mox-autobahn",
        .root_module = consumerModule(b, "tests/autobahn/server.zig", mox, target, optimize),
    });
    const autobahn_install = b.addInstallArtifact(autobahn, .{});
    b.step("autobahn-server", "Build the WebSocket protocol test server").dependOn(&autobahn_install.step);
    const autobahn_object = b.addObject(.{ .name = "check-autobahn", .root_module = autobahn.root_module });
    check.dependOn(&autobahn_object.step);

    const zlap = b.dependency("zlap", .{ .target = target, .optimize = optimize }).module("zlap");
    const bench_module = consumerModule(b, "bench/http.zig", mox, target, optimize);
    bench_module.addImport("zlap", zlap);
    const benchmark = b.addExecutable(.{ .name = "mox-http-bench", .root_module = bench_module });
    const run_benchmark = b.addRunArtifact(benchmark);
    run_benchmark.has_side_effects = true;
    const results = run_benchmark.captureStdErr(.{});
    const save_results = b.addUpdateSourceFiles();
    save_results.addCopyFileToSource(results, "out/bench/http.txt");
    b.step("bench", "Run HTTP microbenchmarks; write results to out/bench/http.txt").dependOn(&save_results.step);
    const bench_object = b.addObject(.{ .name = "check-benchmark", .root_module = bench_module });
    check.dependOn(&bench_object.step);

    const template_bench_module = consumerModule(b, "bench/templates.zig", mox, target, optimize);
    template_bench_module.addImport("zlap", zlap);
    const template_bench = b.addExecutable(.{ .name = "mox-template-bench", .root_module = template_bench_module });
    const run_template_bench = b.addRunArtifact(template_bench);
    run_template_bench.has_side_effects = true;
    b.step("bench-templates", "Compare equal-output handwritten and compiled HTML rendering").dependOn(&run_template_bench.step);
    check.dependOn(&b.addObject(.{ .name = "check-template-benchmark", .root_module = template_bench_module }).step);

    const package = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "run", "--cache-dir", "../../.zig-cache/package", "--prefix", "../../zig-out/package" });
    package.setCwd(b.path("tests/package"));
    package.has_side_effects = true;
    b.step("test-package", "Build and run a downstream dependency and embedded assets").dependOn(&package.step);
}

fn ioTestModule(b: *std.Build, io: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const pack = b.createModule(.{
        .root_source_file = b.path("modules/mox_io/tools/pack.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "mox_io", .module = io }},
    });
    const module = b.createModule(.{
        .root_source_file = b.path("modules/mox_io/tests/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "mox_io", .module = io },
            .{ .name = "mox_io_pack", .module = pack },
        },
    });
    const assets = io_embed.addModule(b, io_embed_tool(b), .{ .directory = b.path("modules/mox_io/tests/fs/assets") });
    module.addImport("test-assets", assets);
    return module;
}

fn io_embed_tool(b: *std.Build) *std.Build.Step.Compile {
    const host_io = b.createModule(.{
        .root_source_file = b.path("modules/mox_io/src/mox_io.zig"),
        .target = b.graph.host,
        .optimize = .safe,
    });
    const tool = b.addExecutable(.{
        .name = "mox-io-embed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("modules/mox_io/tools/embed.zig"),
            .target = b.graph.host,
            .optimize = .safe,
            .imports = &.{.{ .name = "mox_io", .module = host_io }},
        }),
    });
    return tool;
}

fn linkIoSystem(module: *std.Build.Module, os: std.Target.Os.Tag) void {
    switch (os) {
        .windows => {
            module.linkSystemLibrary("kernel32", .{});
            module.linkSystemLibrary("ws2_32", .{});
            module.linkSystemLibrary("ntdll", .{});
        },
        .linux, .macos, .freebsd => {
            module.link_libc = true;
            module.linkSystemLibrary("pthread", .{});
        },
        else => {},
    }
}

fn consumerModule(b: *std.Build, source: []const u8, mox: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(source),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("mox", mox);
    return module;
}
