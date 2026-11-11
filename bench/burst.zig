//! 环管理尺子：一次灌入大量并发操作，测「批量提交/收割」的效率。
//!
//! 现有 `bench/echo.zig` 是单连接串行往返，每轮只有 1 个在飞操作——那种
//! 负载下 SQ/CQ 环永远只有一两条，测不出环管理改动的任何收益。这个尺子
//! 一次性把 N 个操作压进环里，让 `getSqe` / `reapCq` / `waitBatch` 的
//! 批量路径真正被走到。
//!
//! 用法：`zig build bench-burst -Dops=<操作数>`（默认 20000）。

const std = @import("std");
const io = @import("mox_io");

const platform = io.platform;
const Loop = io.Loop;
const Completion = io.Completion;
const Handle = io.Handle;

/// 完成计数。尺子只测吞吐，用全局量最省事——反推父结构在切片场景下
/// 容易出错（`@fieldParentPtr` 要的是切片整体，不是元素）。
var done: usize = 0;
var target: usize = 0;

fn onDone(l: *Loop, c: *Completion) void {
    _ = c;
    done += 1;
    if (done >= target) l.stop();
}

pub fn main() !void {
    // 0.17 没有 GeneralPurposeAllocator；尺子只关心吞吐，用 page_allocator。
    const gpa = std.heap.page_allocator;

    const ops: usize = @import("build_options").ops;

    var loop = try io.open(gpa);
    defer loop.deinit();

    // 这个尺子测的是 io_uring 的环管理：`readFileAsync` 只有 Linux 的
    // io_uring 后端提供，其它平台是 `null`。直接退出而不是报错，方便在
    // Windows / macOS 上 `zig build bench-burst` 不炸。
    if (loop.io.vtable.readFileAsync == null) {
        std.debug.print("bench-burst 需要 io_uring（readFileAsync 不可用），本平台跳过\n", .{});
        return;
    }

    // 准备一个文件当读源。
    const tmp_path = "/tmp/mox_bench_burst.dat";
    try loop.writeFileAll(tmp_path, "0123456789abcdef0123456789abcdef");

    var zpath_buf: [256]u8 = undefined;
    @memcpy(zpath_buf[0..tmp_path.len], tmp_path);
    zpath_buf[tmp_path.len] = 0;
    const zpath: [:0]const u8 = zpath_buf[0..tmp_path.len :0];

    const nodes = try gpa.alloc(io.ReadFileAsync, ops);
    defer gpa.free(nodes);
    const bufs = try gpa.alloc([]u8, ops);
    defer gpa.free(bufs);
    for (bufs) |*b| b.* = try gpa.alloc(u8, 64);
    defer for (bufs) |b| gpa.free(b);

    for (nodes, 0..) |*n, i| {
        n.* = io.ReadFileAsync.init(zpath, bufs[i]);
    }

    target = ops;

    const start = platform.tickCount();
    for (nodes) |*n| {
        n.c.callback = onDone;
        loop.add(&n.c);
    }
    try loop.run();

    const elapsed = platform.tickCount() - start;

    const us: u64 = if (elapsed == 0) 0 else @intCast(elapsed * 1000);
    std.debug.print(
        "mox_io burst: {d} ops / {d} ms = {d} ops/s, {d} ns/op (done={d})\n",
        .{
            ops,
            elapsed,
            if (elapsed != 0) ops * 1000 / @as(usize, @intCast(elapsed)) else 0,
            if (ops != 0) us * 1000 / ops else 0,
            done,
        },
    );
}
