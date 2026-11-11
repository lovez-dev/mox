# mox

一个基于**完成 / 回调**模型的 Zig Web 框架与可复用 I/O 库。

- **不是 async/await**：每个操作是一块由调用方持有、内嵌的 `Completion` 节点，
  交给 `Loop.add`，完成后由 `Loop.run` 回填结果并回调。没有 future、没有纤程栈、
  没有每连接分配之外的额外开销。
- **自有 I/O 抽象**：`mox_io.Io{ userdata, vtable }`。上层只认这个接口，
  不接触任何平台类型；新增后端 = 填满一个 `VTable`。
- **手写原生后端**：Linux `io_uring`（默认，失败自动回落 `epoll`）、
  Linux `epoll`、BSD/Darwin `kqueue`、Windows `IOCP`。
  热路径（网络、定时器）走原生异步；文件等无可移植异步接口的操作走 `Work` 池兜底。
- **不含 HTTPS**：TLS 由 nginx 等反向代理终止，框架只处理明文 HTTP/1.1。

## 环境

Zig **0.17.1**。构建：

```sh
zig build              # 产出 zig-out/bin/example
zig build test         # 所有平台上都跑 mox + mox_io 测试
```

示例服务监听 `127.0.0.1:18080`：

```sh
./zig-out/bin/example
curl http://127.0.0.1:18080/
curl http://127.0.0.1:18080/hello/zig
curl http://127.0.0.1:18080/static/hello.txt
```

## 作为库使用

`build.zig` 暴露两个模块：

| 模块 | 根文件 | 内容 |
|---|---|---|
| `mox` | `src/root.zig` | 路由、中间件、HTTP、服务端 |
| `mox_io` | `src/io/io.zig` | 独立的完成式 I/O 运行时 |

在你的项目里：

```zig
// build.zig
const mox = b.addModule("mox", .{
    .root_source_file = b.path("path/to/mox/src/root.zig"),
    .target = target,
});
const mox_io = b.addModule("mox_io", .{
    .root_source_file = b.path("path/to/mox/src/io/io.zig"),
    .target = target,
});
mox.addImport("mox_io", mox_io);
exe.root_module.addImport("mox", mox);
```

最小服务：

```zig
const std = @import("std");
const mox = @import("mox");

fn index(ctx: *mox.Context) anyerror!mox.Response {
    _ = ctx;
    return .{ .body = "hello\n" };
}

fn greet(ctx: *mox.Context) anyerror!mox.Response {
    const name = ctx.param("name") orelse "world";
    return .{ .body = try std.fmt.allocPrint(ctx.gpa, "hello {s}\n", .{name}) };
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    try mox.serve(.{
        .gpa = gpa,
        .address = try std.Io.net.IpAddress.parse("127.0.0.1", 8080),
        .routes = &.{
            .{ .method = .GET, .path = "/", .handler = index },
            .{ .method = .GET, .path = "/hello/:name", .handler = greet },
    });
}
```

路由是 gin 风格的段前缀树：支持 `:param` 与 `*wildcard`，在编译期展开匹配。
中间件形状是 `fn (next: Handler) Handler`，由 `mox.compose` 在编译期折叠。

## I/O 模型

```
调用方持有 NetRecv / NetSend / NetAccept / NetConnect / Timer / Work
        │  Loop.add(&node.c)
        ▼
Loop ── io.vtable.recv/send/accept/connect ──► 后端（IOCP / io_uring / epoll / kqueue）
        ▲                                          │
        └──── io.vtable.wait() 返回 Ref ───────────┘
                 │
                 ▼ 回填结果 → 回调(loop, &node.c)
```

- `Ref.scratch` 就是 `Completion.ov` 的地址，用 `@fieldParentPtr` 直接映射回节点。
- `Work` 池有固定并发上限、可停机；`Loop.deinit()` 会 join 所有工作线程，
  因此之后不会有线程再触碰循环对象的内存。
- `Loop.cancel(c, ctx, dispose)` 标记取消并让后端投递一个完成包；
  循环收到后调用 `dispose` 释放对象，既不回调也不回填。
- `Loop.drainRetired(ms)` 在停机后排空取消项，保证栈上的 `Server` 安全出栈。
  正常路径下后端都会很快投递完成包；若超时仍未排空，为保证不发生悬空访问，
  对象会被留在登记表里（泄漏而非崩溃），由 `Loop.deinit` 释放表本身。

### 运行时配置（`openWith`）

`mox_io.open(alloc)` 用默认参数构造循环，现有代码无需改动。要调资源尺寸用
`openWith`，形状对齐 zio 的 `Loop.Options` / `RuntimeOptions`——同一进程可开多个
不同配置的循环：

```zig
var loop = try mox_io.openWith(gpa, .{
    .queue_size = 512,   // 后端事件队列容量，2 的幂；io_uring 下 SQ=它、CQ=它×8
    .max_workers = 8,    // Work 线程池上限，0 = 平台默认（4）
    .backend = .epoll,   // 仅 Linux：覆盖后端选择
});
```

- `queue_size` 会真正传到后端：io_uring 的 SQ/CQ 环、epoll/kqueue 就绪数组、
  IOCP 完成端口批量大小都随之缩放（epoll/kqueue/IOCP 当前仍是定长批量数组，
  只接参数不改行为，见各 `createWith` 注释）。
- **`inflight_max` 不要手填。** 留空由后端按 `queue_size × 4` 推导；显式给大值会
  被钳制到「CQ 环容量的一半」。放开它只会在大批量提交时灌爆 CQ 环、内核丢
  完成包、回调永不触发——这是实测踩过的坑。

## 目录结构

```
src/
  root.zig          框架门面
  types.zig         领域模型（Params / Response / Context / Handler / Route / Config）
  http.zig          HTTP/1.1 解析与序列化
  router.zig        段前缀树路由
  middleware.zig    编译期中间件折叠
  server.zig        完成式 HTTP 服务状态机
  io/
    io.zig          契约 + VTable + 门面 + 后端选择器
    completion.zig  完成节点类型族
    loop.zig        事件循环引擎
    queue.zig       侵入式 FIFO 就绪队列
    timer.zig       定时器有序链表
    pool.zig        Work 线程池
    file.zig        文件节点：ReadFile / WriteFile / SendFile / Truncate / Delete
    tests.zig       事件循环测试
    queue.zig       就绪 FIFO
    timer.zig       定时器有序表
    pool.zig        `Work` 线程池
    udp.zig         UDP 可选能力
    dns.zig         DNS 可选能力（建立在 UDP 之上）
    process.zig     子进程：spawn / 异步等退出 / 进程组
    signal.zig      信号订阅：self-pipe + Work 线程
    backends/
      windows.zig   IOCP + 手写 Winsock 层
      uring.zig     io_uring 环
      linux.zig     Linux 后端门面（默认 uring，失败回落 epoll）
      epoll.zig     epoll 就绪→完成桥接
      kqueue.zig    kqueue 就绪→完成桥接
examples/basic.zig   端到端示例
examples/consumer/   外部消费者（真包依赖验证夹具）
bench/echo.zig       TCP echo 性能基线
bench/blocking.zig   纯阻塞 echo 对照尺子
bench/concurrent.zig 多连接并发吞吐尺子
```

## 跨线程提交

`Loop.submit(&c)` 可从任意线程调用：节点压入无锁 MPSC 栈，后端 `notify`
唤醒循环，回调一定在循环线程触发。循环每轮先排空提交项，再批量收割完成包。

## 性能基线

```sh
zig build bench -Drounds=20000 -Doptimize=ReleaseFast
zig build bench-blocking -Drounds=20000 -Doptimize=ReleaseFast   # 纯阻塞对照
zig build bench-concurrent -Dconns=16 -Drounds=2000 -Doptimize=ReleaseFast
```

服务端跑在 `mox_io.Loop` 的完成循环里，客户端是独立阻塞线程，64 字节
payload 串行 ping-pong；输出 ops/s 与 µs/op。`vtable.waitBatch` 一次系统调用
最多收 64 个完成包。`bench-blocking` 用完全相同的负载，但服务端直接阻塞
recv/send，用来隔离本机 / WSL2 的固有开销。

当前实测（ReleaseFast，20000 轮，各三次）：

| 后端 | 纯阻塞对照 | mox_io 循环 | 循环增量 |
|---|---|---|---|
| Windows IOCP | 21–22 µs | 20–21 µs | ~0 |
| Linux io_uring（WSL2） | 71 µs | 76 µs | +5 µs（约 7%） |

结论：WSL2 上的 75µs 主要是 localhost TCP + 双线程往返的固有开销，纯阻塞
同样要 71µs；不是 io_uring 提交路径的问题。因此没有为了这 5µs 去合并
`io_uring_enter(GETEVENTS)`——那会破坏 eventfd 对 `notify` / 跨线程
`submit` 的唤醒语义。

多连接吞吐（16 连接 × 2000 轮，单个 Loop）与 `batch_size` A/B：

| 后端 | batch=1 | batch=64 | 提升 |
|---|---|---|---|
| Windows IOCP | 157.6k ops/s | 170–171k ops/s | 约 8% |
| Linux io_uring（WSL2） | 38.1–38.6k ops/s | 41.9–43.6k ops/s | 约 11% |

Linux 上单连接 13k ops/s、16 连接 42k ops/s，单个循环吞吐提升约 3.2 倍。
A/B 是临时把 `loop.zig` 的 `batch_size` 改成 1 跑出来的，已改回 64。

**这些数字只用于本项目改动前后的自身对比。** zio 没有提供同 workload 的
benchmark，API 也不兼容；在建立 zio 适配器与共同负载之前，不能据此声称
「与 zio 对齐」或「不比 zio 差」。

### 与 zio / fasthttp 同机对标

同一台机器（WSL2，4 核，内核 6.18）、同一个压测客户端，避免跨机误差：

| 场景 | mox | 对照 |
|---|---|---|
| TCP ping-pong，50 连接 | **187.8k ops/s，5.3 µs/op** | zio 181.0k，5.5 µs/op |
| HTTP/1.1 keep-alive，c=200 | **74.9k req/s** | fasthttp 66.3k req/s |

zio 是 Zig 的事件循环库（io_uring + work-stealing 调度），fasthttp 是 Go 的
高性能 HTTP 服务端，两者都是各自生态的性能标杆。测法：zio 与 mox 各写一个
无人工延迟的 echo 服务端，用同一个 Go 客户端跑 ping-pong；HTTP 侧用 `hey`
打同一个固定响应。

**这些绝对数字只在本机内部有意义**（4 核 WSL、客户端与服务端抢同一批
CPU），不要拿去做跨平台横比。有价值的是同机相对差距。

踩到的关键坑：io_uring 后端曾在 `getSqe` 里对每个 `add` 立即
`io_uring_enter`，把批量提交彻底废掉。功能全对、所有测试全绿，但
strace 显示 25000 次往返产生 **50101 次 enter**（每操作 2 次），吞吐比
zio 低 22%。改为只在 `waitBatch` 开头 flush 一次后，enter 降到 **1051**
（-97.9%），吞吐反超 zio。**这类退化没有任何功能测试能抓到，只能数
syscall**——所以后端保留了只读探针 `enterCalls()` 和对应的回归测试。

### 试过但未启用：io_uring 的 `DEFER_TASKRUN` / `SINGLE_ISSUER` / `COOP_TASKRUN`

按 zio 的形状把队列容量做成运行时 `queue_size` 时，顺手试了这三个标志（zio
默认开）。结论：**`SINGLE_ISSUER` 本身无害，但 `DEFER_TASKRUN` 在批量负载下
让吞吐腰斩**，实测 `bench-burst` 20000 ops（ReleaseFast，WSL2 内核 6.18）：

| 标志组合 | ops/s |
|---|---|
| 仅 `CQSIZE`（当前） | 91k–109k |
| `+ SINGLE_ISSUER` | 90k–109k（与基线持平） |
| `+ DEFER_TASKRUN + COOP` | 51k–60k（**腰斩**） |

`DEFER_TASKRUN` 把完成包的 task_work 推迟到 `io_uring_enter(GETEVENTS)` 时刻，
需要把等待模型从外部 `poll(ring_fd/eventfd)` 改成 `io_uring_enter2` + 内核侧
`timespec` 超时，并把跨线程 `notify` 的 eventfd 也做成环内 multishot `POLL_ADD`
才能被唤醒——这套改造本身能跑通（mox 实测全绿），但批量负载下每次 enter 只
推进有限 task_work，20000 个操作要非常多次 `enter2` 才收完，吞吐掉一半。

诚实结论：**`DEFER_TASKRUN` 不适合 mox 的批量收割模型，不启用**。`queue_size`
运行时化与 `openWith` 保留（明确有价值），等待模型保持久经验证的 `poll`。
（另一条实测：`io_uring_getevents_arg.ts` 是**指向 `timespec` 的指针**而非纳秒
整数，传整数会让内核解引用野指针直接返回 `EFAULT(-14)`。）

## Linux 后端：io_uring 与 epoll

`platform.create()`（Linux 上由 `backends/linux.zig` 充当门面）默认建
`io_uring`。`io_uring_setup` 失败（内核不支持、`seccomp` 拦截、
`/proc/sys/kernel/io_uring_disabled=1`、资源不足）时自动回落到 `epoll`，
上层 `Loop` 完全无感——两个后端返回的是同一个 `VTable` 契约。

`epoll` 是「就绪」接口而非「完成」接口，因此 `backends/epoll.zig` 与 kqueue
后端同构：每个未完成操作注册一个 `EPOLL.ONESHOT` 事件并记一条 `Pending`；
`waitBatch` 拿到就绪事件后就地执行非阻塞 `recvfrom` / `sendto` / `accept`，
再合成循环期望的完成包。`Work` 唤醒用 `eventfd` 挂进同一个 epoll 实例。
`ONESHOT` 触发后内核会禁用注册，同一 fd 再次提交操作由 `epoll_ctl(MOD)`
重新武装——这条路径有专门的回归测试（同一 fd 连续两次 `recv`）。

同步辅助函数（建 socket / bind / listen / 文件读写）与事件循环无关，
`epoll.zig` 直接复用 `uring.zig` 的 POSIX 实现，不重复一套编组代码。

`zig build test` 在 Linux 上会跑 `epoll` 专属测试（timer、accept/recv/send、
Work 唤醒、异步 connect、ONESHOT 重挂、后端选择），因此无论 CI runner 是否
启用 io_uring，epoll 路径都真实执行而不是只做编译校验。

回落路径已在真实禁用的内核上端到端验证过：在 WSL 里把
`/proc/sys/kernel/io_uring_disabled` 写成 `1` 后重跑，`io_uring_setup` 返回
`SetupFailed`，`platform.create()` 改选 `epoll`，全量测试在纯 epoll 路径下
**46/46 全绿**。`backends/uring.zig` 里那几条后端专属测试在此时会读取
`create` 的失败原因，遇到 `SetupFailed` 就**跳过而不是失败**——这类失败由
环境造成，不该记在 mox 头上；其它错误仍旧照常抛出。把 sysctl 改回 `0`
之后这 5 条会重新真正执行并通过，两个方向都验证过。

## 新增一个后端

写一个导出 `create(allocator) !Io` 的文件，填满 `mox_io.VTable` 的全部字段，
再在 `src/io/io.zig` 的 `platform` 选择器里加一个分支即可。`VTable` 覆盖：
生命周期、时钟、socket 建立/绑定/监听、文件查询与阻塞读、关联、
收发/接受/连接及其收尾、取消、关闭、批量等待（`waitBatch`）、唤醒。

## 可选能力

新能力通过 `Io.capability` 查询可选能力表接入，用 `mox_io.cap("名字")`
编译期算出 ID；新增能力不改变主 `VTable` 布局，也不打断 TCP / timer 热路径。
未注册的能力返回 `null`。

`src/io/udp.zig` 与 `src/io/dns.zig` 是这套机制的**两个已落地实例**，也同时
是扩展模板：加第三个能力只需「一个 `cap("...")` 常量 + 一张函数表 + 一个
节点类型」，`VTable` 与 `Loop` 都不动。**注意**：进程、信号、select、group
等都只是在设计上被这套机制覆盖；**进程（spawn / 异步等退出 / 进程组）已落地**，
见下文「子进程」一节；**信号订阅已落地**，见「信号」一节；**任意 fd 就绪监视
已落地**（`WatchFd`），见「任意 fd 就绪监视」一节。`select` 明确不做（理由见下）；
能力表当前是 UDP 与 DNS 两项。

### 为什么不做 `select`，而是 `WatchFd`

`select` 是 `poll` 的受限前身：`FD_SETSIZE` 通常只有 1024，且每次调用都要重传
整个 fd 集合。更重要的是，mox 的每个后端**本身就是**事件循环——Linux 走
`epoll_wait` / `io_uring`，macOS 走 `kevent`，Windows 走
`GetQueuedCompletionStatus`。在事件循环之上再套一层 `select`，等于把已有的
能力重新实现一遍，而且只覆盖 1024 个 fd。

「把任意 fd 挂进循环等可读」这个真需求，正确形状是跨后端统一的 `WatchFd`，
已落地（见下文「任意 fd 就绪监视」）。

UDP 已作为第一个能力落地（`src/io/udp.zig`）：`Udp.get(loop.io)` 取句柄，
`Udp.Recv` / `Udp.Send` 优先走后端原生异步数据报（细节见下文「UDP 与 DNS」
一节）；后端没有异步入口时自动回落到 `Work` 池的阻塞 `recvfrom` / `sendto`，
两条路径对调用方同义，回调都落在循环线程。

DNS 是第二个能力（`src/io/dns.zig`），**建立在 UDP 之上**：构造 A 查询报文、
经 UDP 能力收发、解析应答里的 IPv4 地址。能力表现在同时容纳两个 ID，
未注册的 ID 返回 `null`。目前只支持单条 A 查询、无 TCP 回退、不读系统
resolver 配置（由调用方传入 server 地址）。加第三个能力仍然只是加一行
`cap("...")` + 一张函数表，主 `VTable` 与 `Loop` 都不动。

## 定时器与取消

定时器是二叉最小堆（`timer.zig`），插入 / 弹出 O(log n)。`Loop.cancel`
对定时器立即从堆中摘除并回收，对 `Work` / `net_close` 由 `invoke` 拦截回收，
对有内核在飞的操作仍等后端取消完成包；`drainRetired(ms)` 只用于停机时
等待最后一类，超时是泄漏对象而非崩溃。

## 截止时间（deadline）

`Loop.watchdog(c, &timer, ms)` 给任意已提交的操作挂一个截止时间：

```zig
var req_timer = Timer.init(0);
loop.watchdog(&req.work.c, &req_timer, 3000); // 这个请求 3 秒内必须结束
loop.add(&req.work.c);
```

`timer` 由调用方持有（内嵌即可，零额外分配），与目标操作通过双向指针关联：

- 操作先完成 → `invoke` 自动摘除定时器，回调看到的是正常结果。
- 定时器先到点 → 通知后端取消在飞操作，把 `error.DeadlineExceeded` 写进
  操作的 `err`，然后回调一次并把回调指针置空；之后到达的完成包被静默丢弃。
- `Loop.unwatchdog(c)` 可提前主动撤销。

超时不走 `cancel` 的延迟回收路径：**对象仍归调用方**，因为调用方需要靠
`getResult()` 读到 `DeadlineExceeded`。也没有「同一操作挂多个 watchdog」的语义，
重复调用 `watchdog` 会先撤销上一个。


## 子进程

`src/io/process.zig` 是**手写平台层**，不借 `std.Io`：POSIX 用 `fork` +
`execve` + `waitpid`，Windows 用 `CreateProcessW` + `WaitForSingleObject` +
`TerminateProcess`。标准库只当 syscall / kernel32 绑定用，和 epoll / kqueue /
IOCP 三个后端的做法一致。

```zig
var p = try mox_io.Process.spawn(.{
    .allocator = allocator,
    .argv = &.{ "/bin/sh", "-c", "echo hi; exit 7" },
    .stdout = .pipe,            // 也可 .inherit / .ignore / .fd(fd)
    .cwd = "/tmp",              // null = 继承
    .new_group = true,          // 建新进程组，配合 killGroup
});

// 同步等退出（阻塞调用线程）
const term = try p.waitSync();
_ = term.code();               // ?u8，非 .exited 时为 null
_ = term.success();            // 仅 .exited 且码为 0

// 或者异步等：Wait 节点占一个 Work 池线程，回调回到循环线程
var wait = mox_io.ProcessWait.init(&p);
wait.work.c.callback = myCb;
loop.add(&wait.work.c);
// … 回调里：wait.getResult()

p.kill();                      // 强制终止并回收
try p.killGroup(15);           // 向整个进程组发 SIGTERM
```

语义要点：

- **`spawn` 是同步的**，`wait` 才是异步的。fork/exec 与 `CreateProcessW` 在调用
  线程里跑完；`Wait` 节点的阻塞 `waitpid` / `WaitForSingleObject` 在 `Work` 池
  线程里，和文件 I/O 同一权衡（默认 4 个池线程）。
- **exec 失败如何回传**：POSIX 上 fork 成功但 exec 失败时，子进程把 errno 写进
  一根 `CLOEXEC` 管道后 `_exit(127)`；父进程读到 EOF 即成功、读到 4 字节即失败。
  父进程**必须在阻塞读之前关掉自己的写端**，否则永远等不到 EOF。
- **Linux 不链 libc**：Linux 的 POSIX 路径走 `std.os.linux` 裸 syscall。原因是一旦
  链上 libc，`std.Thread.spawn` 会改走 `pthread_create`，而 `Work` 池给线程设了
  256 KiB 栈，glibc 会以 `EINVAL` 拒绝，std 把它映射成 `unreachable` 直接 panic。
  环境变量因此从 `/proc/self/environ` 读，而不是 `environ`。
- **Windows 组终止用作业对象**：`new_group = true` 时会建一个 Job Object 并把子进程
  放进去，`killGroup` 走 `TerminateJobObject`，能连带杀掉子进程再派生的进程。
- **`deleteFile` 式的诚实**：`killGroup` 在 POSIX 上要求子进程确实是组长（`new_group
  = true`），否则 `kill(-pid)` 会失败并返回 `error.KillFailed`。

## 任意 fd 就绪监视（`WatchFd`）

管道、串口、`stdin` 这类 mox 不认识语义的 fd，用 `WatchFd` 挂进事件循环：

```zig
var w = mox_io.WatchFd.init(pipe_read_fd, .{ .read = true });
w.c.callback = myCb;               // 回调里读 w.ready
loop.add(&w.c);
```

与 `NetRecv` / `NetSend` 的分工：那两个**替你收发**并回填字节数；`WatchFd`
只**通知方向**，数据仍由调用方自己 `read` / `write`。

- **一次性语义**：回调触发后这次 watch 失效，要再等必须重新 `loop.add`。
  与后端的 ONESHOT / `EV.ONESHOT` / `POLL_ADD` 天然一致。
- **`Ready` 用位标志**：`read` / `write` / `failed` / `hangup` 可能同时置位，
  一次就能拿到全部信息。（字段不叫 `error`——那是 Zig 关键字。）
- **就绪位经 `Ref.bytes` 回传**，由 `Loop` 统一翻译进 `WatchFd.ready`。这样
  三个后端不必知道节点布局，形状完全一致。
- **kqueue 一次只盯一个方向**：可读可写要挂两个 `WatchFd` 节点。
- **Windows 返回 `error.Unsupported`**：IOCP 是完成模型，没有「等就绪」这
  回事。硬实现要另起 `WSAPoll` 线程桥接，那等于在 IOCP 里塞第二条事件循环，
  比 `select` 更糟。这是刻意的能力缺口，不是遗漏。

## 信号

`src/io/signal.zig`。信号不能「异步等」，只能阻塞等，因此 `Signal` 内嵌一个
`Work` 节点，由池线程阻塞在 self-pipe 读端；信号到达时处理器写入一个字节，
读端返回，回调回到循环线程。

```zig
var s = try mox_io.Signal.init(mox_io.Signals.TERM);
defer s.deinit();
s.work.c.callback = myCb;          // 回调里 s.getResult() 拿到信号编号
loop.add(&s.work.c);
```

- **self-pipe 而非 `sigwait` / `signalfd`**：`sigwait` 要求信号先被 `pthread_sigmask`
  屏蔽，而屏蔽必须在**所有线程**上生效，否则信号可能投递到别的线程、池线程永远
  等不到；`signalfd` 是 Linux 专有。self-pipe 用「异步信号安全的 `write`」把信号
  转成 fd 可读，全 POSIX 通用。
- **处理器只做 `write`**，不碰堆内存——异步信号安全。
- **每种信号同一时刻只支持一个订阅**（`sigaction` 是进程级单值）。
- **Windows 返回 `error.Unsupported`**：Windows 没有 POSIX 信号语义，硬凑没有意义。
- **不要订阅 `SIGPIPE`**：`Loop.init` 已经把它设为 `SIG_IGN`，永远不会走到订阅端。

### `SIGPIPE`：两道防线

写一个对端已关闭的 socket 时，内核默认投递 `SIGPIPE`，**直接把整个进程杀掉**。
这不是边缘情况：浏览器取消请求、用户关页面、网络闪断都会触发。实测确认（向半
关闭连接反复写，第二次写即死），因此设了两道防线：

1. **每处发送带标志**：Linux 的 `send` SQE 与 `sendBlocking` 都带 `MSG_NOSIGNAL`；
   BSD 没有这个标志，改为在 `createSocket` 时设 socket 级 `SO_NOSIGPIPE`，一次
   覆盖该 socket 的所有发送路径。
2. **进程级兜底**：`Loop.init` 调用一次 `sigaction(SIGPIPE, SIG_IGN)`，让任何漏掉
   的写路径（标准库内部、第三方代码、写已关闭的管道）都只得到 `EPIPE` 错误。

两道防线都有变异测试证明有效：撤掉 `MSG_NOSIGNAL` 后进程被信号杀死；只靠
`SIG_IGN` 时裸 `write` 能拿到 `EPIPE` 并存活。
## 文件系统操作

除读写删之外，`Loop` 还提供目录与元数据操作。**这些都是同步入口**（直接调
平台层），在 `Work` 节点内部复用；在循环线程里直接调用会卡住整个循环，
异步场景请用对应的节点。

| 操作 | 语义 |
|---|---|
| `makeDir(path, mode)` | 逐级创建（`mkdir -p`），已存在不报错 |
| `removeDir(path)` | 只删空目录，非空报 `DirNotEmpty`，**不递归** |
| `rename(from, to)` | 跨设备报 `CrossDevice`，不退化成「复制+删除」 |
| `symLink(target, link)` | Windows 需管理员权限或开发者模式 |
| `statPath(path)` | 返回 `FileKind` / `size` / `mtime_ms`，跟随符号链接 |
| `listDir(path, buf)` | 列出条目（`DirEntry` 数组），返回条数 |

`makeDir` 逐级创建、`removeDir` 不递归是刻意的：递归删除太危险，静默截断
路径会操作到别的文件——宁可明确失败。

### Unix domain socket

```zig
const listener = try loop.createUnixSocket();
try loop.bindUnix(listener, "/tmp/app.sock");   // 已存在报 PathAlreadyExists
try loop.listen(listener, 8);
// 之后与 TCP 完全同形：NetAccept / NetRecv / NetSend
```

三个 POSIX 后端各自实现（io_uring 走 `prep_connect` 原生异步；epoll 与
kqueue 做非阻塞 connect）。**Windows 整组槽位为 `null`**，返回
`error.Unsupported`。

已知限制：`connect` 的 `sockaddr_un` 要活到内核读完，只能塞进 64 字节的
`Scratch`，扣掉结构头后路径上限约 62 字节。覆盖 `/tmp/x.sock`、
`/var/run/x.sock` 这类常见路径；超出时明确报 `NameTooLong`，而不是截断
连到别的 socket。

### 原生异步文件 I/O（仅 io_uring）

Linux 上文件读写是真异步——提交 SQE，完成时回调，不占池线程：

```zig
var f = root.ReadFileAsync.init("/path/to/file ", &buf);
f.c.callback = &onRead;
loop.add(&f.c);
```

`openat` 与 `close` 留同步，只 `read`/`write` 异步。两条实测结论支撑这个
取舍：`IOSQE_IO_LINK` **不会**把前一条的返回值传给后一条的 fd 字段；把
`close` 链在 `read` 后面，它的 CQE 会回 `-125`（ECANCELED）导致 fd 泄漏。
两者都是纳秒到微秒级的元数据操作，留在同步侧没有可观测代价。

非 io_uring 后端 `readFileAsync`/`writeFileAsync` 为 `null`，节点返回
`error.Unsupported`，调用方回落 `ReadFile`（`Work` 版）。

### 零拷贝文件 → socket（`SendFile`）

```zig
var sf = root.SendFile.init(loop.io, socket, "/path/to/big.bin");
sf.work.c.callback = &onSent;   // 或直接 loop.sendFile(socket, path, 0, 0)
```

`sendfile(2)` 把页缓存直接送进 socket 缓冲，不经用户态。走 `Work` 池而不是
异步后端——它本身已是零拷贝，只有数据量大时才阻塞，两者结合同时拿到「不
阻塞循环」和「不复制数据」。

三平台签名不同（Darwin 参数顺序与 Linux 相反，FreeBSD 多一个出参），逐个
适配。Windows 的 `TransmitFile` 在 std 里没绑定，槽位为 `null`。

## 作为包被依赖

仓库根有 `build.zig.zon`，包名 `mox`，最低 Zig 版本 `0.17.1`。外部项目
可以直接声明路径依赖：

```zig
// 消费者的 build.zig.zon
.dependencies = .{ .mox = .{ .path = "../.." } },

// 消费者的 build.zig
const dep = b.dependency("mox", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("mox", dep.module("mox"));
exe.root_module.addImport("mox_io", dep.module("mox_io"));
```

`zig build test-package` 会在 `examples/consumer/` 里真正编译这个外部
消费者，验证 `addModule` 暴露的两个模块都能被包管理器拿到；此前还实跑过
它的 HTTP 服务返回 200。`.paths` 只包含 `build.zig`、`build.zig.zon`、
`src`，因此 README / CI / 示例数据不进包哈希。

## 部分写入与背压

一次 `send` 完成给出的字节数**可能少于提交的长度**（内核发送缓冲已满）。
`server.zig` 的 `onSend` 因此把 `send_wire` / `sent_len` 记在连接上，未写完
就重新投递尾部，直到全部送达；这形成天然的背压——循环线程不阻塞、不轮询，
只是让出等该 socket 下一次可写。

丢弃这个返回值曾经是协议正确性 bug：响应被截断，而 `content-length` 仍声称
完整，客户端会一直等一个永远不会来的结尾。

各后端的实际差异（实测，非推断）：

| 后端 | 部分写入 | 说明 |
|---|---|---|
| Linux io_uring | 常见 | `send` 在缓冲满时明确短写；回归测试在 WSL 上稳定触发 |
| Linux epoll | 常见 | 与 io_uring 同一套 POSIX socket；就绪后就地 `sendto`，短写语义一致 |
| Windows IOCP | 少见 | `WSASend` 会把整块缓冲挂进内核发送队列，通常一次性完成，流控留在内核 |
| kqueue | 常见 | 与 POSIX 语义一致；后端已在 macOS CI 跑通全量测试，短写本身未单独实测 |

回归测试 `server.test.响应发生部分写入时续发剩余字节，不静默丢弃` 用 32 MB
载荷加一个先读 4 KB 再停 200 ms 的慢读者逼出短写。几 KB 的响应在回环上会被
内核一次吞下，测不到这条路径——这也是第一版测试（512 KB）「绿了但没有验证力」
的原因。我用变异测试确认它有牙：临时禁用续发分支后，Linux 侧立刻变红
（Windows 侧仍绿，与上表的语义差异一致），恢复后续发则两边全绿。

已知容量上限：非文件响应受每连接 `send_buf`（16 KB）限制，超出会返回 500；
文件响应走动态缓冲区不受此限。这是容量问题，不是正确性问题。

## 连接管理：并发上限、空闲超时、优雅停机

server 层面向生产的几个硬缺口已补齐，均可经 `Config` 调参：

```zig
try mox.serve(.{
    .gpa = gpa,
    .address = addr,
    .routes = routes,
    .max_connections = 1024,   // 并发连接上限
    .idle_timeout_ms = 60_000, // 两次请求间最长静默
    .accept_backoff_ms = 50,   // accept 失败退避
    .shutdown_timeout_ms = 5_000,
});
```

- **并发上限**：达到 `max_connections` 后不再 `accept`，新连接留在内核
  listen backlog 里排队（天然背压），而不是无限制地吃内存 / fd。有连接
  释放腾出名额后自动恢复接受。
- **accept 失败退避**：`accept` 因 `EMFILE` / `ENFILE`（fd 耗尽）失败时，
  **不能立即重试**——失败→立即重试会在错误持续期间把循环线程 CPU 打满。
  改为用一个短定时器（`accept_backoff_ms`）延时重试，期间照常服务已有连接。
- **空闲超时**：每个连接在「等下一个请求」期间挂一个 `idle_timeout_ms` 的
  定时器；到点仍未收到新数据即关闭，防半开连接 / 慢速攻击长期占资源。
  `0` 表示不设。
- **优雅停机**：`loop.run()` 退出后，server 不再粗暴丢弃在飞连接，而是：
  停止接受 → 逐个 `abortConn`（按连接所处阶段取消对应的在飞 recv/send/
  file-read，空闲连接直接关闭）→ `Loop.drainOpen` 继续驱动循环把收尾完成包
  收干净，直到所有连接释放或超过 `shutdown_timeout_ms`。

**取消的释放时机**（关键正确性点）：中止一个带在飞操作的连接时，**绝不**
同步 `destroy`——后端可能还持有指向 `conn.recv`/`conn.send` 的节点，立即释放
就是 use-after-free。正确做法是 `loop.cancel` 那个操作，把连接释放在它的完成包
回来时（`freeConnCtx`）做。`Connection.state` 记录当前阶段，停机时据此决定
该取消哪个节点。

三条回归测试各有洞：达上限不投递 accept、静默连接被空闲超时关闭、`drainOpen`
停机后关闭在飞连接。都用变异测试确认有验证力（分别禁用容量守卫 / idle 定时器
挂载 / `drainOpen` 的回调派发，均明确变红而非挂死）。

## UDP 与 DNS：原生异步，不再占用线程池

UDP 数据报原先只能在 `Work` 池里用阻塞 `recvfrom` 实现。这个组合有一个致命
后果：`recvfrom` 在没有数据报时会**永不返回**，而 `Pool.shutdown()` 无超时地
`join()` 全部线程，于是进程关不掉。默认只有 4 个池线程，**四次无应答的 DNS
查询就能把它们占满**，之后连文件读取都会饿死。实测（Windows 与 Linux 各自
提交一次无应答接收再 `deinit`）两边都挂死。

现在 UDP 走真正的内核异步，与 TCP 同级：

| 后端 | 提交方式 | 状态 |
|---|---|---|
| io_uring | `prep_recvmsg` / `prep_sendmsg` | 实测通过 |
| IOCP | `WSARecvFrom` / `WSASendTo` | 实测通过 |
| epoll | `EPOLL.IN` / `EPOLL.OUT` + 就地 `recvfrom` / `sendto` | WSL 实测通过 |
| kqueue | `EVFILT_READ` / `EVFILT_WRITE` + 就地 `recvfrom` / `sendto` | macOS CI 实测通过 |

四个后端都改走了内核异步，这个挂死在结构上被消除；四者都有运行时实测，
其中 kqueue 的证据来自 macOS arm64 CI，BSD 目标仍只做编译校验。

设计上沿用既有分层，没有侵入核心：

- `Io.VTable` 新增两个**可选**入口（`udpRecv` / `udpSend`），后端不提供即为
  `null`，能力层自动回落线程池 —— 老后端不会因为新增字段而失效。
- 节点自带 `hdr: [32]usize` 作为后端私有存储：`msghdr` / `iovec` / `sockaddr`
  必须活到完成包被收割，而 64 字节的 `Scratch` 早已被 `OVERLAPPED` + `WSABUF`
  占满。提交时若失败则降级为线程池重试一次，绝不在调用栈内同步回调。
- 异步路径**复用 `Work` 里那个 Completion 作为身份锚点**，因此完成包的收割、
  取消、`@fieldParentPtr` 反查与阻塞路径完全一致，`dns.zig` 一行没改。

两个踩到的真实契约，都值得记下来：

1. **重叠套接字上 `WSARecvFrom` / `WSASendTo` 的 `lpNumberOfBytes...` 必须传
   `NULL`**，完成字节数来自完成包。传了栈指针会直接 `ERROR_INVALID_PARAMETER`。
   TCP 的 `WSARecv` 对此容忍，`RecvFrom` 不容忍。
2. **`CreateIoCompletionPort` 关联是每个 socket 一次的动作**：对同一 socket
   重复关联返回 `ERROR_INVALID_PARAMETER`(87)。所以关联放在 `Udp.create`，
   不在每次提交时做。

回归测试 `tests.test.无人应答的 UDP 接收走内核异步路径，且停机不被线程池拖住`
一次提交 8 个（故意超过池的 4 个线程），断言每个节点的 op 都仍是 `udp_recv`
——哪天悄悄回退到线程池就会红 —— 再断言 `deinit` 耗时小于 1 秒。

DNS 端到端实测：`example.com` 经 223.5.5.5 解析，Linux 20 ms、Windows 157 ms，
两边都拿到应答并干净退出。

## 套接字选项、半关闭与关停语义

`Loop.setSockOpt(socket, opt, value)` 暴露四个跨平台语义选项，后端各自映射到
本平台的 `setsockopt`：

| `SockOpt` | Linux | Windows | BSD/Darwin |
|---|---|---|---|
| `tcp_nodelay` | `TCP_NODELAY` | `TCP_NODELAY` | `TCP_NODELAY` |
| `keepalive_idle` | `TCP_KEEPIDLE` | `TCP_KEEPIDLE` | `TCP_KEEPIDLE` / Darwin `TCP_KEEPALIVE` |
| `recv_buf` | `SO_RCVBUF` | `SO_RCVBUF` | `SO_RCVBUF` |
| `send_buf` | `SO_SNDBUF` | `SO_SNDBUF` | `SO_SNDBUF` |

只收录三家后端都能一致表达的那几个——语义不齐的选项宁可先不做，也好过在
某个平台上静默变成另一件事。`setSockOpt` / `shutdownSend` 都是 `VTable` 里的
**可选**入口，后端不提供时返回 `error.Unsupported`，调用方据此降级。

两个真实差异，都是编译期撞出来的：

- **Winsock 的 `SO_*` / `TCP_*` 常量在 std 里没有导出**（`std.os.windows.ws2_32`
  只给了 `IPPROTO`），而且取值与 Linux 不同名同值的直觉相反。只能按 Windows
  SDK 补定义，不能借用 Linux 的编号。
- **Darwin 的保活空闲选项叫 `TCP_KEEPALIVE`，FreeBSD/NetBSD 叫 `TCP_KEEPIDLE`**。
  语义相同、常量名不同，按目标平台 `builtin.os.tag` 编译期分派。

**半关闭**接在响应收尾路径上：决定不复用连接时，先 `shutdownSend`（`SHUT_WR` /
`SD_SEND`）再 `close`。直接 `close` 有可能在响应还躺在内核发送缓冲里时被 RST
掉，对端会看到连接被重置而不是干净的 EOF。后端不支持时退回原来的直接关闭，
行为不退化。

**`drainRetired` 的超时契约**已经写死并做成可观测的：

- `max_wait_ms` 到点即返回，不再等待。
- 仍留在 `retired` 里的节点**没有**被 `dispose`，其 `context` 归属转交调用方；
  调用方必须保证这些 context 在自身作用域结束前不被释放，否则是悬垂指针。
- `Loop.deinit` 不替它们收尾也不报错——后端可能在进程退出前才投递最后一个
  完成包。
- 超时会自增 `loop.retired_timeouts`。正常关停应当为 0，调用方可以据此断言，
  而不是靠日志猜测。

## 并发压力测试

三条测试专门打竞态，且都用变异测试确认过"有牙"（临时禁用被测机制必须变红）：

| 测试 | 压什么 | 变异验证 |
|---|---|---|
| 跨线程 `submit` 洪泛 | 8 线程 × 256 个定时器，一个都不能丢 | 去掉 `notify` → 循环唤不醒，测试挂死（exit 143） |
| `Work` 池饱和 | 64 个任务压 4 个池线程，全部完成且停机有界 | — |
| 取消竞态 | 64 个定时器入堆后立刻取消，只回收一次、零回调 | — |
| `drainRetired` 超时 | 永不回来的取消项必须记一次超时且不被回收 | 去掉计数 → `expected 1, found 0` |

第 1 条有个细节值得记：洪泛测试里**不能靠外部线程翻 `running` 停机**，那唤不醒
已经阻塞在 `waitBatch` 里的循环线程。必须由某个完成回调（或同线程定时器）在
循环线程内调 `stop`。

## 验证状态

**当前四个后端都有运行时实测**：Windows IOCP、Linux io_uring、Linux epoll、
macOS arm64 kqueue 均在 CI 中跑全量测试。

| 目标 | 架构 | 状态 |
|---|---|---|
| Windows（IOCP） | x86_64 / arm64 | 全量测试、真包依赖、性能尺子均在 CI 中运行；子进程四场景本地实跑；`Signal` / UDS / 异步文件 I/O / `sendfile` 明确返回 `Unsupported` |
| Linux（io_uring + epoll） | x86_64 / arm64 | 同上；`zig build test` 同时跑 epoll 专属测试，WSL 开发机实跑 71/76（含子进程、信号、WatchFd、目录操作、UDS、异步文件 I/O 与 sendfile；uring 与 epoll 双后端各跑一遍） |
| macOS（kqueue） | arm64 | CI 真跑全量 kqueue 运行时测试，逐条隔离 + 20 秒看门狗 |

BSD 不在覆盖范围内。

CI（`.github/workflows/test.yml`）分两块：

- `runtime` job 用矩阵跑四种组合 —— `windows-latest`、`windows-11-arm`、
  `ubuntu-latest`、`ubuntu-24.04-arm`，每格都做：全量测试、io 模块根测试、
  示例构建、真包依赖验证、三把性能尺子，并交叉编译校验另一架构的目标。
  Linux 格会先打印 `/proc/sys/kernel/io_uring_disabled`，便于在托管 runner
  禁用 io_uring 时区分代码问题与环境问题。
- `macos` job 在真实 macOS arm64 runner 上跑 kqueue 全量测试。每条 io
  测试独立编译、独立 20 秒看门狗，逐条报告挂死/失败及其断言输出，避免
  一条卡住吞掉其余结果；另做示例构建、真包依赖验证与 x86_64 交叉编译校验。


## 内存文件（VFS）

`Loop.memory_fs` 可以挂载编译期资源或测试替身，静态文件路由会优先命中它，
不再 open/read/close 真实磁盘（池线程只做一次 memcpy，不做阻塞 I/O）：

```zig
var loop = try mox_io.open(gpa);
defer loop.deinit();
try loop.mountMemory("/assets/app.css", @embedFile("assets/app.css"));
```

- 路径按字节精确匹配，不做任何规范化；`path` / `bytes` 由调用方持有，
  `mountMemory` 不复制、也不负责释放，其生命周期必须长于本循环。
- 同名路径再次 `mount` 会覆盖旧条目（`mount` 只在初始化时调用，不在热路径增删）。
- `Loop.fileSize` 命中内存表时直接返回长度；未命中才回落到后端的真实文件读取。
- 缓冲区小于文件内容时 `ReadFile.getResult()` 返回 `error.BufferTooSmall`，不静默截断。

### 编译期嵌入整个目录

`@embedFile` 不能跨包路径，逐个手写 `mountMemory` 也麻烦。mox 在包里带了
一个 build helper，把目录递归内联成一份生成的 Zig 模块（源码见
`src/embed.build.zig`，结构命名沿用 lovez 的 `Embed`）：

```zig
// 调用方 build.zig
const mox_build = std.Build.lazyImport(b, @This(), "mox") orelse
    @panic("mox 依赖未就绪");
const embed = mox_build.addEmbed(b, .{
    .dirs = &.{
        .{ .dir = "assets", .mount = "/assets" },
        .{ .dir = "templates", .mount = "/tmpl" },
    },
    .git_rev = true, // 可选：注入构建时版本戳
});
exe.step.dependOn(embed.step);
exe.root_module.addImport("mox_vfs", embed.module);
```

生成模块导出 `Embed.files`（按路径排序）、`get` / `exists` / `list`、
`git_rev`，以及 `mount(loop)`。运行时把资源挂进事件循环：

```zig
const embed = @import("mox_vfs");

// 直接用 Loop：泛型 mount 可以自动推导。
var loop = try mox_io.open(gpa);
defer loop.deinit();
try embed.mount(&loop);

// 用 mox.serveWith：钩子要具体函数指针，包一层把 anytype 具体化。
fn mountAll(l: *mox_io.Loop) anyerror!void { return embed.mount(l); }
try mox.serveWith(.{ .gpa = gpa, .address = addr, .routes = routes }, mountAll);
```

`serve(config)` 保持不变，转调 `serveWith(config, null)`；不挂 VFS 的用户
零改动。之后返回 `Response{ .file_path = "/assets/app.css" }` 就会命中内存表。

约定与校验（都在构建期完成，写错直接编译失败）：

- `mount` 前缀必须以 `/` 开头，且与 HTTP 请求路径一致；不填前缀时
  目录内相对路径本身必须以 `/` 开头。避免生成运行时永远匹配不到的 key。
- 路径分隔符统一成 `/`；重复路径、超过 `max_file_size`（默认 8 MiB）
  直接让构建失败。
- `git_rev = true` 时注入 `"<short-rev>"`，工作树有改动加 `-dirty`；
  git 不可用或不在仓库里回落 `"dirty"`，不会让构建失败。
- `Embed` 是**静态数据源**，`Loop.memory_fs`（`MemoryFs`）是运行时可挂载
  的表；`mount()` 只负责把前者灌进后者，两者不是可互换的实现。

`examples/consumer/` 是这套用法的真包依赖夹具：通过 `b.dependency("mox")`
拿模块、用 `addEmbed` 生成资源、再走 `serveWith` 挂载；实测
`GET /assets/a.txt` 返回内存中的 `hello-from-vfs`。

## 说明

- 代码注释统一使用中文。
- 不使用 `std.Io` 的异步运行时句柄；`std.Io.net.IpAddress` 仅作为地址值类型出现在接口签名里。
- 文件读写都通过 `Work` 池在后台线程阻塞执行，完成回调回到循环线程。
  四个结构形状一致，都是内嵌 `Work` 节点的零分配结构，用法统一为
  `xxx.init(...)` + `loop.add(&xxx.work.c)`，都不在 `Loop` 上开便捷入口：
  - `ReadFile`：缓冲区由调用方提供，命中 `memory_fs` 时只做一次 memcpy；
    `initAt(...)` 可指定起始偏移做随机访问（分段读大文件的基础），
    偏移超出文件长度时短读为 0 字节而不报错。
  - `WriteFile`：默认整文件覆盖写；`initAppend(...)` 追加到末尾并保留既有内容。
  - `TruncateFile`：把文件截断到指定长度。
  - `DeleteFile`：删除文件。平台层实现返回 `void`，所有失败都被吞掉
    （含文件不存在与权限不足），因此它不会报错——需要可靠删除请自行先 `fileSize` 探测。
  `VTable` 上对应的 `readFileInto`/`readFileAt`/`writeFileAll`/`appendFile`/
  `truncateFile`/`deleteFile` 是所有后端共用的兜底，没有可移植的原生异步接口。

## 许可证

MIT，见 [LICENSE](LICENSE)。
