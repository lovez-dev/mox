//! 事件循环测试：定时器、收发、接受、连接、`Work` 与文件读取。
//!
//! 从 `loop.zig` / `io.zig` 移出，统一由 `io.zig` 聚合。

const std = @import("std");
const net = std.Io.net;
const root = @import("io.zig");

const Loop = root.Loop;
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
const platform = root.platform;
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
    try std.testing.expectEqual(@as(usize, 0), loop.retired.items.len);
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

    try std.testing.expectEqual(@as(usize, 1), loop.retired.items.len);
    try std.testing.expectEqual(@as(usize, 0), loop.retired_timeouts);

    loop.drainRetired(50);

    // 超时必须被记下来，而不是静默返回；对象也仍然没有被 dispose。
    try std.testing.expectEqual(@as(usize, 1), loop.retired_timeouts);
    try std.testing.expectEqual(@as(usize, 1), loop.retired.items.len);
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
