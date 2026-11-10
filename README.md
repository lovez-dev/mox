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
    file.zig        阻塞文件读兜底
    tests.zig       事件循环测试
    queue.zig       就绪 FIFO
    timer.zig       定时器有序表
    pool.zig        `Work` 线程池
    udp.zig         UDP 可选能力
    dns.zig         DNS 可选能力（建立在 UDP 之上）
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
等都只是在设计上被这套机制覆盖，**并未实现**，能力表当前只有 UDP 与 DNS
两项。

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
| Windows（IOCP） | x86_64 / arm64 | 全量测试、真包依赖、性能尺子均在 CI 中运行 |
| Linux（io_uring + epoll） | x86_64 / arm64 | 同上；`zig build test` 同时跑 epoll 专属测试（44/44），WSL 开发机亦实跑 |
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
  `ReadFile`（缓冲区由调用方提供，命中 `memory_fs` 时只做一次 memcpy）与
  `WriteFile`（整文件覆盖写，`VTable.writeFileAll` 是所有后端共用的兜底，
  没有可移植的原生异步写接口）形状对称，都是内嵌 `Work` 节点的零分配结构。
  两者都不在 `Loop` 上开便捷入口，用法是 `xxx.init(...)` + `loop.add(&xxx.work.c)`。

## 许可证

MIT，见 [LICENSE](LICENSE)。
