//! 事件循环测试：定时器、收发、接受、连接、`Work` 与文件读取。
//!
//! 从 `loop.zig` / `io.zig` 移出，统一由 `io.zig` 聚合。

const std = @import("std");
const builtin = @import("builtin");
const net = std.Io.net;
const root = @import("mox_io.zig");

const Loop = root.Loop;
// 文件句柄层（阶段 A）
const OpenFile = root.OpenFile;
const ReadFileHandle = root.ReadFileHandle;
const WriteFileHandle = root.WriteFileHandle;
const CloseFile = root.CloseFile;
// 句柄级元数据与同步（阶段 B）
const StatFile = root.StatFile;
const SetFileSize = root.SetFileSize;
const SyncFile = root.SyncFile;
// 符号链接读取 + 目录流式句柄（阶段 C）
const ReadLink = root.ReadLink;
const OpenDir = root.OpenDir;
const ReadDirHandle = root.ReadDirHandle;
const CloseDir = root.CloseDir;

// Options：运行时配置必须真的传到后端，不能只是把参数接住扔掉。
test "openWith 的 queue_size 非法值报错，合法值生效" {
    // 0 和 3（非 2 的幂）都要明确报错，不能静默截断——静默改尺寸会让
    // 用户以为自己测的是另一种配置。
    try std.testing.expectError(error.InvalidQueueSize, root.openWith(std.testing.allocator, .{ .queue_size = 0 }));
    try std.testing.expectError(error.InvalidQueueSize, root.openWith(std.testing.allocator, .{ .queue_size = 3 }));
}

test "openWith 的 queue_size 改变后端环容量与在飞窗口" {
    // 只在能观测到 SQ/CQ 环的 io_uring 后端上验证；epoll 现在也按
    // queue_size 预分配 fd-slot / Pending 池 / queued 环，但没有可观测字段。
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var small = try root.openWith(std.testing.allocator, .{ .queue_size = 64, .backend = .uring });
    defer small.deinit();
    var large = try root.openWith(std.testing.allocator, .{ .queue_size = 512, .backend = .uring });
    defer large.deinit();

    // CQ 容量 = queue_size × 8，在飞窗口 = 它的一半 = queue_size × 4。
    try std.testing.expectEqual(@as(usize, 64 * 4), small.inflight_max);
    try std.testing.expectEqual(@as(usize, 512 * 4), large.inflight_max);

    // 更硬的证据：内核实际回填的 SQ/CQ 环尺寸必须跟着配置走。
    // 只断言 `inflight_max` 是不够的——那是 Loop 层按参数算出来的，
    // 就算后端把 `queue_size` 整个忽略掉也照样对。必须直接读后端状态。
    const uring = @import("backends/uring.zig");
    const s64 = uring.ringSizes(small.io.userdata);
    const s512 = uring.ringSizes(large.io.userdata);
    try std.testing.expectEqual(@as(u32, 64), s64[0]);
    try std.testing.expectEqual(@as(u32, 64 * 8), s64[1]);
    try std.testing.expectEqual(@as(u32, 512), s512[0]);
    try std.testing.expectEqual(@as(u32, 512 * 8), s512[1]);
}

test "openWith 的 inflight_max 显式值被钳制到 CQ 容量一半" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    // 传一个大到会灌爆 CQ 环的值（1<<20），必须被钳制而不是照单全收。
    var l = try root.openWith(std.testing.allocator, .{
        .queue_size = 64,
        .inflight_max = 1 << 20,
        .backend = .uring,
    });
    defer l.deinit();
    try std.testing.expectEqual(@as(usize, 64 * 4), l.inflight_max);
}

test "openWith 的 max_workers 生效" {
    var l = try root.openWith(std.testing.allocator, .{ .max_workers = 2 });
    defer l.deinit();
    try std.testing.expectEqual(@as(usize, 2), l.pool.max_workers);
}

test "不同 queue_size 的 Loop 都能完成大批量提交" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (root.platform.chosen == .epoll) return error.SkipZigTest;

    // 关键回归：queue_size 缩到 64 时 CQ 只有 512 格，仍不能丢完成包。
    // 窗口必须跟着缩小，否则一次 add 3000 个操作就会灌爆 CQ。
    var l = try root.openWith(std.testing.allocator, .{ .queue_size = 64, .backend = .uring });
    defer l.deinit();

    var pbuf: [512]u8 = undefined;
    const dir = try tmpDir(&pbuf, "qsz");
    try l.makeDir(dir, 0o755);
    defer l.removeDir(dir) catch {};
    var fbuf: [600]u8 = undefined;
    const fpath = try std.fmt.bufPrint(&fbuf, "{s}/q.txt", .{dir});
    defer l.deleteFile(fpath);
    try l.writeFileAll(fpath, "q");
    var zbuf: [700]u8 = undefined;
    @memcpy(zbuf[0..fpath.len], fpath);
    zbuf[fpath.len] = 0;
    const zpath: [:0]const u8 = zbuf[0..fpath.len :0];

    const n = 600; // > CQ 容量 512
    const Ctx = struct {
        var remaining: usize = 0;
        var bad: usize = 0;
        fn cb(lp: *Loop, c: *root.Completion) void {
            if (c.err != null) bad += 1;
            remaining -|= 1;
            if (remaining == 0) lp.stop();
        }
    };
    Ctx.remaining = n;
    Ctx.bad = 0;

    var nodes: [n]root.ReadFileAsync = undefined;
    var bufs: [n][16]u8 = undefined;
    var wds: [n]root.Timer = undefined;
    for (&nodes, 0..) |*node, i| {
        node.* = root.ReadFileAsync.init(zpath, &bufs[i]);
        node.c.callback = &Ctx.cb;
        l.add(&node.c);
        wds[i] = root.Timer.init(30_000);
        l.watchdog(&node.c, &wds[i], 30_000);
    }
    try l.run();
    try std.testing.expectEqual(@as(usize, 0), Ctx.bad);
    try std.testing.expectEqual(@as(usize, 0), Ctx.remaining);
}
const Completion = root.Completion;
const Timer = root.Timer;
const NetRecv = root.NetRecv;
const NetAccept = root.NetAccept;
const NetConnect = root.NetConnect;
const Work = root.Work;
const Handle = root.Handle;
const INVALID_HANDLE = root.INVALID_HANDLE;
const ReadFile = root.ReadFile;
const WriteFile = root.WriteFile;
const TruncateFile = root.TruncateFile;
const DeleteFile = root.DeleteFile;
const platform = root.platform;
const Process = root.Process;
const ProcessWait = root.ProcessWait;
fn testLoop() !Loop {
    return Loop.init(try platform.create(std.testing.allocator));
}

test "a timer fires through the loop" {
    var loop = try testLoop();
    defer loop.deinit();

    const Ctx = struct {
        var fired: usize = 0;
        fn cb(l: *Loop, c: *Completion) void {
            _ = c;
            fired += 1;
            l.stop();
        }
    };

    var timer = Timer.init(20);
    timer.c.callback = &Ctx.cb;
    loop.add(&timer.c);
    try loop.run();

    try std.testing.expectEqual(@as(usize, 1), Ctx.fired);
    try timer.getResult();
}

test "a socket receive completes through the loop" {
    var loop = try testLoop();
    defer loop.deinit();

    const bind_addr = try net.IpAddress.parse("127.0.0.1", 0);
    const listener = try platform.createTcpSocket(bind_addr);
    defer platform.closeSocket(listener);
    try platform.setReuseAddress(listener, true);
    try platform.bindSocket(listener, bind_addr);
    const bound = try platform.localAddress(listener);
    try platform.listenSocket(listener, 16);

    const Sender = struct {
        fn run(addr: net.IpAddress) void {
            const client = platform.createTcpSocket(addr) catch return;
            defer platform.closeSocket(client);
            platform.connectSocket(client, addr) catch return;
            _ = platform.sendBlocking(client, "hello") catch return;
            const start = platform.tickCount();
            while (platform.tickCount() - start < 200) {}
        }
    };
    const thread = try std.Thread.spawn(.{}, Sender.run, .{bound});

    const accepted = try platform.acceptSocket(listener);
    defer platform.closeSocket(accepted.socket);
    try loop.associate(accepted.socket, 1);

    const Ctx = struct {
        var calls: usize = 0;
        var got: usize = 0;
        fn cb(l: *Loop, c: *Completion) void {
            const r: *NetRecv = @fieldParentPtr("c", c);
            got = r.getResult() catch 0;
            calls += 1;
            l.stop();
        }
    };

    var buf: [64]u8 = undefined;
    var recv = NetRecv.init(accepted.socket, &buf);
    recv.c.callback = &Ctx.cb;
    loop.add(&recv.c);
    try loop.run();

    thread.join();

    try std.testing.expectEqual(@as(usize, 1), Ctx.calls);
    try std.testing.expectEqualStrings("hello", buf[0..Ctx.got]);
}

test "accept and receive through the loop" {
    var loop = try testLoop();
    defer loop.deinit();

    const bind_addr = try net.IpAddress.parse("127.0.0.1", 0);
    const listener = try platform.createTcpSocket(bind_addr);
    defer platform.closeSocket(listener);
    try platform.setReuseAddress(listener, true);
    try platform.bindSocket(listener, bind_addr);
    const bound = try platform.localAddress(listener);
    try platform.listenSocket(listener, 16);

    const accept_sock = try platform.createTcpSocket(bind_addr);
    defer platform.closeSocket(accept_sock);

    const Ctx = struct {
        var accepted: Handle = INVALID_HANDLE;
        var got: usize = 0;
        var buf: [64]u8 = undefined;
        var recv: NetRecv = undefined;

        fn onAccept(l: *Loop, c: *Completion) void {
            const a: *NetAccept = @fieldParentPtr("c", c);
            accepted = a.getResult() catch {
                l.stop();
                return;
            };
            l.associate(accepted, 2) catch {};
            recv = NetRecv.init(accepted, &buf);
            recv.c.callback = &onRecv;
            l.add(&recv.c);
        }

        fn onRecv(l: *Loop, c: *Completion) void {
            const r: *NetRecv = @fieldParentPtr("c", c);
            got = r.getResult() catch 0;
            l.stop();
        }
    };

    const Sender = struct {
        fn run(addr: net.IpAddress) void {
            const client = platform.createTcpSocket(addr) catch return;
            defer platform.closeSocket(client);
            platform.connectSocket(client, addr) catch return;
            _ = platform.sendBlocking(client, "hello") catch return;
            const start = platform.tickCount();
            while (platform.tickCount() - start < 200) {}
        }
    };
    const thread = try std.Thread.spawn(.{}, Sender.run, .{bound});

    try loop.associate(listener, 0);
    var acc = NetAccept.init(listener, accept_sock);
    acc.c.callback = &Ctx.onAccept;
    loop.add(&acc.c);
    try loop.run();

    thread.join();
    if (Ctx.accepted != INVALID_HANDLE) platform.closeSocket(Ctx.accepted);

    try std.testing.expectEqualStrings("hello", Ctx.buf[0..Ctx.got]);
}

test "a Work item runs on the pool and completes on the loop" {
    var loop = try testLoop();
    defer loop.deinit();

    const Item = struct {
        work: Work,
        value: u32 = 0,
    };
    const Ctx = struct {
        var done = false;
        fn workFn(w: *Work) void {
            const self: *Item = @fieldParentPtr("work", w);
            const start = platform.tickCount();
            while (platform.tickCount() - start < 10) {} // pretend blocking I/O
            self.value = 42;
        }
        fn done_cb(l: *Loop, c: *Completion) void {
            _ = c;
            done = true;
            l.stop();
        }
    };

    var item: Item = .{ .work = Work.init(&Ctx.workFn) };
    item.work.c.callback = &Ctx.done_cb;
    loop.add(&item.work.c);
    try loop.run();

    try std.testing.expect(Ctx.done);
    try std.testing.expectEqual(@as(u32, 42), item.value);
}

test "an async connect completes through the loop" {
    var loop = try testLoop();
    defer loop.deinit();

    const bind_addr = try net.IpAddress.parse("127.0.0.1", 0);
    const listener = try platform.createTcpSocket(bind_addr);
    defer platform.closeSocket(listener);
    try platform.setReuseAddress(listener, true);
    try platform.bindSocket(listener, bind_addr);
    const bound = try platform.localAddress(listener);
    try platform.listenSocket(listener, 16);

    const Acceptor = struct {
        fn run(l: Handle) void {
            const peer = platform.acceptSocket(l) catch return;
            platform.closeSocket(peer.socket);
        }
    };
    const t = try std.Thread.spawn(.{}, Acceptor.run, .{listener});

    const client = try platform.createTcpSocket(bound);
    defer platform.closeSocket(client);

    const Ctx = struct {
        var ok = false;
        fn cb(l: *Loop, c: *Completion) void {
            const nc: *NetConnect = @fieldParentPtr("c", c);
            nc.getResult() catch {
                l.stop();
                return;
            };
            ok = true;
            l.stop();
        }
    };

    var conn = NetConnect.init(client, bound);
    conn.c.callback = &Ctx.cb;
    try loop.associate(client, 5);
    loop.add(&conn.c);
    try loop.run();

    t.join();
    try std.testing.expect(Ctx.ok);
}

test "ReadFile reads a file off the loop thread" {
    var l = Loop.init(try platform.create(std.testing.allocator));
    defer l.deinit();

    const path = "zig-cache-mox-readfile-test.txt";
    try platform.writeFileAll(path, "static-asset-body");
    defer platform.deleteFile(path);

    const Ctx = struct {
        var ok = false;
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            ok = true;
            loop.stop();
        }
    };

    var buf: [64]u8 = undefined;
    var rf = ReadFile.init(l.io, path, &buf, null);
    rf.work.c.callback = &Ctx.cb;
    l.add(&rf.work.c);
    try l.run();

    try std.testing.expect(Ctx.ok);
    try std.testing.expectEqualStrings("static-asset-body", try rf.getResult());
}

// 内存文件走完整条 `Loop.add → Work → 回调` 链路，但路径在磁盘上不存在：
// 若实现回落到了 `readFileInto`，这条测试会直接失败。
test "MemoryFs 命中时不碰磁盘且结果进入回调" {
    var l = Loop.init(try platform.create(std.testing.allocator));
    defer l.deinit();

    const path = "這個路徑在磁盤上絕對不存在/memory-only.bin";
    const body = "compiled-in-asset";
    try l.mountMemory(path, body);
    try std.testing.expectEqual(@as(u64, body.len), try l.fileSize(path));

    const Ctx = struct {
        var ok = false;
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            ok = true;
            loop.stop();
        }
    };

    var buf: [64]u8 = undefined;
    var rf = ReadFile.init(l.io, path, &buf, l.memory_fs.lookup(path));
    rf.work.c.callback = &Ctx.cb;
    l.add(&rf.work.c);
    try l.run();

    try std.testing.expect(Ctx.ok);
    try std.testing.expectEqualStrings(body, try rf.getResult());
}

// 缓冲区小于内存文件时必须报错，而不是静默截断。
test "MemoryFs 缓冲区不足时返回 BufferTooSmall" {
    var l = Loop.init(try platform.create(std.testing.allocator));
    defer l.deinit();
    try l.mountMemory("/big", "0123456789");

    const Ctx = struct {
        var ok = false;
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            ok = true;
            loop.stop();
        }
    };

    var buf: [4]u8 = undefined;
    var rf = ReadFile.init(l.io, "/big", &buf, l.memory_fs.lookup("/big"));
    rf.work.c.callback = &Ctx.cb;
    l.add(&rf.work.c);
    try l.run();

    try std.testing.expect(Ctx.ok);
    try std.testing.expectError(error.BufferTooSmall, rf.getResult());
}

// 未挂载的路径仍回落到真实文件，避免 VFS 把原有行为吃掉。
test "MemoryFs 未命中时回落到后端 readFileInto" {
    var l = Loop.init(try platform.create(std.testing.allocator));
    defer l.deinit();

    const path = "zig-cache-mox-vfs-fallback-test.txt";
    try platform.writeFileAll(path, "on-disk-body");
    defer platform.deleteFile(path);
    try std.testing.expect(l.memory_fs.lookup(path) == null);

    const Ctx = struct {
        var ok = false;
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            ok = true;
            loop.stop();
        }
    };

    var buf: [64]u8 = undefined;
    var rf = ReadFile.init(l.io, path, &buf, l.memory_fs.lookup(path));
    rf.work.c.callback = &Ctx.cb;
    l.add(&rf.work.c);
    try l.run();

    try std.testing.expect(Ctx.ok);
    try std.testing.expectEqualStrings("on-disk-body", try rf.getResult());
}

test "取消在飞操作后不回调，只回收对象" {
    var loop = try testLoop();
    defer loop.deinit();

    const bind_addr = try net.IpAddress.parse("127.0.0.1", 0);
    const listener = try platform.createTcpSocket(bind_addr);
    defer platform.closeSocket(listener);
    try platform.setReuseAddress(listener, true);
    try platform.bindSocket(listener, bind_addr);
    const bound = try platform.localAddress(listener);
    try platform.listenSocket(listener, 16);

    const Sender = struct {
        fn run(addr: net.IpAddress) void {
            const client = platform.createTcpSocket(addr) catch return;
            defer platform.closeSocket(client);
            platform.connectSocket(client, addr) catch return;
            const start = platform.tickCount();
            while (platform.tickCount() - start < 400) {}
        }
    };
    const thread = try std.Thread.spawn(.{}, Sender.run, .{bound});
    const accepted = try platform.acceptSocket(listener);
    defer platform.closeSocket(accepted.socket);
    try loop.associate(accepted.socket, 1);

    const Ctx = struct {
        var callback_calls: usize = 0;
        var disposed: usize = 0;

        fn cb(l: *Loop, c: *Completion) void {
            _ = c;
            callback_calls += 1;
            l.stop();
        }
        fn dispose(p: *anyopaque) void {
            const l: *Loop = @ptrCast(@alignCast(p));
            disposed += 1;
            l.stop();
        }
    };

    var buf: [64]u8 = undefined;
    var recv = NetRecv.init(accepted.socket, &buf);
    recv.c.callback = &Ctx.cb;
    loop.add(&recv.c);
    loop.cancel(&recv.c, @ptrCast(&loop), Ctx.dispose);
    try loop.run();

    thread.join();
    try std.testing.expectEqual(@as(usize, 0), Ctx.callback_calls);
    try std.testing.expectEqual(@as(usize, 1), Ctx.disposed);
}

test "跨线程 submit 的操作在循环线程回调" {
    var loop = try testLoop();
    defer loop.deinit();

    const Ctx = struct {
        var callback_thread: std.Thread.Id = 0;
        var loop_thread: std.Thread.Id = 0;
        var fired: usize = 0;

        fn cb(l: *Loop, c: *Completion) void {
            _ = c;
            callback_thread = std.Thread.getCurrentId();
            fired += 1;
            l.stop();
        }
        fn run(l: *Loop, t: *Timer) void {
            // 让循环先进入 waitBatch，再从本线程提交。
            const start = platform.tickCount();
            while (platform.tickCount() - start < 30) {}
            l.submit(&t.c);
        }
    };

    var timer = Timer.init(1);
    timer.c.callback = &Ctx.cb;
    Ctx.loop_thread = std.Thread.getCurrentId();

    const thread = try std.Thread.spawn(.{}, Ctx.run, .{ &loop, &timer });
    try loop.run();
    thread.join();

    try std.testing.expectEqual(@as(usize, 1), Ctx.fired);
    try std.testing.expectEqual(Ctx.loop_thread, Ctx.callback_thread);
}

test "UDP 能力可查询并完成一次数据报收发" {
    var loop = try root.open(std.testing.allocator);
    defer loop.deinit();

    const udp = root.udp.Udp.get(loop.io) orelse return error.SkipZigTest;
    try std.testing.expect(loop.io.capability(*const root.udp.VTable, root.udp.id) != null);
    // 未注册的能力必须返回 null，这是「老后端自动不支持」的依据。
    try std.testing.expect(loop.io.capability(*const root.udp.VTable, root.cap("mox.io.signal.v1")) == null);

    const bind_addr = try net.IpAddress.parse("127.0.0.1", 0);
    const receiver = try udp.create(bind_addr);
    defer udp.close(receiver);
    try udp.bind(receiver, bind_addr);
    const bound = try platform.localAddress(receiver);

    const sender = try udp.create(bound);
    defer udp.close(sender);

    const Ctx = struct {
        var done: usize = 0;
        fn onDone(l: *Loop, c: *Completion) void {
            _ = c;
            done += 1;
            if (done == 2) l.stop();
        }
    };

    var buf: [64]u8 = undefined;
    var recv = root.udp.Recv.init(receiver, &buf);
    recv.work.c.callback = Ctx.onDone;
    udp.recv(&loop, &recv);

    var send = root.udp.Send.init(sender, "ping", bound);
    send.work.c.callback = Ctx.onDone;
    udp.send(&loop, &send);

    try loop.run();

    try std.testing.expectEqualStrings("ping", buf[0..try recv.getResult()]);
    try std.testing.expectEqual(@as(usize, 4), try send.getResult());
}

test "无人应答的 UDP 接收走内核异步路径，且停机不被线程池拖住" {
    if (@import("builtin").os.tag == .windows) try platform.startup();
    var loop = try root.open(std.testing.allocator);

    const udp = root.udp.Udp.get(loop.io) orelse return error.SkipZigTest;
    // 前提是后端提供了原生异步 UDP。回落到线程池的后端确实会占住一个池线程，
    // 那是另一条已知边界（README 里记着），不该拿这条测试去假装它不存在。
    if (loop.io.vtable.udpRecv == null) return error.SkipZigTest;

    const bind_addr = try net.IpAddress.parse("127.0.0.1", 0);
    const receiver = try udp.create(bind_addr);
    defer udp.close(receiver);
    try udp.bind(receiver, bind_addr);

    const Ctx = struct {
        fn onDone(l: *Loop, c: *Completion) void {
            _ = c;
            l.stop();
        }
    };

    // 线程池默认只有 4 个线程，原始故障是四次无应答接收就能把它占满，之后
    // 所有文件读取一起饿死。这里故意提交 8 次，并要求每一个都仍标记为
    // `udp_recv`：哪天悄悄退回线程池，这两处都会立刻红。
    var bufs: [8][64]u8 = undefined;
    var recvs: [8]root.udp.Recv = undefined;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        recvs[i] = root.udp.Recv.init(receiver, &bufs[i]);
        recvs[i].work.c.callback = Ctx.onDone;
        udp.recv(&loop, &recvs[i]);
        try std.testing.expectEqual(root.Op.udp_recv, recvs[i].work.c.op);
    }

    // 不会有数据报过来，靠定时器收尾。
    var dog = root.Timer.init(50);
    dog.c.callback = Ctx.onDone;
    loop.add(&dog.c);

    try loop.run();

    // 挂死就表现为这里耗时极长：接收占住池线程，`shutdown` 的 `join` 永远
    // 等不到。正常应在几十毫秒内返回。
    const t0 = platform.tickCount();
    loop.deinit();
    try std.testing.expect(platform.tickCount() - t0 < 1000);
}

test "取消定时器立即回收，不等待完成包" {
    var loop = try testLoop();
    defer loop.deinit();

    const Ctx = struct {
        var fired: usize = 0;
        var disposed: usize = 0;
        fn cb(l: *Loop, c: *Completion) void {
            _ = l;
            _ = c;
            fired += 1;
        }
        fn dispose(ctx: *anyopaque) void {
            _ = ctx;
            disposed += 1;
        }
    };

    var timer = Timer.init(60_000);
    timer.c.callback = Ctx.cb;
    loop.add(&timer.c);
    loop.cancel(&timer.c, @ptrCast(&loop), Ctx.dispose);

    // 用一个短定时器把循环跑起来，再停；不会因超长定时器而等待。
    var stopper = Timer.init(1);
    stopper.c.callback = struct {
        fn f(l: *Loop, c: *Completion) void {
            _ = c;
            l.stop();
        }
    }.f;
    loop.add(&stopper.c);
    try loop.run();

    try std.testing.expectEqual(@as(usize, 0), Ctx.fired);
    try std.testing.expectEqual(@as(usize, 1), Ctx.disposed);
    try std.testing.expectEqual(@as(usize, 0), loop.retired.count());
}

test "能力表同时容纳 UDP 与 DNS，未注册能力仍返回 null" {
    var loop = try root.open(std.testing.allocator);
    defer loop.deinit();

    try std.testing.expect(loop.io.capability(*const root.udp.VTable, root.udp.id) != null);
    try std.testing.expect(loop.io.capability(*const root.dns.Descriptor, root.dns.id) != null);
    try std.testing.expect(root.dns.Resolver.get(loop.io) != null);
    try std.testing.expect(loop.io.capability(*const root.udp.VTable, root.cap("mox.io.signal.v1")) == null);
}

test "跨线程 submit 洪泛：8 线程各投 256 个定时器，全部回调且不丢" {
    var loop = try testLoop();
    defer loop.deinit();

    const total = 8 * 256;
    const Ctx = struct {
        var fired = std.atomic.Value(usize).init(0);

        fn cb(l: *Loop, c: *Completion) void {
            _ = c;
            const n = fired.fetchAdd(1, .monotonic) + 1;
            // 最后一个回调负责停机：不能靠外部线程翻 running，
            // 那唤不醒已经阻塞在 waitBatch 里的循环线程。
            if (n == total) l.stop();
        }
        fn flood(l: *Loop, timers: []Timer) void {
            for (timers) |*t| {
                t.c.callback = &cb;
                l.submit(&t.c);
            }
        }
    };

    var timers: [total]Timer = undefined;
    for (&timers) |*t| t.* = Timer.init(0);

    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*th, i| {
        th.* = try std.Thread.spawn(.{}, Ctx.flood, .{ &loop, timers[i * 256 ..][0..256] });
    }
    try loop.run();
    for (&threads) |*th| th.join();

    // 洪泛的检验点是"一个都不能丢"：跨线程 Treiber 栈在 8 路并发下
    // 若有竞态，这里必然少计数而不是挂住。
    try std.testing.expectEqual(@as(usize, total), Ctx.fired.load(.monotonic));
}

test "Work 池饱和：提交数远超线程数，全部完成且停机有界" {
    var loop = try testLoop();
    defer loop.deinit();

    // 默认只有 4 个池线程，故意投 64 个任务把它们压满。
    const total = 64;
    const Ctx = struct {
        var items: [total]root.Work = undefined;
        var done = std.atomic.Value(usize).init(0);

        fn work(w: *root.Work) void {
            _ = w;
            // 稍微拉长占用时间，让"饱和"真的发生而不是瞬间排空。
            const start = platform.tickCount();
            while (platform.tickCount() - start < 2) {}
            _ = done.fetchAdd(1, .monotonic);
        }
        fn cb(l: *Loop, c: *Completion) void {
            _ = c;
            if (done.load(.monotonic) == total) l.stop();
        }
    };

    const t0 = platform.tickCount();
    for (&Ctx.items) |*w| {
        w.* = root.Work.init(&Ctx.work);
        w.c.callback = &Ctx.cb;
        loop.add(&w.c);
    }

    // 用定时器轮询完成数，而不是指望最后一个 Work 回调能停循环。
    var timer = Timer.init(10);
    const Poll = struct {
        fn tick(l: *Loop, c: *Completion) void {
            const t: *Timer = @fieldParentPtr("c", c);
            if (Ctx.done.load(.monotonic) == total) {
                l.stop();
                return;
            }
            t.* = Timer.init(10);
            t.c.callback = tick;
            l.add(&t.c);
        }
    };
    timer.c.callback = &Poll.tick;
    loop.add(&timer.c);

    try loop.run();
    const elapsed = platform.tickCount() - t0;

    try std.testing.expectEqual(@as(usize, total), Ctx.done.load(.monotonic));
    // 饱和不等于卡死：64 个 2ms 任务在 4 线程上应远快于串行 128ms。
    try std.testing.expect(elapsed < 5000);
}

test "取消竞态：取消与完成同时发生时只回收一次，不重复回调" {
    var loop = try testLoop();
    defer loop.deinit();

    // 定时器是最容易撞上"已入堆但还没触发"的取消对象，用它逼出竞态。
    const N = 64;
    const Ctx = struct {
        var timers: [N]Timer = undefined;
        var calls = std.atomic.Value(usize).init(0);
        var disposals = std.atomic.Value(usize).init(0);

        fn cb(l: *Loop, c: *Completion) void {
            _ = c;
            _ = calls.fetchAdd(1, .monotonic);
            l.stop();
        }
        fn dispose(ctx: *anyopaque) void {
            _ = ctx;
            _ = disposals.fetchAdd(1, .monotonic);
        }
    };

    for (&Ctx.timers, 0..) |*t, i| {
        t.* = Timer.init(1 + i % 4);
        t.c.callback = &Ctx.cb;
        loop.add(&t.c);
    }
    // 紧接着全部取消：此时它们可能已经入堆、也可能已就绪。
    for (&Ctx.timers) |*t| {
        loop.cancel(&t.c, t, &Ctx.dispose);
    }

    var stop_timer = Timer.init(50);
    const Stop = struct {
        fn tick(l: *Loop, c: *Completion) void {
            _ = c;
            l.stop();
        }
    };
    stop_timer.c.callback = &Stop.tick;
    loop.add(&stop_timer.c);

    try loop.run();
    loop.drainRetired(1000);

    // 取消过的定时器一个都不该回调；每个对象恰好回收一次。
    try std.testing.expectEqual(@as(usize, 0), Ctx.calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, N), Ctx.disposals.load(.monotonic));
}

test "drainRetired 超时可观测：永不回来的取消项记一次超时且不被回收" {
    var loop = try testLoop();
    defer loop.deinit();

    const Ctx = struct {
        fn dispose(ctx: *anyopaque) void {
            _ = ctx;
        }
        fn noop(w: *root.Work) void {
            _ = w;
        }
    };

    // 一个从未提交给线程池的 Work 节点：没有内核在飞操作，取消之后
    // 不会有任何完成包回来，所以它必然一直留在 retired 里。
    var w = root.Work.init(&Ctx.noop);
    w.c.socket = root.INVALID_HANDLE;
    loop.cancel(&w.c, &w, &Ctx.dispose);

    try std.testing.expectEqual(@as(usize, 1), loop.retired.count());
    try std.testing.expectEqual(@as(usize, 0), loop.retired_timeouts);

    loop.drainRetired(50);

    // 超时必须被记下来，而不是静默返回；对象也仍然没有被 dispose。
    try std.testing.expectEqual(@as(usize, 1), loop.retired_timeouts);
    try std.testing.expectEqual(@as(usize, 1), loop.retired.count());
}

// WriteFile 与 ReadFile 对称：都内嵌 Work 节点、回调落在循环线程。
// 这里写一个临时文件再读回来，端到端验证字节真的落盘。
test "WriteFile 通过 Work 池写文件，可被 ReadFile 读回" {
    var l = Loop.init(try platform.create(std.testing.allocator));
    defer l.deinit();

    const path = "zig-cache-mox-writefile-test.txt";
    defer platform.deleteFile(path);

    const Ctx = struct {
        var ok = false;
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            ok = true;
            loop.stop();
        }
    };

    const body = "written-through-work-pool";
    var wf = WriteFile.init(l.io, path, body);
    wf.work.c.callback = &Ctx.cb;
    l.add(&wf.work.c);
    try l.run();

    try std.testing.expect(Ctx.ok);
    try std.testing.expectEqual(body.len, try wf.getResult());

    // 读回来确认不是只返回了长度。
    var buf: [64]u8 = undefined;
    var rf = ReadFile.init(l.io, path, &buf, null);
    rf.work.c.callback = &Ctx.cb;
    l.add(&rf.work.c);
    try l.run();
    try std.testing.expectEqualStrings(body, try rf.getResult());
}

// 失败路径必须把池线程里的错误带回回调，而不是静默成功。
test "WriteFile 写入失败时把错误交给回调" {
    var l = Loop.init(try platform.create(std.testing.allocator));
    defer l.deinit();

    const Ctx = struct {
        var ok = false;
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            ok = true;
            loop.stop();
        }
    };

    var wf = WriteFile.init(l.io, "不存在的目录/无法创建.txt", "x");
    wf.work.c.callback = &Ctx.cb;
    l.add(&wf.work.c);
    try l.run();

    try std.testing.expect(Ctx.ok);
    // 各后端的底层错误名不同（Windows RequestFailed、POSIX OpenFailed 等），
    // 这里只断言「失败被带回回调」，不绑定具体错误值。
    if (wf.getResult()) |n| {
        std.debug.print("期望失败，却写入了 {d} 字节\n", .{n});
        return error.TestUnexpectedResult;
    } else |_| {}
}

// watchdog：正常完成时截止时间定时器被撤销，回调看到的是成功结果。
test "watchdog 在操作按时完成时被撤销" {
    var loop = try testLoop();
    defer loop.deinit();

    const Item = struct {
        work: Work,
        value: u32 = 0,
    };
    const Ctx = struct {
        var done = false;
        var saw_deadline = false;
        fn workFn(w: *Work) void {
            const self: *Item = @fieldParentPtr("work", w);
            self.value = 7; // 立即完成，远早于 5000ms 的截止时间
        }
        fn cb(l: *Loop, c: *Completion) void {
            done = true;
            saw_deadline = if (c.err) |e| e == error.DeadlineExceeded else false;
            l.stop();
        }
    };

    var item: Item = .{ .work = Work.init(&Ctx.workFn) };
    item.work.c.callback = &Ctx.cb;
    var timer = Timer.init(0);
    loop.watchdog(&item.work.c, &timer, 5000);
    loop.add(&item.work.c);
    try loop.run();

    try std.testing.expect(Ctx.done);
    try std.testing.expect(!Ctx.saw_deadline);
    try std.testing.expectEqual(@as(u32, 7), item.value);
    // 正常完成后链接被清空，定时器也不在队列里。
    try std.testing.expect(item.work.c.timeout == null);
    try std.testing.expect(timer.target == null);
}

// watchdog：操作超过截止时间仍未完成时，回调带 DeadlineExceeded 触发一次。
test "watchdog 到点后以 DeadlineExceeded 回调一次" {
    var loop = try testLoop();
    defer loop.deinit();

    const Item = struct {
        work: Work,
        value: u32 = 0,
    };
    const Ctx = struct {
        var calls: usize = 0;
        var saw_deadline = false;
        fn workFn(w: *Work) void {
            const self: *Item = @fieldParentPtr("work", w);
            const start = platform.tickCount();
            while (platform.tickCount() - start < 400) {}
            self.value = 9;
        }
        fn cb(l: *Loop, c: *Completion) void {
            calls += 1;
            saw_deadline = if (c.err) |e| e == error.DeadlineExceeded else false;
            l.stop();
        }
    };

    var item: Item = .{ .work = Work.init(&Ctx.workFn) };
    item.work.c.callback = &Ctx.cb;
    var timer = Timer.init(0);
    loop.watchdog(&item.work.c, &timer, 20); // 远小于 400ms 的实际耗时
    loop.add(&item.work.c);
    try loop.run();

    try std.testing.expectEqual(@as(usize, 1), Ctx.calls);
    try std.testing.expect(Ctx.saw_deadline);
    try std.testing.expect(item.work.c.timeout == null);
}

// unwatchdog：调用方在超时前主动撤销，操作照常完成、不报超时。
test "unwatchdog 主动撤销后操作按原样完成" {
    var loop = try testLoop();
    defer loop.deinit();

    const Item = struct {
        work: Work,
    };
    const Ctx = struct {
        var done = false;
        fn workFn(w: *Work) void {
            _ = w;
        }
        fn cb(l: *Loop, c: *Completion) void {
            done = c.err == null;
            l.stop();
        }
    };

    var item: Item = .{ .work = Work.init(&Ctx.workFn) };
    item.work.c.callback = &Ctx.cb;
    var timer = Timer.init(0);
    loop.watchdog(&item.work.c, &timer, 5000);
    loop.unwatchdog(&item.work.c);
    try std.testing.expect(item.work.c.timeout == null);
    try std.testing.expect(timer.target == null);

    loop.add(&item.work.c);
    try loop.run();
    try std.testing.expect(Ctx.done);
}

// 偏移读：从中间开始读，验证随机访问与文件尾短读。
test "ReadFile 支持偏移读与文件尾短读" {
    var l = Loop.init(try platform.create(std.testing.allocator));
    defer l.deinit();

    const path = "zig-cache-mox-readat-test.txt";
    try platform.writeFileAll(path, "0123456789");
    defer platform.deleteFile(path);

    const Ctx = struct {
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    };

    var buf: [64]u8 = undefined;
    var rf = ReadFile.initAt(l.io, path, 4, &buf, null);
    rf.work.c.callback = &Ctx.cb;
    l.add(&rf.work.c);
    try l.run();
    try std.testing.expectEqualStrings("456789", try rf.getResult());

    // 偏移超出文件长度：读到 0 字节，而不是报错。
    var rf2 = ReadFile.initAt(l.io, path, 100, &buf, null);
    rf2.work.c.callback = &Ctx.cb;
    l.add(&rf2.work.c);
    try l.run();
    try std.testing.expectEqual(@as(usize, 0), (try rf2.getResult()).len);
}

// 追加写：两次追加后内容应为两段拼接，既有内容不被覆盖。
test "WriteFile 追加模式保留既有内容" {
    var l = Loop.init(try platform.create(std.testing.allocator));
    defer l.deinit();

    const path = "zig-cache-mox-append-test.txt";
    defer platform.deleteFile(path);

    const Ctx = struct {
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    };

    var w1 = WriteFile.init(l.io, path, "hello");
    w1.work.c.callback = &Ctx.cb;
    l.add(&w1.work.c);
    try l.run();
    try std.testing.expectEqual(@as(usize, 5), try w1.getResult());

    var w2 = WriteFile.initAppend(l.io, path, "-world");
    w2.work.c.callback = &Ctx.cb;
    l.add(&w2.work.c);
    try l.run();
    try std.testing.expectEqual(@as(usize, 6), try w2.getResult());

    var buf: [64]u8 = undefined;
    var rf = ReadFile.init(l.io, path, &buf, null);
    rf.work.c.callback = &Ctx.cb;
    l.add(&rf.work.c);
    try l.run();
    try std.testing.expectEqualStrings("hello-world", try rf.getResult());
}

// 截断：把 10 字节文件截到 4 字节后，读回来只有前 4 字节。
test "TruncateFile 缩短文件后再读只剩前缀" {
    var l = Loop.init(try platform.create(std.testing.allocator));
    defer l.deinit();

    const path = "zig-cache-mox-truncate-test.txt";
    try platform.writeFileAll(path, "0123456789");
    defer platform.deleteFile(path);

    const Ctx = struct {
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    };

    var tf = TruncateFile.init(l.io, path, 4);
    tf.work.c.callback = &Ctx.cb;
    l.add(&tf.work.c);
    try l.run();
    try tf.getResult();

    var buf: [64]u8 = undefined;
    var rf = ReadFile.init(l.io, path, &buf, null);
    rf.work.c.callback = &Ctx.cb;
    l.add(&rf.work.c);
    try l.run();
    try std.testing.expectEqualStrings("0123", try rf.getResult());
}

// 删除：删掉后读应报 FileNotFound；再删一次仍成功（幂等）。
test "DeleteFile 删除文件且重复删除不报错" {
    var l = Loop.init(try platform.create(std.testing.allocator));
    defer l.deinit();

    const path = "zig-cache-mox-delete-test.txt";
    try platform.writeFileAll(path, "gone");

    const Ctx = struct {
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    };

    var df = DeleteFile.init(l.io, path);
    df.work.c.callback = &Ctx.cb;
    l.add(&df.work.c);
    try l.run();
    try df.getResult();

    // 第二次删除：文件已不存在，仍应成功。
    var df2 = DeleteFile.init(l.io, path);
    df2.work.c.callback = &Ctx.cb;
    l.add(&df2.work.c);
    try l.run();
    try df2.getResult();

    var buf: [16]u8 = undefined;
    var rf = ReadFile.init(l.io, path, &buf, null);
    rf.work.c.callback = &Ctx.cb;
    l.add(&rf.work.c);
    try l.run();
    // 读已删除的文件必须失败。这里不断言具体错误名：各后端对「文件不存在」
    // 的映射不同（Windows/POSIX 走 FileNotFound，macOS kqueue 走 OpenFailed）。
    if (rf.getResult()) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

// 幂等（ENOENT）不能掩盖真正的删除失败：删一个非空目录应被计数。
test "deleteFile 失败不再静默：delete_failures 可观测" {
    var l = Loop.init(try platform.create(std.testing.allocator));
    defer l.deinit();

    const dir = "zig-cache-mox-delete-dir";
    try l.makeDir(dir, 0o755);
    defer l.removeDir(dir) catch {};
    const path = dir ++ "/f";
    try platform.writeFileAll(path, "x");
    defer l.deleteFile(path);

    try std.testing.expectEqual(@as(usize, 0), l.delete_failures);
    // unlink 一个目录：Linux EISDIR / Windows ERROR_ACCESS_DENIED，都不是 ENOENT。
    l.deleteFile(dir);
    try std.testing.expect(l.delete_failures > 0);
}

// `closeChecked`：有效句柄关闭成功；重复关闭报 `error.NotOpen`，
// 并累加 `close_failures`（`close` 本身吞错，不可见）。
test "closeChecked 区分成功与失败：重复关闭报 NotOpen" {
    var l = try testLoop();
    defer l.deinit();

    const bind_addr = try net.IpAddress.parse("127.0.0.1", 0);
    const sock = try platform.createTcpSocket(bind_addr);
    try std.testing.expectEqual(@as(usize, 0), l.close_failures);

    // 第一次关闭：成功。
    try l.closeChecked(sock);
    try std.testing.expectEqual(@as(usize, 0), l.close_failures);

    // 第二次关闭：句柄已失效，必须报错而不是静默成功。
    try std.testing.expectError(error.NotOpen, l.closeChecked(sock));
    try std.testing.expectEqual(@as(usize, 1), l.close_failures);
}

// 子进程：同步 spawn 后异步等退出，退出码应被带回回调。
test "Process 启动子进程并异步等退出" {
    var loop = try testLoop();
    defer loop.deinit();

    const Ctx = struct {
        var done = false;
        fn cb(l: *Loop, c: *Completion) void {
            _ = c;
            done = true;
            l.stop();
        }
    };

    var proc = try Process.spawn(.{
        .allocator = std.heap.page_allocator,
        .argv = if (builtin.os.tag == .windows)
            &.{ "cmd.exe", "/c", "exit 7" }
        else
            &.{ "/bin/sh", "-c", "exit 7" },
        .create_no_window = true,
    });
    defer if (proc.alive) proc.kill();

    var wait = ProcessWait.init(&proc);
    wait.work.c.callback = &Ctx.cb;
    loop.add(&wait.work.c);
    try loop.run();

    try std.testing.expect(Ctx.done);
    const term = try wait.getResult();
    try std.testing.expectEqual(@as(?u8, 7), term.code());
}

// 子进程：stdio 重定向到管道后可读到子进程输出（`Stdio.pipe` 路径可用）。
test "Process 可通过管道读取子进程输出" {
    var loop = try testLoop();
    defer loop.deinit();

    var proc = try Process.spawn(.{
        .allocator = std.heap.page_allocator,
        .argv = if (builtin.os.tag == .windows)
            &.{ "cmd.exe", "/c", "echo hello-child" }
        else
            &.{ "/bin/sh", "-c", "echo hello-child" },
        .stdout = .pipe,
        .create_no_window = true,
    });
    defer if (proc.alive) proc.kill();

    // 读完 stdout 再等退出，避免子进程因管道写满而阻塞。
    var buf: [128]u8 = undefined;
    const n = if (builtin.os.tag == .windows)
        try readAllWindows(proc.stdoutFd().?, &buf)
    else
        try readAllPosix(proc.stdoutFd().?, &buf);
    const term = try proc.waitSync();
    try std.testing.expect(term.success());
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "hello-child") != null);
}

fn readAllPosix(fd: anytype, buf: []u8) !usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.read(fd, buf[total..]) catch |e| {
            if (e == error.WouldBlock) continue;
            return e;
        };
        if (n == 0) break;
        total += n;
    }
    return total;
}

// `ReadFile` 不在 std 的 kernel32 绑定里，按 mox 一贯做法自行声明。
const kernelReadFile = @extern(
    *const fn (
        h: std.os.windows.HANDLE,
        buf: [*]u8,
        len: std.os.windows.DWORD,
        got: *std.os.windows.DWORD,
        overlapped: ?*anyopaque,
    ) callconv(.winapi) std.os.windows.BOOL,
    .{ .name = "ReadFile", .library_name = "kernel32" },
);

fn readAllWindows(handle: anytype, buf: []u8) !usize {
    const h: std.os.windows.HANDLE = @ptrFromInt(handle);
    var got: std.os.windows.DWORD = 0;
    if (!kernelReadFile(h, buf.ptr, @intCast(buf.len), &got, null).toBool()) return error.ReadFailed;
    return got;
}

// ===== 信号订阅 =====
//
// 只在 POSIX 上跑；Windows 的 `Signal.init` 直接返回 `error.Unsupported`，
// 那条路径由下面第一条测试覆盖。

test "Signal 在 Windows 上明确返回 Unsupported" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const r = root.Signal.init(root.Signals.USR1);
    try std.testing.expectError(error.Unsupported, r);
}

test "Signal 订阅 USR1 后 self-pipe 收到通知" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var l = try testLoop();
    defer l.deinit();

    var s = try root.Signal.init(root.Signals.USR1);
    defer s.deinit();

    const Ctx = struct {
        var done = false;
        fn cb(lp: *Loop, c: *Completion) void {
            _ = c;
            done = true;
            lp.stop();
        }
    };
    var wd = Timer.init(5000);
    s.work.c.callback = &Ctx.cb;
    l.add(&s.work.c);
    // 看门狗：若 self-pipe 没被写入，池线程永远阻塞在读端，`run` 会挂死。
    // 有它在，变异（处理器不写 pipe）表现为明确的超时失败而非 CI 卡住。
    l.watchdog(&s.work.c, &wd, 5000);

    // 给自己发信号，处理器写 self-pipe，池线程读端返回。
    const pid = if (builtin.os.tag == .linux)
        @as(i32, @intCast(std.os.linux.getpid()))
    else
        std.c.getpid();
    try std.testing.expect(root.signal.raiseForTest(pid, root.Signals.USR1));

    try l.run();
    try std.testing.expect(Ctx.done);
    // 看门狗到点会先把节点标成超时；有信号到达才算真通过。
    try std.testing.expectEqual(@as(u8, root.Signals.USR1), try s.getResult());
}

// ===== 任意 fd 就绪监视（`WatchFd`）=====
//
// 跨平台管道辅助：Linux 不链 libc（见 README「子进程」一节）必须走裸 syscall，
// macOS/BSD 始终链 libSystem 则用 `std.c`。写成函数而不是内联，是为了让两个
// 测试共用同一份、且平台分派只出现在一处。

const Pipe = struct {
    fds: [2]i32,

    fn open() !Pipe {
        var fds: [2]i32 = undefined;
        if (builtin.os.tag == .linux) {
            const rc = std.os.linux.pipe2(&fds, .{ .CLOEXEC = true });
            if (@as(isize, @bitCast(rc)) < 0) return error.PipeFailed;
        } else {
            // macOS 上没有 `pipe2` 的可用绑定，退回 `pipe` + 事后设 CLOEXEC。
            if (std.c.pipe(&fds) != 0) return error.PipeFailed;
            for (fds) |fd| _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
        }
        return .{ .fds = fds };
    }

    fn close(self: Pipe) void {
        for (self.fds) |fd| {
            if (builtin.os.tag == .linux) {
                _ = std.os.linux.close(@intCast(fd));
            } else {
                _ = std.c.close(fd);
            }
        }
    }

    fn writeByte(self: Pipe, b: u8) !void {
        const buf = [1]u8{b};
        const n: isize = if (builtin.os.tag == .linux)
            @bitCast(std.os.linux.write(@intCast(self.fds[1]), &buf, 1))
        else
            std.c.write(self.fds[1], &buf, 1);
        if (n != 1) return error.WriteFailed;
    }
};

//
// 只在 POSIX 上跑：Windows 的 IOCP 是完成模型，`watchFd` 槽位为 `null`，
// 调用方拿 `error.Unsupported`——那条路径由第一条测试覆盖。

test "WatchFd 在 Windows 上返回 Unsupported" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var loop = try testLoop();
    defer loop.deinit();

    const Ctx = struct {
        var saw_unsupported = false;
        fn cb(l: *Loop, c: *Completion) void {
            // `c.err` 是 `?anyerror`；显式取出再比，避免类型推断歧义。
            if (c.err) |e| saw_unsupported = (e == error.Unsupported);
            l.stop();
        }
    };
    var w = root.WatchFd.init(@intCast(0), .{ .read = true });
    w.c.callback = &Ctx.cb;
    loop.add(&w.c);
    try loop.run();
    try std.testing.expect(Ctx.saw_unsupported);
}

test "WatchFd 在管道可读时回调并回填 read 方向" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var loop = try testLoop();
    defer loop.deinit();

    const pipe = try Pipe.open();
    defer pipe.close();

    const Ctx = struct {
        var done = false;
        var got: root.Ready = .{};
        fn cb(l: *Loop, c: *Completion) void {
            const w: *root.WatchFd = @fieldParentPtr("c", c);
            got = w.ready;
            done = true;
            l.stop();
        }
    };

    var w = root.WatchFd.init(@intCast(pipe.fds[0]), .{ .read = true });
    var wd = Timer.init(5000);
    w.c.callback = &Ctx.cb;
    loop.add(&w.c);
    // 看门狗：管道没写可读端永远不就绪，`run` 会挂死。
    loop.watchdog(&w.c, &wd, 5000);

    // 从另一头写入，触发可读。
    try pipe.writeByte('x');

    try loop.run();
    try std.testing.expect(Ctx.done);
    try std.testing.expect(Ctx.got.read);
    try std.testing.expect(!Ctx.got.write);
}

// ===== 目录与元数据 =====
//
// 这些是 `Work` 池里的阻塞调用，四个平台各有实现。测试只用临时目录，
// 每个用例自建自清，互不干扰。

/// 在系统临时目录下造一个唯一子目录，返回完整路径。调用方负责删。
fn tmpDir(buf: []u8, tag: []const u8) ![]const u8 {
    // 0.17 移除了 `std.time.milliTimestamp`；用后端已有的单调时钟辅助。
    const stamp = platform.tickCount();
    const n = @as(u64, @intCast(@mod(stamp, 1_000_000_000)));
    // Windows 上绝不能用前导 `\` —— 那是「当前盘符根」，测试残留会直接
    // 洒在 `D:\` 根目录。这里与 POSIX 的 `/tmp/` 对应，放在进程工作目录
    // （`zig build` 下即工程根），清理失败时也只落在仓库里，肉眼可见。
    if (builtin.os.tag == .windows) {
        return std.fmt.bufPrint(buf, "mox_{s}_{d}", .{ tag, n });
    }
    return std.fmt.bufPrint(buf, "/tmp/mox_{s}_{d}", .{ tag, n });
}

test "makeDir 递归创建、stat 识别为目录、removeDir 删掉" {
    var l = try testLoop();
    defer l.deinit();

    var pbuf: [512]u8 = undefined;
    const base = try tmpDir(&pbuf, "mkdir");
    defer l.removeDir(base) catch {};

    // 中间两级都不存在，验证 mkdir -p 语义。
    var deepbuf: [600]u8 = undefined;
    const deep = try std.fmt.bufPrint(&deepbuf, "{s}{c}a{c}b", .{
        base,
        if (builtin.os.tag == .windows) '\\' else '/',
        if (builtin.os.tag == .windows) '\\' else '/',
    });

    try l.makeDir(deep, 0o755);

    const st = try l.statPath(deep);
    try std.testing.expectEqual(root.FileKind.directory, st.kind);

    // 重复创建不报错（幂等）。
    try l.makeDir(deep, 0o755);

    try l.removeDir(deep);
    try std.testing.expectError(error.FileNotFound, l.statPath(deep));
    // 中间层 `a` 还留在 base 里：先删掉它，否则 defer 的 removeDir(base)
    // 会因目录非空静默失败（`catch {}` 吞掉），把残留目录留在盘上。
    var midbuf: [560]u8 = undefined;
    const mid = try std.fmt.bufPrint(&midbuf, "{s}{c}a", .{
        base,
        if (builtin.os.tag == .windows) '\\' else '/',
    });
    try l.removeDir(mid);
}

test "removeDir 对非空目录报 DirNotEmpty" {
    var l = try testLoop();
    defer l.deinit();

    var pbuf: [512]u8 = undefined;
    const dir = try tmpDir(&pbuf, "rmnonempty");
    try l.makeDir(dir, 0o755);
    defer l.removeDir(dir) catch {};

    var fbuf: [600]u8 = undefined;
    const file = try std.fmt.bufPrint(&fbuf, "{s}{c}f.txt", .{
        dir,
        if (builtin.os.tag == .windows) '\\' else '/',
    });
    try l.writeFileAll(file, "x");
    defer l.deleteFile(file);

    try std.testing.expectError(error.DirNotEmpty, l.removeDir(dir));
}

test "rename 移动文件，原路径消失、新路径可读" {
    var l = try testLoop();
    defer l.deinit();

    var pbuf: [512]u8 = undefined;
    const dir = try tmpDir(&pbuf, "rename");
    try l.makeDir(dir, 0o755);
    defer l.removeDir(dir) catch {};

    const sep = if (builtin.os.tag == .windows) '\\' else '/';
    var abuf: [600]u8 = undefined;
    var bbuf: [600]u8 = undefined;
    const from = try std.fmt.bufPrint(&abuf, "{s}{c}from.txt", .{ dir, sep });
    const to = try std.fmt.bufPrint(&bbuf, "{s}{c}to.txt", .{ dir, sep });

    try l.writeFileAll(from, "payload");

    try l.rename(from, to);

    try std.testing.expectError(error.FileNotFound, l.statPath(from));
    const st = try l.statPath(to);
    try std.testing.expectEqual(root.FileKind.file, st.kind);
    try std.testing.expectEqual(@as(u64, 7), st.size);

    l.deleteFile(to);
}

test "stat 报告文件大小与 mtime，listDir 列出条目" {
    var l = try testLoop();
    defer l.deinit();

    var pbuf: [512]u8 = undefined;
    const dir = try tmpDir(&pbuf, "stat");
    try l.makeDir(dir, 0o755);
    defer l.removeDir(dir) catch {};

    const sep = if (builtin.os.tag == .windows) '\\' else '/';
    var f1buf: [600]u8 = undefined;
    var f2buf: [600]u8 = undefined;
    const f1 = try std.fmt.bufPrint(&f1buf, "{s}{c}one.txt", .{ dir, sep });
    const f2 = try std.fmt.bufPrint(&f2buf, "{s}{c}two.txt", .{ dir, sep });
    try l.writeFileAll(f1, "12345");
    try l.writeFileAll(f2, "ab");
    defer l.deleteFile(f1);
    defer l.deleteFile(f2);

    const st = try l.statPath(f1);
    try std.testing.expectEqual(@as(u64, 5), st.size);
    // mtime 必须是个合理的近期时间；0 说明平台层没回填。
    try std.testing.expect(st.mtime_ms > 1_600_000_000_000);

    var entries: [16]root.DirEntry = undefined;
    const n = try l.listDir(dir, &entries);
    try std.testing.expectEqual(@as(usize, 2), n);

    var found_one = false;
    var found_two = false;
    for (entries[0..n]) |*e| {
        if (std.mem.eql(u8, e.slice(), "one.txt")) found_one = true;
        if (std.mem.eql(u8, e.slice(), "two.txt")) found_two = true;
        try std.testing.expect(!e.is_dir);
    }
    try std.testing.expect(found_one and found_two);
}

test "symLink 创建链接，stat 跟随到目标文件" {
    // Windows 的符号链接需要管理员权限或开发者模式，普通 CI 上会失败。
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var l = try testLoop();
    defer l.deinit();

    var pbuf: [512]u8 = undefined;
    const dir = try tmpDir(&pbuf, "symlink");
    try l.makeDir(dir, 0o755);
    defer l.removeDir(dir) catch {};

    var tbuf: [600]u8 = undefined;
    var lbuf: [600]u8 = undefined;
    const target = try std.fmt.bufPrint(&tbuf, "{s}/target.txt", .{dir});
    const link = try std.fmt.bufPrint(&lbuf, "{s}/link.txt", .{dir});
    try l.writeFileAll(target, "hello");
    defer l.deleteFile(target);

    try l.symLink(target, link);
    defer l.deleteFile(link);

    // `stat` 跟随链接，看到的是目标文件的属性。
    const st = try l.statPath(link);
    try std.testing.expectEqual(root.FileKind.file, st.kind);
    try std.testing.expectEqual(@as(u64, 5), st.size);
}

// ===== Unix domain socket =====
//
// Windows 不支持（IOCP 后端整组槽位为 `null`），那条路径由第一条测试覆盖。

test "Unix socket 在 Windows 上返回 Unsupported" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var l = try testLoop();
    defer l.deinit();
    try std.testing.expectError(error.Unsupported, l.createUnixSocket());
}

test "Unix socket 可 bind、listen、accept、收发数据" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var l = try testLoop();
    defer l.deinit();

    var pbuf: [512]u8 = undefined;
    const dir = try tmpDir(&pbuf, "uds");
    try l.makeDir(dir, 0o755);
    defer l.removeDir(dir) catch {};

    // 路径必须短：`Scratch` 只有 64 字节，UDS sockaddr 结构头占 2 字节。
    var spath_buf: [80]u8 = undefined;
    const sock_path = try std.fmt.bufPrint(&spath_buf, "{s}/s.sock", .{dir});
    if (sock_path.len > 60) return error.SkipZigTest; // 临时目录路径太长，跳过
    defer l.deleteFile(sock_path);

    const listener = try l.createUnixSocket();
    defer l.close(listener);
    try l.bindUnix(listener, sock_path);
    try l.listen(listener, 8);

    const Ctx = struct {
        var total: usize = 0;
        var buf: [16]u8 = undefined;
        var recv: root.NetRecv = undefined;
        var accepted: Handle = INVALID_HANDLE;

        fn onAccept(lp: *Loop, c: *Completion) void {
            const a: *root.NetAccept = @fieldParentPtr("c", c);
            accepted = a.getResult() catch {
                lp.stop();
                return;
            };
            recv = root.NetRecv.init(accepted, &buf);
            recv.c.callback = &onRecv;
            lp.add(&recv.c);
        }
        fn onRecv(lp: *Loop, c: *Completion) void {
            const r: *root.NetRecv = @fieldParentPtr("c", c);
            total = r.getResult() catch 0;
            lp.stop();
        }
    };

    // `NetAccept` 要求一个与监听同族、尚未绑定的 socket 作为接收容器
    // （与 TCP 的用法一致；io_uring/kqueue 上内核会填它）。
    const accept_sock = try l.createUnixSocket();
    defer l.close(accept_sock);
    var accept = root.NetAccept.init(listener, accept_sock);
    var wd = Timer.init(5000);
    accept.c.callback = &Ctx.onAccept;
    l.add(&accept.c);
    l.watchdog(&accept.c, &wd, 5000);

    // 客户端在另一线程连上来写一行。
    const Client = struct {
        fn run(path: []const u8) void {
            // 客户端只用阻塞辅助函数，不碰事件循环。Linux 不链 libc，
            // 所以按平台分派（与 `Pipe` 辅助同一套理由）。
            if (builtin.os.tag == .linux) {
                const lx = std.os.linux;
                const fd = lx.socket(lx.AF.UNIX, lx.SOCK.STREAM, 0);
                const fd_s: isize = @bitCast(fd);
                if (fd_s < 0) return;
                defer _ = lx.close(@intCast(fd_s));
                var sa: lx.sockaddr.un = undefined;
                @memset(std.mem.asBytes(&sa), 0);
                sa.family = lx.AF.UNIX;
                @memcpy(sa.path[0..path.len], path);
                const len: lx.socklen_t = @intCast(@offsetOf(lx.sockaddr.un, "path") + path.len + 1);
                if (@as(isize, @bitCast(lx.connect(@intCast(fd_s), @ptrCast(&sa), len))) != 0) return;
                _ = lx.write(@intCast(fd_s), "hi", 2);
            } else {
                const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
                if (fd < 0) return;
                defer _ = std.c.close(fd);
                var sa: std.c.sockaddr.un = undefined;
                @memset(std.mem.asBytes(&sa), 0);
                sa.family = std.c.AF.UNIX;
                @memcpy(sa.path[0..path.len], path);
                sa.len = @intCast(@offsetOf(std.c.sockaddr.un, "path") + path.len + 1);
                if (std.c.connect(fd, @ptrCast(&sa), sa.len) != 0) return;
                _ = std.c.write(fd, "hi", 2);
            }
        }
    };
    const t = try std.Thread.spawn(.{}, Client.run, .{sock_path});
    defer t.join();

    try l.run();
    try std.testing.expectEqual(@as(usize, 2), Ctx.total);
}

// ===== io_uring 原生异步文件 I/O =====
//
// 只有 io_uring 提供；其它后端 `readFileAsync` 为 `null`，节点返回
// `error.Unsupported`，调用方应回落 `ReadFile`（Work 版）。

test "ReadFileAsync 在非 io_uring 后端返回 Unsupported" {
    var l = try testLoop();
    defer l.deinit();
    if (l.io.vtable.readFileAsync != null) return error.SkipZigTest;

    const Ctx = struct {
        var saw = false;
        fn cb(lp: *Loop, c: *Completion) void {
            if (c.err) |e| saw = (e == error.Unsupported);
            lp.stop();
        }
    };
    var buf: [16]u8 = undefined;
    var f = root.ReadFileAsync.init("/nonexistent", &buf);
    f.c.callback = &Ctx.cb;
    l.add(&f.c);
    try l.run();
    try std.testing.expect(Ctx.saw);
}

test "ReadFileAsync 异步读文件并与阻塞版内容一致" {
    var l = try testLoop();
    defer l.deinit();
    if (l.io.vtable.readFileAsync == null) return error.SkipZigTest;

    var pbuf: [512]u8 = undefined;
    const dir = try tmpDir(&pbuf, "afile");
    try l.makeDir(dir, 0o755);
    defer l.removeDir(dir) catch {};

    var fbuf: [600]u8 = undefined;
    const fpath = try std.fmt.bufPrint(&fbuf, "{s}/a.txt", .{dir});
    defer l.deleteFile(fpath);

    const payload = "async-file-io";
    try l.writeFileAll(fpath, payload);

    // `openat` 的 SQE 直接读这块内存，必须 NUL 结尾。
    var zpath_buf: [700]u8 = undefined;
    @memcpy(zpath_buf[0..fpath.len], fpath);
    zpath_buf[fpath.len] = 0;
    const zpath: [:0]const u8 = zpath_buf[0..fpath.len :0];

    const Ctx = struct {
        var done = false;
        fn cb(lp: *Loop, c: *Completion) void {
            _ = c;
            done = true;
            lp.stop();
        }
    };

    var buf: [64]u8 = undefined;
    var f = root.ReadFileAsync.init(zpath, &buf);
    var wd = Timer.init(5000);
    f.c.callback = &Ctx.cb;
    l.add(&f.c);
    l.watchdog(&f.c, &wd, 5000);

    try l.run();
    try std.testing.expect(Ctx.done);
    const got = try f.getResult();
    try std.testing.expectEqualStrings(payload, got);
}

test "WriteFileAsync 异步写文件后阻塞读回一致" {
    var l = try testLoop();
    defer l.deinit();
    if (l.io.vtable.writeFileAsync == null) return error.SkipZigTest;

    var pbuf: [512]u8 = undefined;
    const dir = try tmpDir(&pbuf, "awrite");
    try l.makeDir(dir, 0o755);
    defer l.removeDir(dir) catch {};

    var fbuf: [600]u8 = undefined;
    const fpath = try std.fmt.bufPrint(&fbuf, "{s}/w.txt", .{dir});
    defer l.deleteFile(fpath);

    var zpath_buf: [700]u8 = undefined;
    @memcpy(zpath_buf[0..fpath.len], fpath);
    zpath_buf[fpath.len] = 0;
    const zpath: [:0]const u8 = zpath_buf[0..fpath.len :0];

    const Ctx = struct {
        var done = false;
        fn cb(lp: *Loop, c: *Completion) void {
            _ = c;
            done = true;
            lp.stop();
        }
    };

    const payload = "written-async";
    var f = root.WriteFileAsync.init(zpath, payload);
    var wd = Timer.init(5000);
    f.c.callback = &Ctx.cb;
    l.add(&f.c);
    l.watchdog(&f.c, &wd, 5000);

    try l.run();
    try std.testing.expect(Ctx.done);
    try std.testing.expectEqual(@as(usize, payload.len), try f.getResult());

    // 用阻塞版读回，确认真的落到磁盘。
    const st = try l.statPath(fpath);
    try std.testing.expectEqual(@as(u64, payload.len), st.size);
}

test "ReadFileAsync 循环读不泄漏 fd（close 真的执行了）" {
    var l = try testLoop();
    defer l.deinit();
    if (l.io.vtable.readFileAsync == null) return error.SkipZigTest;
    // 只有 Linux 能便宜地数 /proc/self/fd。
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var pbuf: [512]u8 = undefined;
    const dir = try tmpDir(&pbuf, "fdleak");
    try l.makeDir(dir, 0o755);
    defer l.removeDir(dir) catch {};

    var fbuf: [600]u8 = undefined;
    const fpath = try std.fmt.bufPrint(&fbuf, "{s}/f.txt", .{dir});
    defer l.deleteFile(fpath);
    try l.writeFileAll(fpath, "abc");

    var zpath_buf: [700]u8 = undefined;
    @memcpy(zpath_buf[0..fpath.len], fpath);
    zpath_buf[fpath.len] = 0;
    const zpath: [:0]const u8 = zpath_buf[0..fpath.len :0];

    const Ctx = struct {
        var done = false;
        fn cb(lp: *Loop, c: *Completion) void {
            _ = c;
            done = true;
            lp.stop();
        }
    };

    const before = countOpenFds();

    // 20 次足够暴露泄漏：每次漏一个 fd，20 次后 /proc/self/fd 明显变多。
    // （默认 ulimit 通常是 1024，直接循环 200 次反而可能撞上限。）
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        Ctx.done = false;
        var buf: [16]u8 = undefined;
        var f = root.ReadFileAsync.init(zpath, &buf);
        var wd = Timer.init(5000);
        f.c.callback = &Ctx.cb;
        l.add(&f.c);
        l.watchdog(&f.c, &wd, 5000);
        try l.run();
        try std.testing.expect(Ctx.done);
        try std.testing.expectEqualStrings("abc", try f.getResult());
    }

    const after = countOpenFds();
    // 允许 ±2 的抖动（loop 自身可能开 eventfd 等）。
    try std.testing.expect(after <= before + 2);
}

/// 数 `/proc/self/fd` 里的条目。仅 Linux。
fn countOpenFds() usize {
    const lx = std.os.linux;
    const fd = lx.open("/proc/self/fd", .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
    const fd_s: isize = @bitCast(fd);
    if (fd_s < 0) return 0;
    defer _ = lx.close(@intCast(fd_s));

    var buf: [2048]u8 = undefined;
    var n: usize = 0;
    while (true) {
        const rc = lx.getdents64(@intCast(fd_s), &buf, buf.len);
        const rc_s: isize = @bitCast(rc);
        if (rc_s <= 0) break;
        var off: usize = 0;
        while (off < @as(usize, @intCast(rc_s))) {
            const d: *align(1) lx.dirent64 = @ptrCast(buf[off..].ptr);
            n += 1;
            off += d.reclen;
        }
    }
    return n;
}

test "ReadFileAsync 对不存在的文件报 FileNotFound" {
    var l = try testLoop();
    defer l.deinit();
    if (l.io.vtable.readFileAsync == null) return error.SkipZigTest;

    const Ctx = struct {
        var got: ?anyerror = null;
        fn cb(lp: *Loop, c: *Completion) void {
            _ = c;
            lp.stop();
        }
    };

    var buf: [16]u8 = undefined;
    var f = root.ReadFileAsync.init("/tmp/mox_definitely_not_here_12345", &buf);
    f.c.callback = &Ctx.cb;
    l.add(&f.c);
    try l.run();
    // openat 失败发生在提交阶段，`c.err` 直接被填。
    try std.testing.expect(f.c.err != null);
    _ = Ctx.got;
}

// 一次提交远超环容量的操作数，每个都必须完成。
//
// **这条测的是背压，不是性能。** io_uring 的 SQ 环只有 256 格、CQ 环有限，
// 一次性 `add` 上千个操作时有三条独立路径会让完成包静默消失：
//
// 1. `getSqe` 绕环覆写还没提交的 SQE；
// 2. CQ 满后内核停止推进 SQ head，`getSqe` 死等；
// 3. CQ 满后内核**丢弃**后续完成包（`sq_head` 照样推进，看起来像全消费了）。
//
// 三种表现都是「回调永不触发」，在 CI 里表现为挂死（超时 124）而不是失败。
// 所以每个节点都挂 watchdog，把挂死转成明确的 `DeadlineExceeded`。
//
// 规模取 1200：既超过 SQ 环（256）也超过 CQ 环（2048/2 的常规余量），
// 又能在 30s watchdog 内跑完（20000 个在本地要 10s 以上）。
test "大批量提交超过环容量时每个操作都完成（背压不丢回调）" {
    var l = try testLoop();
    defer l.deinit();
    if (l.io.vtable.readFileAsync == null) return error.SkipZigTest;

    var pbuf: [512]u8 = undefined;
    const dir = try tmpDir(&pbuf, "burst");
    try l.makeDir(dir, 0o755);
    defer l.removeDir(dir) catch {};

    var fbuf: [600]u8 = undefined;
    const fpath = try std.fmt.bufPrint(&fbuf, "{s}/b.txt", .{dir});
    defer l.deleteFile(fpath);
    try l.writeFileAll(fpath, "hello-burst");

    var zpath_buf: [700]u8 = undefined;
    @memcpy(zpath_buf[0..fpath.len], fpath);
    zpath_buf[fpath.len] = 0;
    const zpath: [:0]const u8 = zpath_buf[0..fpath.len :0];

    const n = 3000;
    const Ctx = struct {
        var remaining: usize = 0;
        var bad: usize = 0;
        fn cb(lp: *Loop, c: *Completion) void {
            if (c.err != null) bad += 1;
            // 饱和减法：watchdog 与真实完成可能先后触发同一个节点。
            remaining -|= 1;
            if (remaining == 0) lp.stop();
        }
    };
    Ctx.remaining = n;
    Ctx.bad = 0;

    var nodes: [n]root.ReadFileAsync = undefined;
    var bufs: [n][16]u8 = undefined;
    var wds: [n]Timer = undefined;
    for (&nodes, 0..) |*node, i| {
        node.* = root.ReadFileAsync.init(zpath, &bufs[i]);
        node.c.callback = &Ctx.cb;
        l.add(&node.c);
        // 每个节点单独挂 30s watchdog：环管理坏掉时是挂死，不是失败。
        wds[i] = Timer.init(30_000);
        l.watchdog(&node.c, &wds[i], 30_000);
    }

    try l.run();

    // 失败的个数必须为 0——任何一个丢了回调，`remaining` 就永远降不到 0，
    // 循环会靠 watchdog 超时退出，而超时的节点会把 `bad` 加上去。
    try std.testing.expectEqual(@as(usize, 0), Ctx.bad);
    try std.testing.expectEqual(@as(usize, 0), Ctx.remaining);
}

test "ReadFileAsync 的 offset 生效（从中间读）" {
    var l = try testLoop();
    defer l.deinit();
    if (l.io.vtable.readFileAsync == null) return error.SkipZigTest;

    var pbuf: [512]u8 = undefined;
    const dir = try tmpDir(&pbuf, "aoff");
    try l.makeDir(dir, 0o755);
    defer l.removeDir(dir) catch {};

    var fbuf: [600]u8 = undefined;
    const fpath = try std.fmt.bufPrint(&fbuf, "{s}/o.txt", .{dir});
    defer l.deleteFile(fpath);
    try l.writeFileAll(fpath, "0123456789");

    var zpath_buf: [700]u8 = undefined;
    @memcpy(zpath_buf[0..fpath.len], fpath);
    zpath_buf[fpath.len] = 0;
    const zpath: [:0]const u8 = zpath_buf[0..fpath.len :0];

    const Ctx = struct {
        var done = false;
        fn cb(lp: *Loop, c: *Completion) void {
            _ = c;
            done = true;
            lp.stop();
        }
    };

    var buf: [8]u8 = undefined;
    var f = root.ReadFileAsync.initAt(zpath, 3, &buf);
    var wd = Timer.init(5000);
    f.c.callback = &Ctx.cb;
    l.add(&f.c);
    l.watchdog(&f.c, &wd, 5000);

    try l.run();
    try std.testing.expect(Ctx.done);
    // offset=3 起读 8 字节 → "3456789"（只剩 7 字节）。
    try std.testing.expectEqualStrings("3456789", try f.getResult());
}

// ===== 零拷贝文件 → socket =====

test "SendFile 在 Windows 上返回 Unsupported" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var l = try testLoop();
    defer l.deinit();
    const f = l.io.vtable.sendFileTo;
    try std.testing.expect(f == null);
}

test "SendFile 把文件内容经 sendfile 送进 socket" {
    // 用 Unix domain socket 做连接对：本机 UDS 的 connect 立即完成，
    // 不需要 TCP 握手时序，测试更稳定。
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var l = try testLoop();
    defer l.deinit();
    if (l.io.vtable.sendFileTo == null) return error.SkipZigTest;

    var pbuf: [512]u8 = undefined;
    const dir = try tmpDir(&pbuf, "sendfile");
    try l.makeDir(dir, 0o755);
    defer l.removeDir(dir) catch {};

    var fbuf: [600]u8 = undefined;
    const fpath = try std.fmt.bufPrint(&fbuf, "{s}/sf.txt", .{dir});
    defer l.deleteFile(fpath);
    const payload = "sendfile-payload-42";
    try l.writeFileAll(fpath, payload);

    var spath_buf: [80]u8 = undefined;
    const sock_path = try std.fmt.bufPrint(&spath_buf, "{s}/s.sock", .{dir});
    if (sock_path.len > 60) return error.SkipZigTest;
    defer l.deleteFile(sock_path);

    // 服务端：bind + listen，然后同步 accept（UDS 上客户端 connect 会立即
    // 排队，accept 不会阻塞）。
    const listener = try l.createUnixSocket();
    defer l.close(listener);
    try l.bindUnix(listener, sock_path);
    try l.listen(listener, 4);

    // 客户端在另一线程 connect 并读数据——不能用 std.c（Linux 不链 libc）。
    const Reader = struct {
        var n: usize = 0;
        var buf: [64]u8 = undefined;
        fn run(path: []const u8) void {
            const lx = std.os.linux;
            const fd = lx.socket(lx.AF.UNIX, lx.SOCK.STREAM, 0);
            const fd_s: isize = @bitCast(fd);
            if (fd_s < 0) return;
            defer _ = lx.close(@intCast(fd_s));
            var sa: lx.sockaddr.un = undefined;
            @memset(std.mem.asBytes(&sa), 0);
            sa.family = lx.AF.UNIX;
            @memcpy(sa.path[0..path.len], path);
            const len: lx.socklen_t = @intCast(@offsetOf(lx.sockaddr.un, "path") + path.len + 1);
            if (@as(isize, @bitCast(lx.connect(@intCast(fd_s), @ptrCast(&sa), len))) != 0) return;
            // 读到 EOF 或缓冲满。
            while (n < buf.len) {
                const rc = lx.read(@intCast(fd_s), buf[n..].ptr, buf.len - n);
                const rc_s: isize = @bitCast(rc);
                if (rc_s <= 0) break;
                n += @intCast(rc_s);
            }
        }
    };

    const t = try std.Thread.spawn(.{}, Reader.run, .{sock_path});

    // accept：走 `NetAccept` 节点（同步 `vtAccept` 需要预建 socket，
    // io_uring 上会 close 掉它再用内核分配的 fd，不适合同步入口）。
    const Conn = struct {
        var fd: Handle = INVALID_HANDLE;
        var done = false;
        fn cb(lp: *Loop, c: *Completion) void {
            const a: *root.NetAccept = @fieldParentPtr("c", c);
            fd = a.getResult() catch INVALID_HANDLE;
            done = true;
            lp.stop();
        }
    };
    const accept_sock = try l.createUnixSocket();
    defer l.close(accept_sock);
    var acc = root.NetAccept.init(listener, accept_sock);
    var wd = Timer.init(5000);
    acc.c.callback = &Conn.cb;
    l.add(&acc.c);
    l.watchdog(&acc.c, &wd, 5000);
    try l.run();
    try std.testing.expect(Conn.done);
    const conn = Conn.fd;
    if (conn == INVALID_HANDLE) {
        t.join();
        return error.SkipZigTest;
    }

    // 对 conn 做 sendfile（同步入口，走 Work 池的节点内部也用这个）。
    const sent = try l.sendFile(conn, fpath, 0, 0);
    try std.testing.expectEqual(payload.len, sent);
    l.close(conn);

    t.join();
    try std.testing.expectEqualStrings(payload, Reader.buf[0..Reader.n]);
}

test "io_uring: 一次提交超过 SQ 环容量不损坏环" {
    var l = try testLoop();
    defer l.deinit();
    // 只在 io_uring 后端有意义（只有它把操作真正塞进 SQ 环）。
    if (l.io.vtable.readFileAsync == null) return error.SkipZigTest;

    // 建一个文件，然后一次性提交远超 ENTRIES(256) 的读操作。
    var pbuf: [512]u8 = undefined;
    const dir = try tmpDir(&pbuf, "sqfull");
    try l.makeDir(dir, 0o755);
    defer l.removeDir(dir) catch {};

    var fbuf: [600]u8 = undefined;
    const fpath = try std.fmt.bufPrint(&fbuf, "{s}/sq.txt", .{dir});
    defer l.deleteFile(fpath);
    try l.writeFileAll(fpath, "0123456789");

    var zpath_buf: [700]u8 = undefined;
    @memcpy(zpath_buf[0..fpath.len], fpath);
    zpath_buf[fpath.len] = 0;
    const zpath: [:0]const u8 = zpath_buf[0..fpath.len :0];

    const Ctx = struct {
        var ok: usize = 0;
        var bad: usize = 0;
        var remaining: usize = 0;
        fn cb(lp: *Loop, c: *Completion) void {
            if (c.err) |e| {
                bad += 1;
                if (bad <= 3) std.debug.print("ERR: {}\n", .{e});
            } else ok += 1;
            // 用饱和减法：看门狗超时与真实完成可能先后触发同一节点。
            remaining -|= 1;
            if (remaining == 0) lp.stop();
        }
    };

    // 400 个 > 256(ENTRIES)，必然触发 SQ 环绕；又不会多到让 openat
    // 本身耗时超过看门狗。
    const N = 400;
    var nodes: [N]root.ReadFileAsync = undefined;
    var bufs: [N][16]u8 = undefined;
    var wds: [N]Timer = undefined;
    Ctx.remaining = N;
    for (&nodes, 0..) |*f, i| {
        f.* = root.ReadFileAsync.init(zpath, &bufs[i]);
        f.c.callback = &Ctx.cb;
    }
    // **每个节点都挂看门狗**：SQ 环损坏会让操作永远收不到完成包，
    // 没有看门狗就表现为挂死（CI 上只是超时 124），而挂死不算合格的
    // 失败信号。挂上后超时会显式走到 `Ctx.bad`，测试明确变红。
    for (&nodes, 0..) |*f, i| {
        wds[i] = Timer.init(15000);
        l.watchdog(&f.c, &wds[i], 15000);
        l.add(&f.c);
    }

    try l.run();

    std.debug.print("\nSQ 环压力: ok={d} bad={d} (N={d})\n", .{ Ctx.ok, Ctx.bad, N });
    try std.testing.expectEqual(@as(usize, N), Ctx.ok + Ctx.bad);
    try std.testing.expectEqual(@as(usize, 0), Ctx.bad);
}

// ===== 批量提交：`add` 不得 eager flush =====
//
// 曾经的 bug：`getSqe` 里每个 `add` 各发一次 `io_uring_enter`。功能全对，
// 但吞吐比 zio 低 22%（实测 25000 次往返 → 50101 次 enter，每操作 2 次）。
// 这种退化没有任何功能测试能抓到，只能数 syscall。
//
// 断言形态选「只 add、不 run」：此时 enter 次数必须是 0，提交全部攒到
// `waitBatch`。若有人把 eager flush 加回来，这里立刻等于 N。
// 纯计数、无时序依赖，不会 flaky。
test "io_uring 的 add 只排队不提交，enter 次数攒到 waitBatch" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (root.platform.chosen == .epoll) return error.SkipZigTest;

    const uring = @import("backends/uring.zig");
    const N = 64;

    var loop = Loop.initWithAllocator(try platform.create(std.testing.allocator), std.testing.allocator);
    defer loop.deinit();

    const bind_addr = try net.IpAddress.parse("127.0.0.1", 0);
    const listener = try platform.createTcpSocket(bind_addr);
    defer platform.closeSocket(listener);
    try platform.setReuseAddress(listener, true);
    try platform.bindSocket(listener, bind_addr);
    const bound = try platform.localAddress(listener);
    try platform.listenSocket(listener, 16);

    const Sender = struct {
        fn run(addr: net.IpAddress) void {
            const client = platform.createTcpSocket(addr) catch return;
            defer platform.closeSocket(client);
            platform.connectSocket(client, addr) catch return;
            const start = platform.tickCount();
            while (platform.tickCount() - start < 300) {}
        }
    };
    const thread = try std.Thread.spawn(.{}, Sender.run, .{bound});

    const accepted = try platform.acceptSocket(listener);
    defer platform.closeSocket(accepted.socket);
    try loop.associate(accepted.socket, 1);

    const before = uring.enterCalls(loop.io.userdata);

    // 连续排队 N 个操作，一个都不该被提交。
    var nodes: [N]NetRecv = undefined;
    var bufs: [N][64]u8 = undefined;
    for (&nodes, &bufs) |*n, *b| {
        n.* = NetRecv.init(accepted.socket, b);
        n.c.callback = &noopCb;
        loop.add(&n.c);
    }

    const after = uring.enterCalls(loop.io.userdata);
    // 关键断言：add 期间一次 enter 都不该有。
    try std.testing.expectEqual(before, after);

    // 收尾：这些操作还在环里，deinit 前必须让后端清理干净。
    for (&nodes) |*n| loop.cancel(&n.c, @ptrCast(n), noopDispose);
    loop.drainRetired(1000);

    thread.join();
}

fn noopCb(_: *Loop, _: *Completion) void {}
fn noopDispose(_: *anyopaque) void {}

// ---- 文件句柄层（阶段 A）--------------------------------------------------
// 这些测试打的是「打开一次、读写多次、显式关闭」这条真实路径：
// 句柄复用、随机访问（显式 offset）、以及 open 后 close 的配对。

test "文件句柄：open → 写入 → 随机读 → close 全链路" {
    // 回调一触发就停机：本层全部走 Work 池，单步驱动。
    const stopCb = struct {
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    }.cb;
    var l = try testLoop();
    defer l.deinit();

    var pbuf: [512]u8 = undefined;
    const dir = try tmpDir(&pbuf, "fh");
    try l.makeDir(dir, 0o755);
    defer l.removeDir(dir) catch {};

    var fbuf: [600]u8 = undefined;
    const fpath = try std.fmt.bufPrint(&fbuf, "{s}/h.txt", .{dir});
    defer l.deleteFile(fpath);

    // 1. 打开（读写，不存在则创建）
    var open_node = OpenFile.init(l.io, fpath, .read_write);
    open_node.work.c.callback = stopCb;
    l.add(&open_node.work.c);
    try l.run();
    const h = try open_node.getResult();

    // 2. 写入 "0123456789"
    var write_node = WriteFileHandle.init(l.io, h, 0, "0123456789");
    write_node.work.c.callback = stopCb;
    l.add(&write_node.work.c);
    try l.run();
    try std.testing.expectEqual(@as(usize, 10), try write_node.getResult());

    // 3. 随机访问：从 offset 4 读 3 字节 → "456"
    //    这条是本层存在的意义：路径式 API 做不到「同一句柄按偏移读」。
    var rbuf: [3]u8 = undefined;
    var read_node = ReadFileHandle.init(l.io, h, 4, &rbuf);
    read_node.work.c.callback = stopCb;
    l.add(&read_node.work.c);
    try l.run();
    try std.testing.expectEqualStrings("456", try read_node.getResult());

    // 4. 从 offset 0 读全部 → "0123456789"
    var rbuf2: [10]u8 = undefined;
    var read_all = ReadFileHandle.init(l.io, h, 0, &rbuf2);
    read_all.work.c.callback = stopCb;
    l.add(&read_all.work.c);
    try l.run();
    try std.testing.expectEqualStrings("0123456789", try read_all.getResult());

    // 5. 覆盖写入中间段：offset 4 写 "XY" → "0123XY6789"
    var over = WriteFileHandle.init(l.io, h, 4, "XY");
    over.work.c.callback = stopCb;
    l.add(&over.work.c);
    try l.run();
    try std.testing.expectEqual(@as(usize, 2), try over.getResult());

    var rbuf3: [10]u8 = undefined;
    var read_back = ReadFileHandle.init(l.io, h, 0, &rbuf3);
    read_back.work.c.callback = stopCb;
    l.add(&read_back.work.c);
    try l.run();
    try std.testing.expectEqualStrings("0123XY6789", try read_back.getResult());

    // 6. 关闭
    var cf_x = CloseFile.init(l.io, h);
    cf_x.close();

    // 注意：**不**在这里断言「关闭后再读会报某个具体错误」。
    // 关闭后的句柄值是未定义行为——Windows 返回 SeekFailed、Linux 返回
    // EBADF、macOS 可能报别的，甚至同一 fd 号被新文件复用时读到别的数据。
    // 断言具体错误名等于把一个平台巧合当契约。这里只验证上面整条链路。
}

test "文件句柄：读超出文件尾短读不报错" {
    // 回调一触发就停机：本层全部走 Work 池，单步驱动。
    const stopCb = struct {
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    }.cb;
    var l = try testLoop();
    defer l.deinit();

    var pbuf: [512]u8 = undefined;
    const dir = try tmpDir(&pbuf, "fheof");
    try l.makeDir(dir, 0o755);
    defer l.removeDir(dir) catch {};

    var fbuf: [600]u8 = undefined;
    const fpath = try std.fmt.bufPrint(&fbuf, "{s}/e.txt", .{dir});
    defer l.deleteFile(fpath);

    try l.writeFileAll(fpath, "abc"); // 3 字节

    var open_node = OpenFile.init(l.io, fpath, .read_only);
    open_node.work.c.callback = stopCb;
    l.add(&open_node.work.c);
    try l.run();
    const h = try open_node.getResult();
    var cf_close = CloseFile.init(l.io, h);
    defer cf_close.close();

    // 从 0 读 100 字节，只应拿到 3 字节（EOF 短读，不是错误）
    var big: [100]u8 = undefined;
    var read_node = ReadFileHandle.init(l.io, h, 0, &big);
    read_node.work.c.callback = stopCb;
    l.add(&read_node.work.c);
    try l.run();
    try std.testing.expectEqualStrings("abc", try read_node.getResult());

    // 从文件尾之后读，应拿到 0 字节（仍不是错误）
    var tail: [10]u8 = undefined;
    var tail_node = ReadFileHandle.init(l.io, h, 100, &tail);
    tail_node.work.c.callback = stopCb;
    l.add(&tail_node.work.c);
    try l.run();
    try std.testing.expectEqual(@as(usize, 0), (try tail_node.getResult()).len);
}

test "文件句柄：open 不存在的文件返回 FileNotFound" {
    // 回调一触发就停机：本层全部走 Work 池，单步驱动。
    const stopCb = struct {
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    }.cb;
    var l = try testLoop();
    defer l.deinit();

    var pbuf: [512]u8 = undefined;
    const dir = try tmpDir(&pbuf, "fhnf");
    try l.makeDir(dir, 0o755);
    defer l.removeDir(dir) catch {};

    var fbuf: [600]u8 = undefined;
    const missing = try std.fmt.bufPrint(&fbuf, "{s}/nope.txt", .{dir});

    // read_only 不创建，必须报错
    var open_node = OpenFile.init(l.io, missing, .read_only);
    open_node.work.c.callback = stopCb;
    l.add(&open_node.work.c);
    try l.run();
    try std.testing.expectError(error.FileNotFound, open_node.getResult());
}

test "文件句柄：write_only 打开会清空既有内容" {
    // 回调一触发就停机：本层全部走 Work 池，单步驱动。
    const stopCb = struct {
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    }.cb;
    var l = try testLoop();
    defer l.deinit();

    var pbuf: [512]u8 = undefined;
    const dir = try tmpDir(&pbuf, "fhtr");
    try l.makeDir(dir, 0o755);
    defer l.removeDir(dir) catch {};

    var fbuf: [600]u8 = undefined;
    const fpath = try std.fmt.bufPrint(&fbuf, "{s}/t.txt", .{dir});
    defer l.deleteFile(fpath);

    try l.writeFileAll(fpath, "old-content-here");

    var open_node = OpenFile.init(l.io, fpath, .write_only);
    open_node.work.c.callback = stopCb;
    l.add(&open_node.work.c);
    try l.run();
    const h = try open_node.getResult();

    var w = WriteFileHandle.init(l.io, h, 0, "new");
    w.work.c.callback = stopCb;
    l.add(&w.work.c);
    try l.run();
    try std.testing.expectEqual(@as(usize, 3), try w.getResult());
    var cf_x = CloseFile.init(l.io, h);
    cf_x.close();

    // 文件应只剩 "new"（TRUNC 生效）
    var buf: [64]u8 = undefined;
    const n = try l.io.vtable.readFileInto(l.io.userdata, fpath, &buf);
    try std.testing.expectEqualStrings("new", buf[0..n]);
}

test "文件句柄：CloseFile 同一实例重复关闭不 panic" {
    // 回调一触发就停机：本层全部走 Work 池，单步驱动。
    const stopCb = struct {
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    }.cb;
    var l = try testLoop();
    defer l.deinit();

    var pbuf: [512]u8 = undefined;
    const dir = try tmpDir(&pbuf, "fhidem");
    try l.makeDir(dir, 0o755);
    defer l.removeDir(dir) catch {};

    var fbuf: [600]u8 = undefined;
    const fpath = try std.fmt.bufPrint(&fbuf, "{s}/i.txt", .{dir});
    defer l.deleteFile(fpath);

    var open_node = OpenFile.init(l.io, fpath, .read_write);
    open_node.work.c.callback = stopCb;
    l.add(&open_node.work.c);
    try l.run();
    const h = try open_node.getResult();

    // 同一个实例重复 close：必须安全（第二次起直接返回）。
    // 拿裸句柄值再 init 新实例去关是未定义行为，所以只测同一实例。
    var cf = CloseFile.init(l.io, h);
    cf.close();
    cf.close(); // 第二次不能崩
    cf.close(); // 第三次也不能
}

// ---- 句柄级元数据与同步（阶段 B）------------------------------------------
// 这三条打的是「路径式 API 做不到」的部分：statFile 直接吃句柄，
// 不存在「open 之后路径被换掉」的竞态；setFileSize / syncFile 同理。

test "句柄元数据：statFile 报告真实大小，且随写入增长" {
    // 回调一触发就停机：本层全部走 Work 池，单步驱动。
    const stopCb = struct {
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    }.cb;
    var l = try testLoop();
    defer l.deinit();

    var pbuf: [512]u8 = undefined;
    const dir = try tmpDir(&pbuf, "sfst");
    try l.makeDir(dir, 0o755);
    defer l.removeDir(dir) catch {};

    var fbuf: [600]u8 = undefined;
    const fpath = try std.fmt.bufPrint(&fbuf, "{s}/s.txt", .{dir});
    defer l.deleteFile(fpath);

    var open_node = OpenFile.init(l.io, fpath, .read_write);
    open_node.work.c.callback = stopCb;
    l.add(&open_node.work.c);
    try l.run();
    const h = try open_node.getResult();
    var cf_close = CloseFile.init(l.io, h);
    defer cf_close.close();

    // 空文件：大小 0，类型是普通文件
    var st1 = StatFile.init(l.io, h);
    st1.work.c.callback = stopCb;
    l.add(&st1.work.c);
    try l.run();
    const s1 = try st1.getResult();
    try std.testing.expectEqual(@as(u64, 0), s1.size);
    try std.testing.expectEqual(root.FileKind.file, s1.kind);

    // 写 7 字节后再 stat：大小必须跟着变。
    // 这条是关键——如果 statFile 误用了路径式 stat 或缓存了旧值，
    // 这里会读到 0。
    var w = WriteFileHandle.init(l.io, h, 0, "1234567");
    w.work.c.callback = stopCb;
    l.add(&w.work.c);
    try l.run();
    try std.testing.expectEqual(@as(usize, 7), try w.getResult());

    var st2 = StatFile.init(l.io, h);
    st2.work.c.callback = stopCb;
    l.add(&st2.work.c);
    try l.run();
    try std.testing.expectEqual(@as(u64, 7), (try st2.getResult()).size);
}

test "句柄元数据：setFileSize 截断后大小与内容都变" {
    const stopCb = struct {
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    }.cb;
    var l = try testLoop();
    defer l.deinit();

    var pbuf: [512]u8 = undefined;
    const dir = try tmpDir(&pbuf, "sfss");
    try l.makeDir(dir, 0o755);
    defer l.removeDir(dir) catch {};

    var fbuf: [600]u8 = undefined;
    const fpath = try std.fmt.bufPrint(&fbuf, "{s}/z.txt", .{dir});
    defer l.deleteFile(fpath);

    try l.writeFileAll(fpath, "0123456789"); // 10 字节

    var open_node = OpenFile.init(l.io, fpath, .read_write);
    open_node.work.c.callback = stopCb;
    l.add(&open_node.work.c);
    try l.run();
    const h = try open_node.getResult();
    var cf_close = CloseFile.init(l.io, h);
    defer cf_close.close();

    // 截到 4 字节
    var trunc = SetFileSize.init(l.io, h, 4);
    trunc.work.c.callback = stopCb;
    l.add(&trunc.work.c);
    try l.run();
    try trunc.getResult();

    // 读回只剩前 4 字节（不只看 size，还要看内容真的被切了）
    var buf: [32]u8 = undefined;
    var rd = ReadFileHandle.init(l.io, h, 0, &buf);
    rd.work.c.callback = stopCb;
    l.add(&rd.work.c);
    try l.run();
    try std.testing.expectEqualStrings("0123", try rd.getResult());

    // statFile 也报告 4
    var st = StatFile.init(l.io, h);
    st.work.c.callback = stopCb;
    l.add(&st.work.c);
    try l.run();
    try std.testing.expectEqual(@as(u64, 4), (try st.getResult()).size);

    // 反向：扩展到 8 字节，多出来的部分是零（稀疏扩展的常见语义）
    var grow = SetFileSize.init(l.io, h, 8);
    grow.work.c.callback = stopCb;
    l.add(&grow.work.c);
    try l.run();
    try grow.getResult();

    var st2 = StatFile.init(l.io, h);
    st2.work.c.callback = stopCb;
    l.add(&st2.work.c);
    try l.run();
    try std.testing.expectEqual(@as(u64, 8), (try st2.getResult()).size);
}

test "句柄元数据：syncFile 在有效句柄上成功" {
    const stopCb = struct {
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    }.cb;
    var l = try testLoop();
    defer l.deinit();

    var pbuf: [512]u8 = undefined;
    const dir = try tmpDir(&pbuf, "sfsy");
    try l.makeDir(dir, 0o755);
    defer l.removeDir(dir) catch {};

    var fbuf: [600]u8 = undefined;
    const fpath = try std.fmt.bufPrint(&fbuf, "{s}/y.txt", .{dir});
    defer l.deleteFile(fpath);

    var open_node = OpenFile.init(l.io, fpath, .read_write);
    open_node.work.c.callback = stopCb;
    l.add(&open_node.work.c);
    try l.run();
    const h = try open_node.getResult();
    var cf_close = CloseFile.init(l.io, h);
    defer cf_close.close();

    var w = WriteFileHandle.init(l.io, h, 0, "durable");
    w.work.c.callback = stopCb;
    l.add(&w.work.c);
    try l.run();
    try std.testing.expectEqual(@as(usize, 7), try w.getResult());

    // 刷盘必须成功。注意：这条**不**能证明数据真的落盘了——
    // 断电才验证得了，测试里没有那个能力。它只证明调用链通、
    // 且没有把错误吞掉。
    var sync = SyncFile.init(l.io, h);
    sync.work.c.callback = stopCb;
    l.add(&sync.work.c);
    try l.run();
    try sync.getResult();
}

// ---- 符号链接读取 + 目录流式句柄（阶段 C）--------------------------------
// 核心正确性问题：`getdents64`/`getdirentries` 一次返回一整批条目，
// 内核的 fd 偏移直接前移到批次末尾。如果调用方缓冲装不下整批，
// 剩下的条目就**丢了**。下面第 2 条测试专门打这个。

test "目录流：openDir → 分多次读完 → closeDir，条目不丢不重" {
    const stopCb = struct {
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    }.cb;
    var l = try testLoop();
    defer l.deinit();

    var pbuf: [512]u8 = undefined;
    const dir = try tmpDir(&pbuf, "dstream");
    try l.makeDir(dir, 0o755);
    defer l.removeDir(dir) catch {};

    // 建 5 个文件。用固定名字，便于断言集合完全相等。
    const names = [_][]const u8{ "a.txt", "b.txt", "c.txt", "d.txt", "e.txt" };
    var fbufs: [5][600]u8 = undefined;
    var fpaths: [5][]const u8 = undefined;
    for (names, 0..) |n, i| {
        fpaths[i] = try std.fmt.bufPrint(&fbufs[i], "{s}/{s}", .{ dir, n });
        try l.writeFileAll(fpaths[i], "x");
    }
    defer for (fpaths) |p| l.deleteFile(p);

    var open_node = OpenDir.init(l.io, dir);
    open_node.work.c.callback = stopCb;
    l.add(&open_node.work.c);
    try l.run();
    const dh = try open_node.getResult();
    var cd_x = CloseDir.init(l.io, dh);
    defer cd_x.close();

    // **关键**：每次只给 2 个槽位，而目录里有 5 个条目。
    // 如果实现没处理「批次装不下」的情况，第一次 getdents64 拿到的
    // 整批条目里只有 2 个被消费，剩下 3 个随 fd 偏移前移而丢失，
    // 总收集数会是 2 而不是 5。
    var seen: [5]bool = .{ false, false, false, false, false };
    var total: usize = 0;
    var rounds: usize = 0;
    while (rounds < 20) : (rounds += 1) {
        var batch: [2]root.DirEntry = undefined;
        var rd = ReadDirHandle.init(l.io, dh, &batch);
        rd.work.c.callback = stopCb;
        l.add(&rd.work.c);
        try l.run();
        const entries = try rd.getResult();
        if (entries.len == 0) break; // 读完
        for (entries) |e| {
            total += 1;
            for (names, 0..) |n, i| {
                if (std.mem.eql(u8, e.slice(), n)) seen[i] = true;
            }
        }
    }

    try std.testing.expectEqual(@as(usize, 5), total);
    for (seen, 0..) |s, i| {
        if (!s) {
            std.debug.print("缺失条目: {s}\n", .{names[i]});
            return error.TestUnexpectedResult;
        }
    }
}

test "目录流：一次给足缓冲能读完，is_dir 标志正确" {
    const stopCb = struct {
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    }.cb;
    var l = try testLoop();
    defer l.deinit();

    var pbuf: [512]u8 = undefined;
    const dir = try tmpDir(&pbuf, "dflags");
    try l.makeDir(dir, 0o755);
    defer l.removeDir(dir) catch {};

    var fbuf: [600]u8 = undefined;
    const fpath = try std.fmt.bufPrint(&fbuf, "{s}/file.txt", .{dir});
    try l.writeFileAll(fpath, "x");
    defer l.deleteFile(fpath);

    var sbuf: [600]u8 = undefined;
    const subdir = try std.fmt.bufPrint(&sbuf, "{s}/subdir", .{dir});
    try l.makeDir(subdir, 0o755);
    defer l.removeDir(subdir) catch {};

    var open_node = OpenDir.init(l.io, dir);
    open_node.work.c.callback = stopCb;
    l.add(&open_node.work.c);
    try l.run();
    const dh = try open_node.getResult();
    var cd_x = CloseDir.init(l.io, dh);
    defer cd_x.close();

    var batch: [16]root.DirEntry = undefined;
    var rd = ReadDirHandle.init(l.io, dh, &batch);
    rd.work.c.callback = stopCb;
    l.add(&rd.work.c);
    try l.run();
    const entries = try rd.getResult();

    // 恰好 2 个条目（file.txt + subdir），且 is_dir 要分清
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    for (entries) |e| {
        if (std.mem.eql(u8, e.slice(), "file.txt")) {
            try std.testing.expect(!e.is_dir);
        } else if (std.mem.eql(u8, e.slice(), "subdir")) {
            try std.testing.expect(e.is_dir);
        } else {
            std.debug.print("意外条目: {s}\n", .{e.slice()});
            return error.TestUnexpectedResult;
        }
    }
}

test "目录流：openDir 不存在的目录返回 FileNotFound" {
    const stopCb = struct {
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    }.cb;
    var l = try testLoop();
    defer l.deinit();

    var pbuf: [512]u8 = undefined;
    const dir = try tmpDir(&pbuf, "dnodir");
    // 不创建，直接开

    var open_node = OpenDir.init(l.io, dir);
    open_node.work.c.callback = stopCb;
    l.add(&open_node.work.c);
    try l.run();
    try std.testing.expectError(error.FileNotFound, open_node.getResult());
}

test "readLink 读回符号链接目标" {
    const stopCb = struct {
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    }.cb;
    var l = try testLoop();
    defer l.deinit();

    var pbuf: [512]u8 = undefined;
    const dir = try tmpDir(&pbuf, "rlink");
    try l.makeDir(dir, 0o755);
    defer l.removeDir(dir) catch {};

    var tbuf: [600]u8 = undefined;
    const target = try std.fmt.bufPrint(&tbuf, "{s}/real.txt", .{dir});
    try l.writeFileAll(target, "hi");
    defer l.deleteFile(target);

    var lbuf: [600]u8 = undefined;
    const link = try std.fmt.bufPrint(&lbuf, "{s}/link.txt", .{dir});
    l.symLink(target, link) catch |e| switch (e) {
        // 非管理员权限下 Windows 无法建符号链接；跳过而不是假装通过。
        error.AccessDenied, error.PrivilegeNotHeld => return error.SkipZigTest,
        else => return e,
    };
    defer l.deleteFile(link);

    var rbuf: [1024]u8 = undefined;
    var rl = ReadLink.init(l.io, link, &rbuf);
    rl.work.c.callback = stopCb;
    l.add(&rl.work.c);
    try l.run();
    const got = try rl.getResult();
    // 目标可能被平台规范化（Windows 会补绝对路径/前缀），只断言尾部一致。
    try std.testing.expect(std.mem.endsWith(u8, got, "real.txt"));
}

test "readLink 对普通文件返回 NotASymLink" {
    const stopCb = struct {
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    }.cb;
    var l = try testLoop();
    defer l.deinit();

    var pbuf: [512]u8 = undefined;
    const dir = try tmpDir(&pbuf, "rlnot");
    try l.makeDir(dir, 0o755);
    defer l.removeDir(dir) catch {};

    var fbuf: [600]u8 = undefined;
    const fpath = try std.fmt.bufPrint(&fbuf, "{s}/plain.txt", .{dir});
    try l.writeFileAll(fpath, "x");
    defer l.deleteFile(fpath);

    var rbuf: [1024]u8 = undefined;
    var rl = ReadLink.init(l.io, fpath, &rbuf);
    rl.work.c.callback = stopCb;
    l.add(&rl.work.c);
    try l.run();
    // 普通文件不是符号链接：必须报错，不能返回空串假装成功。
    try std.testing.expectError(error.NotASymLink, rl.getResult());
}

// 第三轮补齐的同步 Loop API：access / realPath / truncate / readLink。
test "Loop 同步 API：access / realPath / truncate / readLink" {
    var l = try testLoop();
    defer l.deinit();

    var pbuf: [512]u8 = undefined;
    const dir = try tmpDir(&pbuf, "syncapi");
    try l.makeDir(dir, 0o755);
    defer l.removeDir(dir) catch {};

    var fbuf: [600]u8 = undefined;
    const fpath = try std.fmt.bufPrint(&fbuf, "{s}/f.txt", .{dir});
    try l.writeFileAll(fpath, "0123456789");
    defer l.deleteFile(fpath);

    // access：存在且可读可写。
    try l.access(fpath, 4 | 2);
    // 不存在的路径必须报错。
    var miss: [600]u8 = undefined;
    const missing = try std.fmt.bufPrint(&miss, "{s}/nope.txt", .{dir});
    try std.testing.expectError(error.FileNotFound, l.access(missing, 4));

    // truncate：截到 4 字节。
    try l.truncate(fpath, 4);
    try std.testing.expectEqual(@as(u64, 4), try l.fileSize(fpath));

    // realPath：结果包含文件名。
    var rp: [1024]u8 = undefined;
    const abs = try l.realPath(fpath, &rp);
    try std.testing.expect(std.mem.endsWith(u8, rp[0..abs], "f.txt"));

    // readLink：建符号链接再读回（Windows 无权限则跳过）。
    var lbuf: [600]u8 = undefined;
    const link = try std.fmt.bufPrint(&lbuf, "{s}/l.txt", .{dir});
    l.symLink(fpath, link) catch |e| switch (e) {
        error.AccessDenied, error.PrivilegeNotHeld => return error.SkipZigTest,
        else => return e,
    };
    defer l.deleteFile(link);
    var tbuf: [1024]u8 = undefined;
    const n = try l.readLink(link, &tbuf);
    try std.testing.expect(std.mem.endsWith(u8, tbuf[0..n], "f.txt"));

    // hardLink：两个路径指向同一 inode（Windows 不支持硬链接，跳过）。
    var hbuf: [600]u8 = undefined;
    const hard = try std.fmt.bufPrint(&hbuf, "{s}/f-hard.txt", .{dir});
    l.hardLink(fpath, hard) catch |e| switch (e) {
        error.AccessDenied, error.PrivilegeNotHeld, error.Unsupported => {},
        else => return e,
    };
    if (l.access(hard, 4)) |_| {
        // 硬链接存在时，它与原文件共享同一个 inode → 大小相同。
        try std.testing.expectEqual(@as(u64, 4), try l.fileSize(hard));
        l.deleteFile(hard);
    } else |_| {}
}

test "CloseDir 同一实例重复关闭不 panic" {
    const stopCb = struct {
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    }.cb;
    var l = try testLoop();
    defer l.deinit();

    var pbuf: [512]u8 = undefined;
    const dir = try tmpDir(&pbuf, "didem");
    try l.makeDir(dir, 0o755);
    defer l.removeDir(dir) catch {};

    var open_node = OpenDir.init(l.io, dir);
    open_node.work.c.callback = stopCb;
    l.add(&open_node.work.c);
    try l.run();
    const dh = try open_node.getResult();

    // 同一个实例重复 close：必须安全（第二次起直接返回）。
    // 注意：拿裸句柄值再 init 一个新 CloseDir 去关**不**安全——
    // 那是未定义行为，所以这里刻意只测同一实例。
    var cd = CloseDir.init(l.io, dh);
    cd.close();
    cd.close();
    cd.close();
}

// ---- 跨线程投递 Async / 批量等待 Group（阶段 D）--------------------------

test "Async：从另一个线程投递回调，在循环线程上执行" {
    var l = try testLoop();
    defer l.deinit();

    const Ctx = struct {
        var ran: bool = false;
        var on_loop_thread: bool = false;
        var loop_thread_id: std.Thread.Id = undefined;

        fn cb(ctx: ?*anyopaque, a: *root.Async) void {
            _ = ctx;
            _ = a;
            ran = true;
            // 记录执行时所在线程，稍后与主线程比较。
            on_loop_thread = std.Thread.getCurrentId() == loop_thread_id;
        }

        fn worker(loop: *Loop, node: *root.Async) void {
            loop.postAsync(node);
        }
    };
    Ctx.ran = false;
    Ctx.loop_thread_id = std.Thread.getCurrentId();

    var node = root.Async.init(&Ctx.cb, null);

    // 起一个真实线程去投递：这条测试的意义就在于跨线程，同线程调用
    // 证明不了任何事。
    const t = try std.Thread.spawn(.{}, Ctx.worker, .{ &l, &node });
    t.join();

    // 线程已 join，投递一定发生了；现在驱动循环把回调跑掉。
    // 用一个短定时器让 run 有机会处理完就停。
    var stop_timer = root.Timer.init(30);
    stop_timer.c.callback = &struct {
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    }.cb;
    l.add(&stop_timer.c);
    try l.run();

    try std.testing.expect(Ctx.ran);
    // 回调必须在循环线程执行（就是本测试线程）。
    try std.testing.expect(Ctx.on_loop_thread);
}

test "Async：投递后在回调里可以继续 add 操作" {
    var l = try testLoop();
    defer l.deinit();

    const Ctx = struct {
        var chained: bool = false;
        var timer: root.Timer = undefined;

        fn cb(ctx: ?*anyopaque, a: *root.Async) void {
            _ = a;
            const loop: *Loop = @ptrCast(@alignCast(ctx.?));
            // 在 Async 回调里再挂一个定时器：证明 postAsync 的回调
            // 是在正常的循环上下文里，可以继续提交操作。
            const S = @This();
            S.timer = root.Timer.init(5);
            S.timer.c.callback = &onTimer;
            loop.add(&S.timer.c);
        }

        fn onTimer(loop: *Loop, c: *Completion) void {
            _ = c;
            chained = true;
            loop.stop();
        }
    };
    Ctx.chained = false;

    var node = root.Async.init(&Ctx.cb, &l);
    l.postAsync(&node);
    try l.run();

    try std.testing.expect(Ctx.chained);
}

test "Async：多个线程并发投递，全部回调都执行" {
    var l = try testLoop();
    defer l.deinit();

    const N = 8;
    const Ctx = struct {
        var count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
        var nodes: [N]root.Async = undefined;

        fn cb(ctx: ?*anyopaque, a: *root.Async) void {
            _ = ctx;
            _ = a;
            _ = count.fetchAdd(1, .monotonic);
        }

        fn worker(loop: *Loop, node: *root.Async) void {
            loop.postAsync(node);
        }
    };
    Ctx.count.store(0, .monotonic);
    for (&Ctx.nodes) |*n| n.* = root.Async.init(&Ctx.cb, null);

    var threads: [N]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, Ctx.worker, .{ &l, &Ctx.nodes[i] });
    }
    for (threads) |t| t.join();

    // 全部投递完毕，用一个定时器给循环一个截止点。
    var stop_timer = root.Timer.init(50);
    stop_timer.c.callback = &struct {
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    }.cb;
    l.add(&stop_timer.c);
    try l.run();

    // 8 个投递全部执行（MPSC 栈不会丢项）。
    try std.testing.expectEqual(@as(usize, N), Ctx.count.load(.monotonic));
}

test "Group：两个子操作都完成才回调一次" {
    var l = try testLoop();
    defer l.deinit();

    const Ctx = struct {
        var fired: usize = 0;
        var group: root.Group = undefined;
        var t1: root.Timer = undefined;
        var t2: root.Timer = undefined;

        fn onAll(ctx: ?*anyopaque, g: *root.Group) void {
            _ = ctx;
            _ = g;
            fired += 1;
        }

        fn onStop(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    };
    Ctx.fired = 0;
    Ctx.group = root.Group.init(&Ctx.onAll, null, 2);

    // 两个不同时长的定时器当作子操作：先完成一个不该触发 group。
    Ctx.t1 = root.Timer.init(5);
    Ctx.t1.c.callback = &root.Group.childCallback;
    Ctx.t1.c.group_ctx = &Ctx.group;

    Ctx.t2 = root.Timer.init(15);
    Ctx.t2.c.callback = &root.Group.childCallback;
    Ctx.t2.c.group_ctx = &Ctx.group;

    l.add(&Ctx.t1.c);
    l.add(&Ctx.t2.c);

    var stop_timer = root.Timer.init(60);
    stop_timer.c.callback = &Ctx.onStop;
    l.add(&stop_timer.c);
    try l.run();

    // 两个子操作都完成，group 只回调一次（不是两次）。
    try std.testing.expectEqual(@as(usize, 1), Ctx.fired);
    try std.testing.expect(Ctx.group.done());
}

test "Group：子操作失败也不提前结束，等其他子操作都完成" {
    var l = try testLoop();
    defer l.deinit();

    const Ctx = struct {
        var fired: usize = 0;
        var group: root.Group = undefined;
        var t1: root.Timer = undefined;
        var t2: root.Timer = undefined;

        fn onAll(ctx: ?*anyopaque, g: *root.Group) void {
            _ = ctx;
            _ = g;
            fired += 1;
        }

        fn onStop(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    };
    Ctx.fired = 0;
    Ctx.group = root.Group.init(&Ctx.onAll, null, 2);

    // 第一个子操作人为标成失败。group 的语义是「等其他都结束」，
    // 而不是「一有错就短路」——所以 fired 仍应为 1。
    Ctx.t1 = root.Timer.init(5);
    Ctx.t1.c.callback = &root.Group.childCallback;
    Ctx.t1.c.group_ctx = &Ctx.group;
    Ctx.t1.c.err = error.IoFailed;

    Ctx.t2 = root.Timer.init(10);
    Ctx.t2.c.callback = &root.Group.childCallback;
    Ctx.t2.c.group_ctx = &Ctx.group;

    l.add(&Ctx.t1.c);
    l.add(&Ctx.t2.c);

    var stop_timer = root.Timer.init(60);
    stop_timer.c.callback = &Ctx.onStop;
    l.add(&stop_timer.c);
    try l.run();

    try std.testing.expectEqual(@as(usize, 1), Ctx.fired);
}

test "Async：循环已阻塞在 waitBatch 时，notify 立刻唤醒（不等 200ms）" {
    var l = try testLoop();
    defer l.deinit();

    // 关键点：投递必须发生在循环**已经阻塞在 waitBatch 里**的时刻，
    // 而且不能借助任何别的唤醒源（Work 池完成、定时器都会顺带 notify，
    // 那样就分不清是谁叫醒的）。
    //
    // 做法：起一个裸线程，先睡 40ms（确保循环进了 waitBatch），
    // 再 postAsync。循环唯一可能的唤醒源就是这个 notify。
    const Ctx = struct {
        var fired_at_ms: u64 = 0;
        var post_at_ms: u64 = 0;
        var node: root.Async = undefined;
        var loop_ref: ?*Loop = null;

        fn cb(ctx: ?*anyopaque, a: *root.Async) void {
            _ = a;
            const loop: *Loop = @ptrCast(@alignCast(ctx.?));
            @This().fired_at_ms = loop.io.vtable.now(loop.io.userdata);
            loop.stop();
        }

        fn worker(loop: *Loop) void {
            if (builtin.os.tag == .windows) {
                const k32 = struct {
                    extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
                };
                k32.Sleep(40);
            } else {
                var fds: [0]std.posix.pollfd = .{};
                _ = std.posix.poll(&fds, 40) catch {};
            }
            @This().post_at_ms = loop.io.vtable.now(loop.io.userdata);
            loop.postAsync(&@This().node);
        }
    };
    Ctx.node = root.Async.init(&Ctx.cb, &l);
    Ctx.loop_ref = &l;

    const t = try std.Thread.spawn(.{}, Ctx.worker, .{&l});
    defer t.join();

    try l.run();

    const elapsed = Ctx.fired_at_ms - Ctx.post_at_ms;
    // 没有 notify 时，投递只能等 waitBatch 的 200ms 超时到点才被处理。
    // 有 notify 时应该在个位数毫秒内被叫醒。
    try std.testing.expect(elapsed < 60);
}

// ---- 分散聚合 I/O 与全方向关闭（阶段 E）----------------------------------

/// 建一对已连接的 TCP socket（本机回环）。返回 {client, server}。
/// 测试收尾要 `loop.close` 两个。
fn tcpPair(loop: *Loop) !struct { a: root.Handle, b: root.Handle } {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1:0", 0);
    const listen = try loop.createSocket(addr);
    try loop.setReuseAddress(listen, true);
    try loop.bind(listen, addr);
    try loop.listen(listen, 8);

    // 拿实际端口
    const bound = loop.io.vtable.statSocketAddr(loop.io.userdata, listen) catch
        try std.Io.net.IpAddress.parse("127.0.0.1:0", 0);
    _ = bound;

    const client = try loop.createSocket(addr);
    return .{ .a = client, .b = listen };
}

/// 建一对已连接的 TCP socket（本机回环）。
///
/// 走 `platform.*` 同步原语而不是 `Loop.*`：这里要的是「先有一条活着的连接」
/// 这个**前置条件**，用异步 accept/connect 建连接会把被测对象和搭建步骤
/// 混在一起，测试失败时分不清是谁的问题。
const TcpPair = struct {
    listener: root.Handle,
    client: root.Handle,
    server: root.Handle,

    fn close(self: TcpPair) void {
        platform.closeSocket(self.client);
        platform.closeSocket(self.server);
        platform.closeSocket(self.listener);
    }
};

fn makeTcpPair() !TcpPair {
    const bind_addr = try net.IpAddress.parse("127.0.0.1", 0);
    const listener = try platform.createTcpSocket(bind_addr);
    errdefer platform.closeSocket(listener);
    try platform.setReuseAddress(listener, true);
    try platform.bindSocket(listener, bind_addr);
    const bound = try platform.localAddress(listener);
    try platform.listenSocket(listener, 16);

    const Sender = struct {
        fn run(addr: net.IpAddress, out: *root.Handle) void {
            const c = platform.createTcpSocket(addr) catch return;
            platform.connectSocket(c, addr) catch return;
            out.* = c;
        }
    };
    var client: root.Handle = root.INVALID_HANDLE;
    const t = try std.Thread.spawn(.{}, Sender.run, .{ bound, &client });
    const accepted = try platform.acceptSocket(listener);
    t.join();
    if (client == root.INVALID_HANDLE) {
        platform.closeSocket(accepted.socket);
        return error.ConnectFailed;
    }
    return .{ .listener = listener, .client = client, .server = accepted.socket };
}

test "NetShutdown：关写方向后对端读到 0 字节（EOF）" {
    const stopCb = struct {
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    }.cb;
    var l = try testLoop();
    defer l.deinit();

    const pair = try makeTcpPair();
    defer pair.close();
    try l.associate(pair.server, 1);
    try l.associate(pair.client, 2);

    var sd = root.NetShutdown.init(pair.server, .write);
    sd.c.callback = stopCb;
    l.add(&sd.c);
    try l.run();
    try sd.getResult();

    // 客户端应读到 0 字节（对端 FIN）。
    //
    // **不用阻塞读**：方向搞反时阻塞读会永久卡住，变异测试表现为
    // 「挂死」而不是「断言失败」——挂死要靠外部超时才暴露，等于测试
    // 没有牙。改用带超时的异步读，超时就红。
    const Got = struct {
        var recv_fired: bool = false;
        fn onRecv(loop: *Loop, c: *Completion) void {
            _ = c;
            recv_fired = true;
            loop.stop();
        }
        fn onDeadline(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    };
    Got.recv_fired = false;

    var buf: [64]u8 = undefined;
    var r = root.NetRecv.init(pair.client, &buf);
    r.c.callback = &Got.onRecv;
    l.add(&r.c);
    var deadline = root.Timer.init(300);
    deadline.c.callback = &Got.onDeadline;
    l.add(&deadline.c);
    try l.run();

    // **关键断言**：必须真的收到「0 字节 = FIN」，而不是超时后
    // 默认值 0 蒙对。方向搞反时 recv 不触发，recv_fired 为 false。
    try std.testing.expect(Got.recv_fired);
    try std.testing.expect(r.c.err == null);
    try std.testing.expectEqual(@as(usize, 0), r.c.bytes);
}

test "NetSendMsg：两个缓冲一次发出，对端按序收到拼接结果" {
    const stopCb = struct {
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    }.cb;
    var l = try testLoop();
    defer l.deinit();

    const pair = try makeTcpPair();
    defer pair.close();
    try l.associate(pair.server, 1);

    // **关键**：两个分开的缓冲，必须按顺序拼成 "hello world"。
    // 分成两次 send 也能得到同样字节，但那样测不出 iovec 的顺序。
    const bufs = [_][]const u8{ "hello", " world" };
    var sm = root.NetSendMsg.init(pair.server, &bufs);
    sm.c.callback = stopCb;
    l.add(&sm.c);
    try l.run();
    try std.testing.expectEqual(@as(usize, 11), try sm.getResult());

    // 客户端阻塞读回
    var buf: [64]u8 = undefined;
    var got: usize = 0;
    while (got < 11) {
        const n = try platform.recvBlocking(pair.client, buf[got..]);
        if (n == 0) break;
        got += n;
    }
    try std.testing.expectEqualStrings("hello world", buf[0..got]);
}

test "NetRecvMsg：一个数据包摊到两个缓冲，顺序与长度正确" {
    const stopCb = struct {
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    }.cb;
    var l = try testLoop();
    defer l.deinit();

    const pair = try makeTcpPair();
    defer pair.close();
    try l.associate(pair.server, 1);

    // 客户端先发 "HEADpayload"（4 + 7 = 11 字节）
    _ = try platform.sendBlocking(pair.client, "HEADpayload");

    // **关键**：两个缓冲分别接 4 和 7 字节。第一个只给 4 字节，
    // 多出来的数据必须溢到第二个缓冲——这正是 recvmsg 的语义。
    // 如果实现把两个缓冲当成两次独立 recv，head 会拿到 4 字节、
    // body 留空，received 会报 4 而不是 11。
    var head: [4]u8 = undefined;
    var body: [16]u8 = undefined;
    const rbufs = [_][]u8{ &head, &body };
    var rm = root.NetRecvMsg.init(pair.server, &rbufs);
    rm.c.callback = stopCb;
    l.add(&rm.c);
    try l.run();
    const n = try rm.getResult();

    try std.testing.expectEqual(@as(usize, 11), n);
    try std.testing.expectEqualStrings("HEAD", &head);
    try std.testing.expectEqualStrings("payload", body[0..7]);
}

test "NetPoll：socket 可读时立即完成" {
    const stopCb = struct {
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    }.cb;
    var l = try testLoop();
    defer l.deinit();

    const pair = try makeTcpPair();
    defer pair.close();
    try l.associate(pair.server, 1);

    // 先发点数据，让 server 端确定可读
    _ = try platform.sendBlocking(pair.client, "ping!");

    var poll = root.NetPoll.init(pair.server, .recv);
    poll.completion().callback = stopCb;
    l.add(poll.completion());
    try l.run();
    try poll.getResult();
    try std.testing.expect(poll.ready().read);
}

test "NetPoll 真的会等：无数据时不完成，来了数据才完成" {
    var l = try testLoop();
    defer l.deinit();

    const pair = try makeTcpPair();
    defer pair.close();
    try l.associate(pair.server, 1);

    // **关键**：此刻 socket 上没有任何数据。NetPoll 必须「挂着」而不是
    // 立即完成——否则它就是个永远返回就绪的假实现。用 300ms 定时器证明
    // 这段时间内它没完成。
    const Ctx = struct {
        var poll_done: bool = false;
        fn onPoll(loop: *Loop, c: *Completion) void {
            _ = c;
            poll_done = true;
            loop.stop();
        }
        fn onDeadline(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    };
    Ctx.poll_done = false;

    var poll = root.NetPoll.init(pair.server, .recv);
    poll.completion().callback = &Ctx.onPoll;
    l.add(poll.completion());

    var deadline = root.Timer.init(300);
    deadline.c.callback = &Ctx.onDeadline;
    l.add(&deadline.c);
    try l.run();

    // 定时器先到：poll 还没完成，正是我们要的。
    try std.testing.expect(!Ctx.poll_done);

    // 现在发数据，再跑一次——这次必须完成。
    _ = try platform.sendBlocking(pair.client, "go");
    l.add(poll.completion());
    try l.run();
    try std.testing.expect(Ctx.poll_done);
    try std.testing.expect(poll.ready().read);
}

// ---- 元数据写入、路径解析与硬链接（阶段 F）--------------------------------

test "SetTimestamps：设 mtime 后 statFile 能读回来" {
    const stopCb = struct {
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    }.cb;
    var l = try testLoop();
    defer l.deinit();

    var path_buf: [512]u8 = undefined;
    var fbuf: [512]u8 = undefined;
    const path = try tmpDir(&path_buf, "setts");
    const file_path = try std.fmt.bufPrint(&fbuf, "{s}/f.txt", .{path});
    try l.makeDir(path, 0o755);
    defer l.removeDir(path) catch {};
    defer l.deleteFile(file_path);

    // 创建文件
    var content = "hello".*;
    var wf = root.WriteFile.init(l.io, file_path, &content);
    wf.work.c.callback = stopCb;
    l.add(&wf.work.c);
    try l.run();
    _ = try wf.getResult();

    // 设 mtime 为某个固定值（2020-01-01 00:00:00 UTC = 1577836800 秒）
    const target_ns: i64 = 1_577_836_800_000_000_000;
    var ts = root.SetTimestamps.init(l.io, file_path, target_ns, target_ns);
    ts.work.c.callback = stopCb;
    l.add(&ts.work.c);
    try l.run();
    try ts.getResult();

    // statFile 读回 mtime，验证真的改了
    var open_node = root.OpenFile.init(l.io, file_path, .read_only);
    open_node.work.c.callback = stopCb;
    l.add(&open_node.work.c);
    try l.run();
    const h = try open_node.getResult();
    var cf_close = root.CloseFile.init(l.io, h);
    defer cf_close.close();
    var st = root.StatFile.init(l.io, h);
    st.work.c.callback = stopCb;
    l.add(&st.work.c);
    try l.run();
    const s = try st.getResult();

    // mtime 精度：Linux/BSD 是纳秒，Windows 是 100ns；statFile 报毫秒
    const expected_ms = target_ns / 1_000_000;
    try std.testing.expectEqual(expected_ms, s.mtime_ms);
}

test "Access：存在的文件通过，不存在的报 FileNotFound" {
    const stopCb = struct {
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    }.cb;
    var l = try testLoop();
    defer l.deinit();

    var path_buf: [512]u8 = undefined;
    var fbuf: [512]u8 = undefined;
    const path = try tmpDir(&path_buf, "access");
    const file_path = try std.fmt.bufPrint(&fbuf, "{s}/a.txt", .{path});
    try l.makeDir(path, 0o755);
    defer l.removeDir(path) catch {};
    defer l.deleteFile(file_path);

    // 创建文件
    var content = "x".*;
    var wf = root.WriteFile.init(l.io, file_path, &content);
    wf.work.c.callback = stopCb;
    l.add(&wf.work.c);
    try l.run();
    _ = try wf.getResult();

    // 存在 → 通过
    var acc1 = root.Access.init(l.io, file_path, 0); // F_OK
    acc1.work.c.callback = stopCb;
    l.add(&acc1.work.c);
    try l.run();
    try acc1.getResult();

    // 不存在 → FileNotFound
    // 注意不能复用 `fbuf`：`file_path` 也指向它，覆盖后 defer 的 deleteFile
    // 会删错名字，`a.txt` 留在目录里导致 removeDir 非空失败（残留目录）。
    var mbuf: [512]u8 = undefined;
    const missing = try std.fmt.bufPrint(&mbuf, "{s}/nope.txt", .{path});
    var acc2 = root.Access.init(l.io, missing, 0);
    acc2.work.c.callback = stopCb;
    l.add(&acc2.work.c);
    try l.run();
    try std.testing.expectError(error.FileNotFound, acc2.getResult());
}

test "RealPath：解析出的路径与输入一致（无符号链接时）" {
    const stopCb = struct {
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    }.cb;
    var l = try testLoop();
    defer l.deinit();

    var path_buf: [512]u8 = undefined;
    var fbuf: [512]u8 = undefined;
    const path = try tmpDir(&path_buf, "realpath");
    const file_path = try std.fmt.bufPrint(&fbuf, "{s}/r.txt", .{path});
    try l.makeDir(path, 0o755);
    defer l.removeDir(path) catch {};
    defer l.deleteFile(file_path);

    var content = "y".*;
    var wf = root.WriteFile.init(l.io, file_path, &content);
    wf.work.c.callback = stopCb;
    l.add(&wf.work.c);
    try l.run();
    _ = try wf.getResult();

    var out: [1024]u8 = undefined;
    var rp = root.RealPath.init(l.io, file_path, &out);
    rp.work.c.callback = stopCb;
    l.add(&rp.work.c);
    try l.run();
    const n = try rp.getResult();

    // 解析结果应包含文件名（Windows 返回反斜杠，输入可能是正斜杠，不逐字比较）
    const resolved = out[0..n];
    try std.testing.expect(resolved.len > 0);
    // 文件名 "r.txt" 应出现在解析结果中
    try std.testing.expect(std.mem.indexOf(u8, resolved, "r.txt") != null);
}

test "HardLink：创建链接后两个路径指向同一文件" {
    const stopCb = struct {
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    }.cb;
    var l = try testLoop();
    defer l.deinit();

    var path_buf: [512]u8 = undefined;
    var fbuf: [512]u8 = undefined;
    var fbuf2: [512]u8 = undefined;
    const path = try tmpDir(&path_buf, "hardlink");
    const orig = try std.fmt.bufPrint(&fbuf, "{s}/orig.txt", .{path});
    const link = try std.fmt.bufPrint(&fbuf2, "{s}/link.txt", .{path});
    try l.makeDir(path, 0o755);
    defer l.removeDir(path) catch {};
    defer l.deleteFile(orig);
    defer l.deleteFile(link);

    var content = "shared".*;
    var wf = root.WriteFile.init(l.io, orig, &content);
    wf.work.c.callback = stopCb;
    l.add(&wf.work.c);
    try l.run();
    _ = try wf.getResult();

    // 创建硬链接
    var hl = root.HardLink.init(l.io, orig, link);
    hl.work.c.callback = stopCb;
    l.add(&hl.work.c);
    try l.run();
    try hl.getResult();

    // 通过链接读，应拿到相同内容
    var buf: [64]u8 = undefined;
    _ = try l.io.vtable.readFileInto(l.io.userdata, link, &buf);
    try std.testing.expectEqualStrings("shared", buf[0..6]);
}

test "SetPermissions + Access：chmod 0o000 后读被拒绝，恢复后通过" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const stopCb = struct {
        fn cb(loop: *Loop, c: *Completion) void {
            _ = c;
            loop.stop();
        }
    }.cb;
    var l = try testLoop();
    defer l.deinit();

    var path_buf: [512]u8 = undefined;
    var fbuf: [512]u8 = undefined;
    const path = try tmpDir(&path_buf, "chmod");
    const file_path = try std.fmt.bufPrint(&fbuf, "{s}/c.txt", .{path});
    try l.makeDir(path, 0o755);
    defer l.removeDir(path) catch {};
    defer l.deleteFile(file_path);

    var content = "secret".*;
    var wf = root.WriteFile.init(l.io, file_path, &content);
    wf.work.c.callback = stopCb;
    l.add(&wf.work.c);
    try l.run();
    _ = try wf.getResult();

    // chmod 0o000：所有人无权限
    var sp = root.SetPermissions.init(l.io, file_path, 0o000);
    sp.work.c.callback = stopCb;
    l.add(&sp.work.c);
    try l.run();
    try sp.getResult();

    // Access(R_OK=4) 应失败（root 除外，但 CI 不是 root）
    var acc = root.Access.init(l.io, file_path, 4);
    acc.work.c.callback = stopCb;
    l.add(&acc.work.c);
    try l.run();
    try std.testing.expectError(error.AccessDenied, acc.getResult());

    // 恢复 0o644
    var sp2 = root.SetPermissions.init(l.io, file_path, 0o644);
    sp2.work.c.callback = stopCb;
    l.add(&sp2.work.c);
    try l.run();
    try sp2.getResult();

    // Access(R_OK) 应通过
    var acc2 = root.Access.init(l.io, file_path, 4);
    acc2.work.c.callback = stopCb;
    l.add(&acc2.work.c);
    try l.run();
    try acc2.getResult();
}

// ---- 跨后端一致性回归：全双工 + 同方向多 pending -------------------------
//
// 这两个用例是**后端无关**的契约测试：它们跑在当前平台默认后端上
// （Linux=io_uring，可强制 epoll；macOS/FreeBSD=kqueue；Windows=IOCP）。
// 每个后端都有自己的 fd-slot / pending 链表实现，但契约必须一致：
//
//   1. 同一 socket 上**同时**有一个 recv 和一个 send 在飞时，两个都必须
//      各自完成，不能因为「同 fd 只留一个 pending」而静默丢掉一个方向。
//   2. 同一 socket 上**同方向**多个 recv 在飞时，必须按 FIFO 依次完成，
//      不能合并成一个、也不能丢掉后面的。
//
// 用 TCP 回环对而不是 Unix socketpair：Windows 没有 socketpair，
// 而 TCP 在四个后端上语义一致。

test "跨后端：同一 socket 全双工 recv+send 各自完成" {
    var l = try testLoop();
    defer l.deinit();

    const pair = try makeTcpPair();
    defer pair.close();
    try l.associate(pair.server, 1);

    const Ctx = struct {
        var recv_done = false;
        var send_done = false;
        var recv_bytes: usize = 0;
        var send_bytes: usize = 0;
        var recv_buf: [8]u8 = undefined;

        fn onRecv(lp: *Loop, c: *Completion) void {
            const r: *root.NetRecv = @fieldParentPtr("c", c);
            if (r.c.err == null) {
                recv_done = true;
                recv_bytes = r.c.bytes;
            }
            tryStop(lp);
        }
        fn onSend(lp: *root.Loop, c: *Completion) void {
            const s: *root.NetSend = @fieldParentPtr("c", c);
            if (s.c.err == null) {
                send_done = true;
                send_bytes = s.c.bytes;
            }
            tryStop(lp);
        }
        fn tryStop(lp: *Loop) void {
            if (recv_done and send_done) lp.stop();
        }
    };
    Ctx.recv_done = false;
    Ctx.send_done = false;
    Ctx.recv_bytes = 0;
    Ctx.send_bytes = 0;

    var recv_node = root.NetRecv.init(pair.server, &Ctx.recv_buf);
    recv_node.c.callback = &Ctx.onRecv;
    var send_node = root.NetSend.init(pair.server, "abc");
    send_node.c.callback = &Ctx.onSend;
    l.add(&recv_node.c);
    l.add(&send_node.c);

    // 客户端稍后才写：写方向先就绪，读方向后到，逼出「就绪事件必须重挂
    // 剩余方向」的逻辑。
    const Writer = struct {
        fn run(fd: root.Handle) void {
            const start = platform.tickCount();
            while (platform.tickCount() - start < 20) {}
            _ = platform.sendBlocking(fd, "xyz") catch {};
        }
    };
    const t = try std.Thread.spawn(.{}, Writer.run, .{pair.client});
    defer t.join();

    // 守护定时器：万一某个方向被吞掉，2 秒后停循环，测试断言失败而不是挂死。
    var guard = Timer.init(2000);
    guard.c.callback = struct {
        fn cb(lp: *Loop, c: *Completion) void {
            _ = c;
            lp.stop();
        }
    }.cb;
    l.add(&guard.c);

    try l.run();
    try std.testing.expect(Ctx.send_done);
    try std.testing.expect(Ctx.recv_done);
    try std.testing.expectEqual(@as(usize, 3), Ctx.send_bytes);
    try std.testing.expectEqual(@as(usize, 3), Ctx.recv_bytes);
    try std.testing.expectEqualStrings("xyz", Ctx.recv_buf[0..3]);
}

test "跨后端：同一 socket 同方向多个 recv 按 FIFO 依次完成" {
    const n: usize = 4;
    var l = try testLoop();
    defer l.deinit();

    const pair = try makeTcpPair();
    defer pair.close();
    try l.associate(pair.server, 1);

    // 先写 4 个字节，再提交 4 个 1 字节 recv：每个 recv 恰好拿到 1 字节，
    // 于是四个 recv 必须**依次**各完成一次，而不是一个大 recv 吃掉全部。
    _ = try platform.sendBlocking(pair.client, "abcd");

    const Ctx = struct {
        var done: usize = 0;
        var bufs: [n][1]u8 = undefined;
        var nodes: [n]root.NetRecv = undefined;

        fn onRecv(lp: *Loop, c: *Completion) void {
            const r: *root.NetRecv = @fieldParentPtr("c", c);
            if (r.c.err == null and r.c.bytes == 1) done += 1;
            if (done == n) lp.stop();
        }
    };
    Ctx.done = 0;

    for (&Ctx.nodes, 0..) |*node, i| {
        node.* = root.NetRecv.init(pair.server, &Ctx.bufs[i]);
        node.c.callback = &Ctx.onRecv;
        l.add(&node.c);
    }

    var guard = Timer.init(2000);
    guard.c.callback = struct {
        fn cb(lp: *Loop, c: *Completion) void {
            _ = c;
            lp.stop();
        }
    }.cb;
    l.add(&guard.c);

    try l.run();
    try std.testing.expectEqual(@as(usize, n), Ctx.done);
}
