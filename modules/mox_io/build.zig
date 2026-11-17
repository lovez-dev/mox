//! Library exports, embed tooling, examples and verification targets.

const std = @import("std");
const embed_build = @import("build/embed.zig");

pub const EmbedOptions = embed_build.Options;

/// Import this build.zig as a dependency and attach the result with addImport.
pub fn embed(b: *std.Build, options: EmbedOptions) *std.Build.Module {
    const dependency = b.dependencyFromBuildZig(@This(), .{});
    return embed_build.addModule(b, dependency.artifact("mox-io-embed"), options);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    b.default_step = b.step("check-library", "Compile the library API without running tests");
    const thread = b.option(bool, "sanitize-thread", "Use Zig's ThreadSanitizer for tests and stress") orelse false;
    const filter = b.option([]const u8, "test-filter", "Run tests whose names contain this string");
    const soak_seconds = b.option(u32, "soak-seconds", "Duration of each long-running scenario") orelse 60;
    const library = b.addModule("mox_io", .{
        .root_source_file = b.path("src/mox_io.zig"),
        .target = target,
        .optimize = optimize,
        .valgrind = false,
    });
    linkSystem(library, target.result.os.tag);

    // Build-time tools always execute on the host, including cross builds.
    const host_library = b.createModule(.{
        .root_source_file = b.path("src/mox_io.zig"),
        .target = b.graph.host,
        .optimize = .safe,
        .valgrind = false,
    });
    const embed_tool = b.addExecutable(.{
        .name = "mox-io-embed",
        .root_module = rootModule(b, "tools/embed.zig", host_library, b.graph.host, .safe, false),
    });
    b.installArtifact(embed_tool);
    const run_embed = b.addRunArtifact(embed_tool);
    run_embed.addPassthruArgs();
    run_embed.setCwd(b.path("."));
    b.step("embed", "Pack a directory into an embedded filesystem image").dependOn(&run_embed.step);
    const test_assets = embed_build.addModule(b, embed_tool, .{ .directory = b.path("tests/fs/assets") });

    const build_test_paths = b.addOptions();
    build_test_paths.addOptionPath("embed_executable", embed_tool.getEmittedBin());
    build_test_paths.addOptionPathUntracked("zig_executable", .zig_exe);
    build_test_paths.addOptionPathUntracked("project_root", b.path("."));
    build_test_paths.addOptionPathUntracked("cache_root", .cache_root);
    const build_test_root = rootModule(b, "tests/build.zig", host_library, b.graph.host, .debug, false);
    build_test_root.addOptions("build-test-paths", build_test_paths);
    const build_tests = b.addTest(.{ .name = "mox-io-build-tests", .root_module = build_test_root });
    const run_build_tests = b.addRunArtifact(build_tests);
    run_build_tests.setCwd(b.path("."));
    run_build_tests.has_side_effects = true;
    b.step("test-build", "Test the embed command and downstream build caching").dependOn(&run_build_tests.step);

    if (thread and (target.result.os.tag != .linux or target.result.cpu.arch != .x86_64 or
        @import("builtin").os.tag != .linux or @import("builtin").cpu.arch != .x86_64))
    {
        const fail = b.addFail("ThreadSanitizer tests require native Linux x86_64");
        b.step("test", "Run tests").dependOn(&fail.step);
        b.step("stress", "Run bounded stress tests").dependOn(&fail.step);
        b.step("soak", "Run timed lifecycle and application scenarios after stress").dependOn(&fail.step);
        b.default_step.dependOn(&fail.step);
        return;
    }

    // Test instrumentation never changes the exported module's build settings.
    const test_library = if (thread) b.createModule(.{
        .root_source_file = b.path("src/mox_io.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = true,
        .valgrind = false,
    }) else library;
    if (thread) linkSystem(test_library, target.result.os.tag);

    const test_root = rootModule(b, "tests/root.zig", test_library, target, optimize, thread);
    test_root.addImport("test-assets", test_assets);
    const tests = b.addTest(.{
        .name = "mox-io-tests",
        .root_module = test_root,
        .filters = if (filter) |value| &.{value} else &.{},
        .use_llvm = if (thread) true else null,
    });
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(b.path("."));
    run_tests.has_side_effects = true;
    if (thread) run_tests.setEnvironmentVariable("TSAN_OPTIONS", "halt_on_error=1");
    b.step("test", "Run tests").dependOn(&run_tests.step);

    const stress = b.addTest(.{
        .name = "mox-io-stress",
        .root_module = rootModule(b, "tests/stress.zig", test_library, target, optimize, thread),
        .use_llvm = if (thread) true else null,
    });
    const run_stress = b.addRunArtifact(stress);
    run_stress.setCwd(b.path("."));
    run_stress.has_side_effects = true;
    if (thread) run_stress.setEnvironmentVariable("TSAN_OPTIONS", "halt_on_error=1");
    // Both suites use file fixtures, so retire one suite before starting the next.
    run_stress.step.dependOn(&run_tests.step);
    b.step("stress", "Run bounded stress tests").dependOn(&run_stress.step);

    const soak_options = b.addOptions();
    soak_options.addOption(u32, "seconds", soak_seconds);
    const soak_root = rootModule(b, "tests/soak.zig", test_library, target, optimize, thread);
    soak_root.addOptions("soak-options", soak_options);
    const soak = b.addTest(.{
        .name = "mox-io-soak",
        .root_module = soak_root,
        .filters = if (filter) |value| &.{value} else &.{},
        .use_llvm = if (thread) true else null,
    });
    const run_soak = b.addRunArtifact(soak);
    run_soak.setCwd(b.path("."));
    run_soak.has_side_effects = true;
    if (thread) run_soak.setEnvironmentVariable("TSAN_OPTIONS", "halt_on_error=1");
    run_soak.step.dependOn(&run_stress.step);
    b.step("soak", "Run timed lifecycle and application scenarios after stress").dependOn(&run_soak.step);

    const check = b.step("check", "Check formatting and compile all roots without linking");
    const fmt = b.addFmt(.{
        .paths = &.{ b.path("build.zig"), b.path("build.zig.zon"), b.path("src"), b.path("tests"), b.path("examples"), b.path("bench"), b.path("build"), b.path("tools") },
        .check = true,
    });
    check.dependOn(&fmt.step);
    check.dependOn(&embed_tool.step);
    const check_build_tests = b.addTest(.{ .name = "check-build-tests", .root_module = build_test_root, .emit_object = true });
    check.dependOn(&check_build_tests.step);
    for ([_][]const u8{ "tests/root.zig", "tests/stress.zig", "tests/soak.zig" }) |source| {
        const object_root = rootModule(b, source, library, target, optimize, false);
        if (std.mem.eql(u8, source, "tests/root.zig")) object_root.addImport("test-assets", test_assets);
        if (std.mem.eql(u8, source, "tests/soak.zig")) object_root.addOptions("soak-options", soak_options);
        const object = b.addTest(.{
            .name = if (std.mem.eql(u8, source, "tests/root.zig")) "check-tests" else if (std.mem.eql(u8, source, "tests/stress.zig")) "check-stress" else "check-soak",
            .root_module = object_root,
            .emit_object = true,
        });
        check.dependOn(&object.step);
        if (std.mem.eql(u8, source, "tests/root.zig")) b.default_step.dependOn(&object.step);
    }

    const fixtures = b.addWriteFiles();
    _ = fixtures.add("out/.keep", "");
    const examples = b.step("examples", "Run file, TCP and inbox examples");
    const runtime_bench = b.addExecutable(.{
        .name = "mox-io-runtime-bench",
        .root_module = rootModule(b, "bench/runtime.zig", library, target, optimize, false),
    });
    const install_runtime_bench = b.addInstallArtifact(runtime_bench, .{});
    b.step("runtime-bench-build", "Install the parallel Runtime benchmark").dependOn(&install_runtime_bench.step);
    const runtime_bench_object = b.addObject(.{ .name = "check-runtime-bench", .root_module = runtime_bench.root_module });
    check.dependOn(&runtime_bench_object.step);
    // Standard-entry consumer programs exercise ordinary downstream usage.
    for ([_][]const u8{ "framed_service", "pipeline", "runtime" }) |name| {
        const program = b.addExecutable(.{
            .name = b.fmt("mox-io-{s}", .{name}),
            .root_module = rootModule(b, b.fmt("examples/{s}.zig", .{name}), library, target, optimize, false),
        });
        const install = b.addInstallArtifact(program, .{});
        b.step(b.fmt("{s}-build", .{name}), b.fmt("Install {s} consumer example", .{name})).dependOn(&install.step);
        const run = b.addRunArtifact(program);
        run.addPassthruArgs();
        b.step(name, b.fmt("Run {s} consumer example", .{name})).dependOn(&run.step);
        const object = b.addObject(.{ .name = b.fmt("check-{s}", .{name}), .root_module = program.root_module });
        check.dependOn(&object.step);
    }

    const programs = [_]struct { name: []const u8, source: []const u8 }{
        .{ .name = "file", .source = "examples/file.zig" },
        .{ .name = "tcp", .source = "examples/tcp.zig" },
        .{ .name = "inbox", .source = "examples/inbox.zig" },
        .{ .name = "bench", .source = "bench/main.zig" },
    };
    for (programs) |program| {
        const module = rootModule(b, program.source, library, target, optimize, false);
        // These examples use the optional entry and memory helpers.
        module.sanitize_c = .trap;
        module.stack_check = false;
        module.stack_protector = false;
        module.valgrind = false;
        const object = b.addObject(.{ .name = b.fmt("check-{s}", .{program.name}), .root_module = module });
        check.dependOn(&object.step);
        const exe = b.addExecutable(.{ .name = b.fmt("mox-io-{s}", .{program.name}), .root_module = module });
        exe.bundle_compiler_rt = false;
        exe.bundle_ubsan_rt = false;
        if (target.result.os.tag == .windows) exe.entry = .{ .symbol_name = "mox_io_start" };
        const run = b.addRunArtifact(exe);
        run.has_side_effects = true;
        if (std.mem.eql(u8, program.name, "bench")) {
            run.setCwd(b.path("."));
            const csv = run.captureStdOut(.{});
            const save_csv = b.addUpdateSourceFiles();
            save_csv.addCopyFileToSource(csv, "out/bench/benchmark.csv");
            b.step("bench", "Run the benchmark and write out/bench/benchmark.csv").dependOn(&save_csv.step);
            const install = b.addInstallArtifact(exe, .{});
            b.step("bench-build", "Install the benchmark executable without running it").dependOn(&install.step);
        } else {
            run.setCwd(fixtures.getDirectory());
            examples.dependOn(&run.step);
        }
    }
}

fn rootModule(b: *std.Build, source: []const u8, library: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, thread: bool) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(source),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = thread,
        .imports = &.{.{ .name = "mox_io", .module = library }},
    });
    if (std.mem.eql(u8, source, "tests/root.zig")) module.addImport("mox_io_pack", b.createModule(.{
        .root_source_file = b.path("tools/pack.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = thread,
        .imports = &.{.{ .name = "mox_io", .module = library }},
    }));
    return module;
}

fn linkSystem(module: *std.Build.Module, os: std.Target.Os.Tag) void {
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
