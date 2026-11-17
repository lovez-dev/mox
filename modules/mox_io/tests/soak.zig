//! Timed lifecycle tests with backend, scenario and iteration diagnostics.

const std = @import("std");
const mox_io = @import("mox_io");
const seconds = @import("soak-options").seconds;

const HandleSnapshot = struct { tracked: usize, total: usize };

fn handles(comptime runtime: bool) !HandleSnapshot {
    if (@import("builtin").os.tag == .linux) {
        var directory = try std.Io.Dir.cwd().openDir(std.testing.io, "/proc/self/fd", .{ .iterate = true });
        defer directory.close(std.testing.io);
        var iterator = directory.iterate();
        var count: usize = 0;
        while (try iterator.next(std.testing.io)) |_| count += 1;
        return .{ .tracked = count, .total = count };
    }
    if (@import("builtin").os.tag == .windows) {
        if (runtime) {
            const snapshot = try @import("support/windows_handles.zig").snapshot();
            return .{ .tracked = snapshot.total - snapshot.events, .total = snapshot.total };
        }

        const Win = struct {
            extern "kernel32" fn GetCurrentProcess() callconv(.winapi) *anyopaque;
            extern "kernel32" fn GetProcessHandleCount(*anyopaque, *u32) callconv(.winapi) i32;
        };
        var count: u32 = 0;
        if (Win.GetProcessHandleCount(Win.GetCurrentProcess(), &count) == 0) return error.HandleCountFailed;
        return .{ .tracked = count, .total = count };
    }
    return .{ .tracked = 0, .total = 0 };
}

fn repeat(comptime Backend: type, comptime scenario: enum { inbox, network, service, pipeline, runtime }) !void {
    if (@import("builtin").os.tag == .linux and Backend == mox_io.backends.Uring)
        if (!try Backend.probe()) return error.SkipZigTest;
    const stop = mox_io.os.now() + @as(u64, seconds) * 1_000_000_000;
    var iteration: usize = 0;
    var baseline_handles: ?usize = null;
    var total_peak: usize = 0;
    while (iteration == 0 or mox_io.os.now() < stop) : (iteration += 1) {
        const result = switch (scenario) {
            .inbox => @import("integration/native.zig").Suite(Backend).inbox(),
            .network => @import("stress.zig").networkRun(Backend, 8192, 512),
            .service => @import("integration/application.zig").Suite(Backend).tcpFrames(4096),
            .pipeline => @import("integration/application.zig").Suite(Backend).childPipe(),
            .runtime => @import("integration/runtime.zig").Suite(Backend).tcpRounds(512),
        };
        result catch |err| {
            std.debug.print("soak backend={s} scenario={s} iteration={d} error={s}\n", .{ @typeName(Backend), @tagName(scenario), iteration, @errorName(err) });
            return err;
        };
        const snapshot = try handles(scenario == .runtime);
        const current = snapshot.tracked;
        total_peak = @max(total_peak, snapshot.total);
        if (baseline_handles) |baseline| {
            if (current != baseline) {
                std.debug.print("soak handle leak backend={s} scenario={s} iteration={d} baseline={d} current={d}\n", .{ @typeName(Backend), @tagName(scenario), iteration, baseline, current });
                return error.NativeHandleLeak;
            }
        } else baseline_handles = current;
    }
    std.debug.print("soak backend={s} scenario={s} iterations={d} seconds={d} tracked_handles={d} total_handles_peak={d}\n", .{ @typeName(Backend), @tagName(scenario), iteration, seconds, baseline_handles orelse 0, total_peak });
}

test "soak application service" {
    try repeat(mox_io.DefaultBackend, .service);
}

test "soak Runtime TCP owners" {
    try repeat(mox_io.DefaultBackend, .runtime);
}

test "soak io_uring Runtime TCP owners" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    try repeat(mox_io.backends.Uring, .runtime);
}

test "soak application pipeline" {
    try repeat(mox_io.DefaultBackend, .pipeline);
}

test "soak io_uring application service" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    try repeat(mox_io.backends.Uring, .service);
}

test "soak io_uring application pipeline" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    try repeat(mox_io.backends.Uring, .pipeline);
}

test "soak native inbox" {
    try repeat(mox_io.DefaultBackend, .inbox);
}

test "soak native network" {
    try repeat(mox_io.DefaultBackend, .network);
}

test "soak io_uring inbox" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    try repeat(mox_io.backends.Uring, .inbox);
}

test "soak io_uring network" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    try repeat(mox_io.backends.Uring, .network);
}
