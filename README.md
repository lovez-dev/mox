# mox

一个基于**完成 / 回调**模型的 Zig Web 框架与可复用 I/O 库。

- **不是 async/await**：每个操作是一块由调用方持有、内嵌的 `Completion` 节点，
  交给 `Loop.add`，完成后由 `Loop.run` 回填结果并回调。没有 future、没有纤程栈、
  没有每连接分配之外的额外开销。
- **自有 I/O 抽象**：`mox_io.Io{ userdata, vtable }`。上层只认这个接口，
  不接触任何平台类型；新增后端 = 填满一个 `VTable`。
- **手写原生后端**：Linux `io_uring`（默认，失败自动回落 `epoll`）、
  Linux `epoll`、FreeBSD / Darwin `kqueue`、Windows `IOCP`。
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


## Web 框架 API

### 请求上下文（Context）

```zig
ctx.param("name")          // 路径参数  ?[]const u8
ctx.query("page")          // 查询参数  ?[]const u8（零拷贝）
ctx.body                   // 请求体    []const u8（零拷贝）
ctx.request.header("x-token") // 请求头
ctx.json(MyStruct)         // 解析 JSON → std.json.Parsed(T)（框架在请求末统一回收）
ctx.cookie("session")      // 读 Cookie  ?[]const u8（零拷贝）

// URL 解码版本（%XX 与 + → 空格；结果由 ctx.gpa 分配，请求末自动回收）
try ctx.queryDecoded("q")   // !?[]const u8
try ctx.paramDecoded("name")// !?[]const u8
// 非法 % 序列返回 error.InvalidEncoding（不静默丢弃畸形输入）

// 必填版本（缺失时返回对应 error）
try ctx.requireParam("id")   // error.MissingParam
try ctx.requireQuery("q")    // error.MissingQuery
try ctx.requireHeader("auth")// error.MissingHeader
```

### 响应

```zig
// 纯文本
return .{ .body = "ok\n" };

// 自定义状态码 + 头（编译期常量数组在静态区，安全）
return .{
    .status = .created,
    .headers = &.{ .{ .name = "x-custom", .value = "1" } },
    .body = "created\n",
};

// JSON（由上层序列化）
const out = try std.json.Stringify.valueAlloc(ctx.gpa, value, .{});
return mox.Response.withJson(out);

// 文件（内存 VFS 或磁盘）
return .{ .file_path = "/static/index.html", .content_type = "text/html" };

// RFC 9457 Problem Details
return try mox.problem(ctx.gpa, .bad_request, "Bad input", "field 'email' is invalid");

// WebSocket 升级
return mox.Response.upgrade(myWsHandler);

// Server-Sent Events
return mox.Response.sse(mySseHandler);

// Set-Cookie（headers 数组须由 ctx.gpa 分配，栈局部数组在 handler 返回后悬垂）
const ck = try mox.setCookieHeader(ctx.gpa, "session", tok, .{ .http_only = true });
const hdrs = try ctx.gpa.alloc(mox.Header, 1);
hdrs[0] = ck;
return .{ .headers = hdrs, .body = "logged in\n" };
```

### 中间件

```zig
// 内置中间件
mox.logging               // 请求日志（stderr）
mox.jsonLog               // JSON Lines 格式日志
mox.cors(.{               // CORS
    .allow_origins = &.{"https://example.com"},
    .allow_credentials = true,
})
// 请求超时由 Config.request_timeout_ms 统一配置，无独立 timeout 中间件
mox.requireHeader("authorization", "Bearer secret")
mox.rateLimit(.{          // 限流（comptime 静态桶）
    .window_ms = 60_000,
    .max_requests = 100,
})
mox.staticDir("/public/") // 终结 Handler：须挂在 /static/*path 路由上
mox.requestId             // 添加 X-Request-Id 响应头
mox.bodyLimit(1024 * 1024)// 请求体大小限制（1 MB → 413）
mox.cache(3600)           // Cache-Control: public, max-age=N（2xx 响应）

// compose 多个中间件
const app = mox.compose(.{
    mox.requestId,
    mox.cors(.{}),
    mox.bodyLimit(1024 * 1024),
}, myHandler);
```

### 路由分组与前缀

```zig
const api = mox.group("/api/v1", &.{
    .{ .method = .GET,  .path = "/users",     .handler = listUsers },
    .{ .method = .POST, .path = "/users",     .handler = createUser },
    .{ .method = .GET,  .path = "/users/:id", .handler = getUser },
});
const admin = mox.group("/admin", &.{
    .{ .method = .GET, .path = "/metrics", .handler = mox.metricsHandler },
});
// 合并为一个切片
const routes = mox.routes(.{ api, admin });
try mox.serve(.{ .gpa = gpa, .address = addr, .routes = routes });
```

### WebSocket

```zig
fn wsHandler(conn: mox.WsConn, msg: mox.WsMessage) void {
    if (msg.opcode == .text) {
        conn.sendText(msg.data); // 回显（字段是 data，不是 payload）
    }
}
fn handler(ctx: *mox.Context) !mox.Response {
    _ = ctx;
    return mox.Response.upgrade(wsHandler);
}
```

### SSE（Server-Sent Events）

```zig
// 例 1：一次性推送后关闭
fn once(w: mox.SseWriter) bool {
    w.send("update", "data payload");
    w.close();
    return false;
}

// 例 2：定时心跳（本次不 send，靠 tick 按周期再次调用）
var counter: u32 = 0;
fn heartbeat(w: mox.SseWriter) bool {
    w.setTick(1000);            // 每 1s 自动 pump 一次（默认就是 1000ms）
    counter += 1;
    if (counter >= 10) { w.close(); return false; }
    if (counter % 2 == 0) w.send("tick", "ping"); // 有 send 时本轮立即再 pump
    return true;
}

fn handler(ctx: *mox.Context) !mox.Response {
    _ = ctx;
    return mox.Response.sse(heartbeat);
}
```

**驱动规则**（`handler` 返回 `true` 时）：

| 本次 handler 内 | 下一次 pump 由谁触发 |
|---|---|
| 调用了 `w.send()` | 发送完成回调（数据写完立即再调用） |
| 没有调用 `w.send()` | `w.setTick(ms)` 定时器，到点再调用 |

`w.setTick(ms)` 可在任意一次调用里改周期；`setTick(0)` 关闭自动 tick
（此时只有 `send` 能驱动下一次，适合纯事件驱动）。**注意**：本轮调用了
`send()` 时，发送完成回调会立即重新 pump，不等 tick；所以想严格按周期
推送就不要在同一轮里 send 后续数据。SSE 是长连接，框架会自动撤掉 HTTP
请求超时定时器；连接关闭时会同步撤销在飞的 tick，不会留下指向已释放连接
的完成包。

### Multipart

```zig
fn upload(ctx: *mox.Context) !mox.Response {
    const ct = ctx.request.header("content-type") orelse "";
    const boundary = mox.extractBoundary(ct) orelse "";
    var buf: [mox.multipart.max_parts]mox.Multipart = undefined;
    const n = try mox.parseMultipart(ctx.body, boundary, &buf);
    for (buf[0..n]) |part| {
        std.debug.print("field={s} len={d}\n", .{ part.name, part.data.len });
    }
    return .{ .body = "ok\n" };
}
```

### 请求指标

```zig
// 在任意 handler 或定时器中读取快照
const m = mox.getMetrics();
// m.total_requests  m.total_errors  m.active_conns

// 直接注册为路由
.{ .method = .GET, .path = "/metrics", .handler = mox.metricsHandler }
```

### 服务器配置

```zig
try mox.serve(.{
    .gpa           = gpa,
    .address       = try std.Io.net.IpAddress.parse("0.0.0.0", 8080),
    .routes        = routes,
    .max_connections    = 4096,          // 默认 1024
    .max_body_size      = 4 * 1024 * 1024, // 默认 4 MB
    .idle_timeout_ms    = 30_000,        // 默认 60s
    .request_timeout_ms = 10_000,        // 默认 30s
});
```


### HTTP/1.1 能力边界

下面是**刻意的能力边界**，用之前请先看清楚，避免按完整 HTTP/1.1 服务器来预期：

| 能力 | 现状 |
|---|---|
| 请求体 `Content-Length` | 支持；超出 `max_body_size` 返回 413；重复 `Content-Length` 返回 400 |
| `Transfer-Encoding: chunked` 请求 | **支持**。流式解码，可跨多次 `recv` 累积（请求体不受 8 KB 缓冲区限制）；上限仍受 `max_body_size` 约束，畸形编码返回 400 |
| HTTP pipelining | **支持**。一次 `recv` 里的多个请求按序处理，响应同序返回；剩余字节在本次响应发完后继续解析 |
| `HEAD` | **支持**。未注册 HEAD 时自动回退到 GET handler，只发头部、不发 body，`content-length` 仍是真实长度 |
| `Expect: 100-continue` | 未实现 |
| Range / 条件请求 | 未实现 |
| 查询参数 | `ctx.query()` 返回原始切片（未解码）；需要解码用 `ctx.queryDecoded()`，路径参数用 `ctx.paramDecoded()` |
| 响应体大小 | 非文件响应受每连接 16 KB `send_buf` 限制，超出返回 500；文件响应走动态缓冲不受此限 |
| 响应头 | 头名/头值含 CR/LF 会被 `http.serialize` 拒绝（`error.InvalidHeader` → 500），防响应拆分 |
| HTTPS | 不内置，由 nginx 等反向代理终止 TLS |

框架定位是「明文 HTTP/1.1 + 完成式 I/O」，不是全功能 HTTP 服务器。

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
- **Windows 返回 `error.Unsupported`**：理由**不是**「IOCP 没有等就绪这回事」
  ——那是错的，零字节重叠读就是干净的就绪通知（见「分散聚合 I/O 与全方向
  关闭」一节的实测表格）。真实原因是**句柄类型**：`WatchFd` 面向管道、串口、
  `stdin`，而匿名管道和控制台句柄挂不进 IOCP（`ERROR_INVALID_PARAMETER`）。
  socket 就绪等待由 `NetPoll` 承担，Windows 上有实现。

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
   Darwin / FreeBSD 没有这个标志，改为在 `createSocket` 时设 socket 级 `SO_NOSIGPIPE`，一次
   覆盖该 socket 的所有发送路径。
2. **进程级兜底**：`Loop.init` 调用一次 `sigaction(SIGPIPE, SIG_IGN)`，让任何漏掉
   的写路径（标准库内部、第三方代码、写已关闭的管道）都只得到 `EPIPE` 错误。

两道防线都有变异测试证明有效：撤掉 `MSG_NOSIGNAL` 后进程被信号杀死；只靠
`SIG_IGN` 时裸 `write` 能拿到 `EPIPE` 并存活。

## TTY / 终端

`src/io/tty.zig`。只暴露同步接口（终端操作微秒级完成，不需要异步化）：
`isTty` / `getSize` / `save` / `restore` / `setMode`（`cooked` / `raw` / `cbreak`）。

Zig 0.17.1 的 `std.os.windows` 只声明了 `CreateProcessW`，**没有任何 Console API**，
因此 Windows 侧按 Win32 SDK 签名自行 `extern` 声明
（`GetConsoleMode` / `SetConsoleMode` / `GetConsoleScreenBufferInfo` /
`GetStdHandle` / `CreateFileW`）。

| 行为 | POSIX | Windows |
|---|---|---|
| `isTty` | `isatty(fd)` | `GetConsoleMode` 成功即控制台（不需要 ConDrv / NtQueryObject） |
| `getSize` | `ioctl(TIOCGWINSZ)` | `GetConsoleScreenBufferInfo` 的 `srWindow`（**可见窗口**，不是整个屏幕缓冲区 `dwSize`） |
| `raw` | 关 ICANON/ECHO/ISIG 等 | 关 LINE_INPUT/ECHO/PROCESSED_INPUT，开 `ENABLE_VIRTUAL_TERMINAL_INPUT` |
| `cbreak` | 关 ICANON，保留 ECHO/ISIG | **退化为 raw**（见下） |

**Windows 的真实平台差异（实测，不是推测）**：关掉 `ENABLE_LINE_INPUT` 后
`SetConsoleMode` 拒绝保留 `ENABLE_ECHO_INPUT`（`0x5` 失败 / `0x1` 成功）。
即「无行缓冲 + 有回显」在 Windows 输入句柄上无法表达，所以 `cbreak` 在
Windows 输入句柄上等同 `raw`，回显需应用自己写回。POSIX 语义不变。

句柄不是控制台（管道、文件重定向）时：`isTty` 返回 `false`，`getSize` /
`save` / `setMode` 返回 `error.NotATty`（POSIX 侧 `getSize` 是 `error.IoctlFailed`），
不会 panic 也不会静默成功。

Windows 的 `tty.zig` 测试用 `CONOUT$` / `CONIN$` 打开**真实控制台设备**
（stdout 被重定向时依然有效），断言 `isTty == true`、`getSize` 行列 > 0、
`setMode` 后读回的模式位确实变化、`restore` 回到原值。没有控制台的环境
（纯服务容器）拿不到 `CONOUT$`，此时跳过。
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

四个后端都改走了内核异步，这个挂死在结构上被消除；IOCP / epoll / kqueue
（macOS）都有运行时实测。FreeBSD 只做交叉编译校验，**没有运行时验证**；
NetBSD / OpenBSD / DragonFly 不提供支持（`io.zig` 会明确报
`no backend for this target yet`），因为它们的 `Kevent.flags` 宽度与
`sendfile` 签名不同，修到「能编译」不等于「能跑」。

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

| `SockOpt` | Linux | Windows | FreeBSD / Darwin |
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
- **Darwin 的保活空闲选项叫 `TCP_KEEPALIVE`，FreeBSD 叫 `TCP_KEEPIDLE`**。
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
| Windows（IOCP） | x86_64 / arm64 | 全量测试、真包依赖、性能尺子均在 CI 中运行；子进程四场景本地实跑；`Signal` 明确返回 `Unsupported` |
| Linux（io_uring + epoll） | x86_64 / arm64 | 同上；`zig build test` 同时跑 epoll 专属测试，WSL 开发机实跑 59/61（含子进程、信号与 WatchFd；uring 与 epoll 双后端各跑一遍） |
| macOS（kqueue） | arm64 | CI 真跑全量 kqueue 运行时测试，逐条隔离 + 20 秒看门狗 |

FreeBSD（x86_64 / arm64）只做交叉编译校验，没有运行时验证；NetBSD /
OpenBSD / DragonFly 明确不支持，`io.zig` 会报 `no backend for this target yet`。

CI（`.github/workflows/test.yml`）分两块：

- `runtime` job 用矩阵跑四种组合 —— `windows-latest`、`windows-11-arm`、
  `ubuntu-latest`、`ubuntu-24.04-arm`，每格都做：全量测试、io 模块根测试、
  示例构建、真包依赖验证、三把性能尺子，并交叉编译校验另一架构的目标。
  Linux 格会先打印 `/proc/sys/kernel/io_uring_disabled`，便于在托管 runner
  禁用 io_uring 时区分代码问题与环境问题。
- `macos` job 在真实 macOS arm64 runner 上跑 kqueue 全量测试。每条 io
  测试独立编译、独立 20 秒看门狗，逐条报告挂死/失败及其断言输出，避免
  一条卡住吞掉其余结果；另做示例构建、真包依赖验证与 x86_64 交叉编译校验。



## 文件句柄层

路径式 API（`ReadFile(path)` / `WriteFile(path)` / `SendFile(path)`）每次调用都要
重新 `open`/`close`，拿不到句柄复用，也没法按偏移随机读写。文件句柄层补上这一块：

```zig
// 打开一次，拿句柄
var open_node = mox_io.OpenFile.init(io, "/data/log.bin", .read_write);
loop.add(&open_node.work.c);
const h = try open_node.getResult();   // 句柄归调用方，必须自己关

// 按显式 offset 读（同一句柄可反复用，不影响别的读者）
var buf: [4096]u8 = undefined;
var rd = mox_io.ReadFileHandle.init(io, h, 1024, &buf);
loop.add(&rd.work.c);
const bytes = try rd.getResult();      // 文件尾短读不报错

// 按显式 offset 写
var wr = mox_io.WriteFileHandle.init(io, h, 0, "header");
loop.add(&wr.work.c);

// 关闭（同步；同一个实例重复调用安全）
var cf = mox_io.CloseFile.init(io, h);
cf.close();
```

`OpenFile` 的 `FileMode`：`read_only`（必须已存在）、`write_only`（截断并创建）、
`read_write`（不清空，不存在则创建）、`append`（末尾追加）。

**为什么 `CloseFile` 是同步的**：关闭本身不阻塞，没必要进池线程；更重要的是
避免「调用方以为已经关了、其实还在队列里排队」的悬垂窗口。

**关闭的幂等性边界（重要）**：重复调用**同一个** `CloseFile` 实例是安全的
（第二次起直接返回）。但拿同一个**裸句柄值**再 `init` 一个新实例去关，
仍然是未定义行为——POSIX 的 `close()` 与 Win32 的 `CloseHandle()` 都如此，
第二次可能误关被系统复用的别人的 fd/句柄。句柄所有权只能由调用方自己维护，
框架无法替你判断一个 `usize` 是否还有效。

**生命周期契约**：`OpenFile` 成功后句柄归调用方，节点不会替你关（否则你拿到
的是已失效句柄）。`path` / `bytes` / `buf` 都由调用方持有，必须活到回调触发为止。

**错误语义与其它后端一致**：`read_only` 打开不存在的文件返回 `error.FileNotFound`，
权限不足返回 `error.AccessDenied`（Windows 侧把 `GetLastError` 的
`ERROR_FILE_NOT_FOUND` / `ERROR_PATH_NOT_FOUND` / `ERROR_ACCESS_DENIED` 翻译成
同一套语义错误，而不是一律 `OpenFailed`）。

**实现差异**：Linux 用 `pread`/`pwrite`，BSD/Darwin 用 `pread`/`pwrite`，
Windows 用 `SetFilePointerEx` + `ReadFile`/`WriteFile`。Windows 刻意**不用**
`OVERLAPPED`——那会把文件 I/O 接到 IOCP 上变成异步语义，与另外两个后端的
同步 `Work` 池语义不一致。

句柄在手时还能做元数据与同步，不用再走一遍路径（也就没有「open 之后路径
被换掉」的竞态）：

```zig
// 取元数据：类型 / 大小 / mtime
var st = mox_io.StatFile.init(io, h);
loop.add(&st.work.c);
const s = try st.getResult();          // s.size, s.kind, s.mtime_ms

// 截断到指定长度
var trunc = mox_io.SetFileSize.init(io, h, 4096);
loop.add(&trunc.work.c);

// 刷到磁盘（fsync / FlushFileBuffers）
var sync = mox_io.SyncFile.init(io, h);
loop.add(&sync.work.c);
```

`statFile` 各平台都是**直接作用于句柄**：Linux 用 `statx` 的 `AT_EMPTY_PATH`
形式（路径传空串、`dirfd` 就是句柄本身），BSD/Darwin 用 `fstat`，
Windows 用 `GetFileInformationByHandle`。

`syncFile` 的测试**只能证明调用链通、错误没被吞掉**，不能证明数据真的落盘——
那要断电才验证得了。别把它当持久化保证的证明。

## 目录流与符号链接

`listDir(path)` 一次性把整个目录塞进调用方缓冲：目录大时要么截断、要么给一个
巨大缓冲。目录流把目录变成可增量读的句柄，和文件句柄那套对称：

```zig
var od = mox_io.OpenDir.init(io, "/var/log");
loop.add(&od.work.c);
const dh = try od.getResult();       // 目录句柄归调用方

var cd = mox_io.CloseDir.init(io, dh);
defer cd.close();

// 每次读一小批，读到空切片为止
while (true) {
    var batch: [32]mox_io.DirEntry = undefined;
    var rd = mox_io.ReadDirHandle.init(io, dh, &batch);
    loop.add(&rd.work.c);
    const entries = try rd.getResult();
    if (entries.len == 0) break;
    for (entries) |e| {
        // e.slice(), e.is_dir
    }
}
```

**这里有个非平凡的正确性问题**：Linux 的 `getdents64` 一次返回**一整批**条目，
内核的文件偏移直接前移到批次末尾。如果调用方缓冲装不下整批，剩下的条目就丢了
——下一次读从批次末尾继续，中间那段永远读不到。

Linux 的解法：消费完能放下的条目后，把偏移 `lseek` 回**最后一个已消费条目**
记录的 `d_off`，下次从那里继续。测试里专门有一条用「2 个槽位读 5 个条目」来打这个。

BSD/Darwin 用的是 `opendir` + `readdir`：游标状态由 `DIR*` 自己维护，每次调用
只消耗一条，天然没有这个问题。（第一版曾用 `open(2)` + `getdirentries` + `lseek`
回退，**macOS CI 直接抓爆**：`expected 5, found 40` —— `seekoff` 回退在那里
会无限重复同一批条目。换成 `opendir` 才真正稳。）

Windows 不存在这个问题：`FindFirstFileW`/`FindNextFileW` 是逐条推进的枚举器，
只需记住「已取到但还没交付」的那一条。

符号链接读取：

```zig
var rbuf: [1024]u8 = undefined;
var rl = mox_io.ReadLink.init(io, "/etc/localtime", &rbuf);
loop.add(&rl.work.c);
const target = try rl.getResult();
```

目标比缓冲长时报 `error.NameTooLong` 而不是静默截断——被切掉的路径是**错的**，
比报错更危险。对普通文件调用报 `error.NotASymLink`。

Windows 侧读链接走 `FSCTL_GET_REPARSE_POINT`，同时支持
`IO_REPARSE_TAG_SYMLINK`（符号链接）与 `IO_REPARSE_TAG_MOUNT_POINT`（junction）。

## 跨线程投递与批量等待

### `Async`：从任意线程把回调送回循环线程

```zig
var node = mox_io.Async.init(&onWorkDone, my_ctx);

// 在别的线程里：
loop.postAsync(&node);          // 线程安全，内部压栈 + 唤醒循环
```

回调在**循环线程**上执行，因此可以放心 `loop.add(...)` 继续提交操作，
不需要任何额外同步。

与 `Work` 的分工：

| | 在哪个线程跑 | 用途 |
|---|---|---|
| `Work.func` | 池线程 | 阻塞 I/O（文件、DNS 等） |
| `Async.func` | 循环线程 | 「必须串行在循环线程上」的动作 |

没有 `Async` 时，别的线程想让循环做点事只能绕 `Work` 池——多一次线程切换，
而且语义上是「去池里干活」而不是「回循环线程」。

**`notify` 的真实作用**：`run` 里 `waitBatch` 的超时被钳在 200ms（这是 HTTP
高并发不断崖的关键），所以即使完全不唤醒，循环也会在 200ms 内自己醒来处理
投递项。`notify` 的价值是把延迟从「最多 200ms」压到接近 0，不是正确性必需。
测试里专门有一条要求「循环已阻塞在 waitBatch 时，投递在 60ms 内生效」——
删掉 `notify` 这条就红。

### `Group`：并发发起、只被通知一次

```zig
var group = mox_io.Group.init(&onAllDone, ctx, 2);

recv1.c.callback = &mox_io.Group.childCallback;
recv1.c.group_ctx = &group;
recv2.c.callback = &mox_io.Group.childCallback;
recv2.c.group_ctx = &group;

loop.add(&recv1.c);
loop.add(&recv2.c);
// 两个都完成后 onAllDone 被调用一次
```

**语义**：子操作出错**不会**让 group 提前结束——即使某个失败，也等其余都
结束才回调。调用方在回调里自己检查各子操作的结果。这是刻意的：批量场景下
「一个失败就放弃」通常不是想要的，而且提前回调会让调用方读到还没填好的结果。

## 分散聚合 I/O 与全方向关闭

### `NetSendMsg` / `NetRecvMsg`：一次系统调用收发多个缓冲

```zig
// 一次 sendmsg：帧头 + 载荷在同一次系统调用里发出，中间不会被插入
const bufs = [_][]const u8{ frame_header, payload };
var sm = mox_io.NetSendMsg.init(socket, &bufs);
loop.add(&sm.c);
const sent = try sm.getResult();

// 一次 recvmsg：数据摊到两个缓冲，省掉一次拷贝
var head: [4]u8 = undefined;
var body: [4096]u8 = undefined;
const rbufs = [_][]u8{ &head, &body };
var rm = mox_io.NetRecvMsg.init(socket, &rbufs);
loop.add(&rm.c);
const n = try rm.getResult();
```

**为什么不用两次 `send`**：两次 `send` 之间可能被其他写入插入——多路复用
（HTTP/2、WebSocket 并发帧）时这会直接破坏帧边界。`sendmsg` 的 iovec 保证
多段内容在一次系统调用里连续发出。

**`recvmsg` 的语义要点**：内核按 iovec 顺序填满，第一个缓冲写满了才继续写
第二个。上面例子里 `head` 只有 4 字节，多出来的数据**必须**溢到 `body`——
测试专门打这个：如果实现退化成两次独立 `recv`，`received` 会报 4 而不是 11。

**上限**：单个节点最多 32 段（`MSG_HDR_WORDS` 预算约束，见下）。超过报
`error.TooManyBuffers`。

**`hdr` 暂存区**：`msghdr` 与 iovec 数组必须活到完成包被收割，不能放栈上。
节点自带 `hdr: [MSG_HDR_WORDS]usize` 就是干这个的，调用方不用管。

后端差异：

| 后端 | 实现 | 异步？ |
|---|---|---|
| Linux io_uring | 原生 `IORING_OP_SENDMSG`/`RECVMSG` | 是 |
| Windows IOCP | `WSASend`/`WSARecv` 多 `WSABUF` | 是 |
| Linux epoll / BSD kqueue | 同步 `sendmsg`/`recvmsg` | 否（提交时即完成） |

epoll/kqueue 没有「异步 sendmsg」这种原语（它们的模型是「等可写再自己发」），
所以走同步路径。语义完全一致，只是不占异步槽位。

### `NetShutdown`：按方向关闭

```zig
// 只关写：对端读到 EOF，但仍可以继续给我们发
loop.add(&(mox_io.NetShutdown.init(socket, .write).c));

// 双向关（协议错误后强制断开）
loop.add(&(mox_io.NetShutdown.init(socket, .both).c));
```

与 `NetClose` 的区别：`shutdown` 只改连接状态、**不释放句柄**，之后仍可以
`recv` 探测对端是否已关，也可以正常 `close`。

### `NetPoll`：等 socket 可读/可写

```zig
var poll = mox_io.NetPoll.init(socket, .recv);   // 或 .send
loop.add(poll.completion());
try poll.getResult();
_ = poll.ready().read;
```

这是 `WatchFd` 的语义化封装——底层完全一样，只是调用方想说的是「等这个
socket 能收了」而不是「等这个 fd 的 read 位」。

**一次性通知**：回调触发后若要继续等，必须重新 `init` + `add`。

**Windows 上可用**（v0.12.1 起）。实现方式是投一个零字节的 `WSARecv`
（等可读）或 `WSASend`（等可写）：缓冲区长度为 0 时内核不搬数据，但仍然在
**真的能读/能写**时才投递完成包——这就是就绪通知。走既有 IOCP 通道，不新增
线程，也不需要 `WSAPoll`。

> 这条是实测出来的，不是推测。我最初在文档里写「IOCP 是完成式不是就绪式，
> 做不到就绪通知」——**那句话是错的**，探针推翻了自己。

### `WatchFd` 在 Windows 上仍然不支持，但理由不同

`WatchFd` 和 `NetPoll` 是**两个独立节点**，因为两个平台的最优实现不同。
`WatchFd` 在 Windows 上返回 `Unsupported`，真实限制是**句柄类型**：

| 句柄 | 能挂 IOCP | 零字节重叠读当通知 |
|---|---|---|
| TCP socket | 能 | 有效（已实测） |
| 命名管道（`FILE_FLAG_OVERLAPPED`） | 能 | 有效（已实测） |
| 匿名管道 | 不能（`ERROR_INVALID_PARAMETER`） | — |
| 控制台 `CONIN$` | 不能（`ERROR_INVALID_PARAMETER`） | — |

`WatchFd` 的文档场景正是「管道、串口、`stdin` 这类 mox 不认识语义的 fd」，
而这几类在 Windows 上恰恰挂不进 IOCP。socket 是能挂的那一类，所以 `NetPoll`
单独有实现。

顺带说明为什么不用 `WSAPoll`：它需要一条**阻塞在 `WSAPoll` 上的线程**，再
把结果投回循环——那等于塞第二条事件循环，与「单线程事件循环 + 完成包」的
架构冲突。零字节重叠 I/O 没有这个问题。

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

### 目录与元数据操作

`Loop` 暴露 6 个**同步**方法（阻塞调用，在 `Work` 池线程里跑才不卡循环）：

```zig
pub fn makeDir(self: *Loop, path: []const u8, mode: u32) !void
pub fn removeDir(self: *Loop, path: []const u8) !void
pub fn rename(self: *Loop, old_path: []const u8, new_path: []const u8) !void
pub fn symLink(self: *Loop, target: []const u8, link_path: []const u8) !void
pub fn statPath(self: *Loop, path: []const u8) !Stat
pub fn listDir(self: *Loop, path: []const u8, buf: []DirEntry) !usize
```

对应的异步节点（`MakeDir`、`RemoveDir`、`Rename`、`SymLink`、`StatPath`、`ListDir`）
都内嵌 `Work`，用法与文件读写一致：`xxx.init(...)` + `loop.add(&xxx.work.c)`。

`Stat` 返回文件大小、类型（file/dir/symlink/other）、修改时间（Unix 毫秒时间戳）；
`listDir` 填充调用方提供的 `DirEntry` 数组，返回实际条目数（超过数组长度时截断，
不报错）。

### Unix domain socket

三个新方法支持 `AF_UNIX` + `SOCK_STREAM`（Windows 返回 `error.Unsupported`）：

```zig
pub fn createUnixSocket(self: *Loop) !Handle
pub fn bindUnix(self: *Loop, socket: Handle, path: []const u8) !void
pub fn connectUnix(self: *Loop, socket: Handle, path: []const u8, scratch: *Scratch) !void
```

`bindUnix` 在文件系统创建 socket 文件；路径已存在时返回 `error.PathAlreadyExists`。
`connectUnix` 是同步阻塞调用，不返回节点；需要异步连接请用 `Work` 包装。
`NetRecv`/`NetSend`/`NetClose` 对 UDS 和 TCP 一视同仁。

### io_uring 原生异步文件 I/O

**仅在 Linux io_uring 后端可用**，其它后端 `vtable.readFileAsync` / `writeFileAsync` 为 `null`。

```zig
pub const ReadFileAsync = struct {
    c: Completion = .{ .op = .file_read },
    path: []const u8,      // 必须 NUL 结尾
    buf: []u8,
    offset: u64 = 0,
    len: usize = 0,        // 回填：实际读到的字节数

    pub fn init(path: [:0]const u8, buf: []u8) ReadFileAsync
    pub fn initAt(path: [:0]const u8, offset: u64, buf: []u8) ReadFileAsync
    pub fn getResult(self: *const ReadFileAsync) ![]const u8
};

pub const WriteFileAsync = struct {
    c: Completion = .{ .op = .file_write },
    path: []const u8,      // 必须 NUL 结尾
    bytes: []const u8,
    offset: u64 = 0,
    written: usize = 0,

    pub fn init(path: [:0]const u8, bytes: []const u8) WriteFileAsync
    pub fn getResult(self: *const WriteFileAsync) !usize
};
```

内部通过 `IOSQE_IO_LINK` 把 `openat` → `read`/`write` → `close` 三条 SQE 链起来，
一次提交、一次完成；中间 fd 由内核在链内传递，不经过用户态。调用方回落逻辑示例：

```zig
var async_read = mox_io.ReadFileAsync.init(path, buf);
if (loop.io.vtable.readFileAsync == null) {
    // 回落 Work 版本
    var sync_read = mox_io.ReadFile.init(path, buf);
    loop.add(&sync_read.work.c);
} else {
    loop.add(&async_read.c);
}
```

### 零拷贝文件→socket（sendfile）

```zig
// 同步版本（立即返回已发送字节数或错误）
pub fn sendFile(self: *Loop, socket: Handle, path: []const u8, offset: u64, count: usize) !usize

// 异步版本（内嵌 Work，通过 loop.add 提交）
pub const SendFile = struct {
    work: Work,
    socket: Handle,
    path: []const u8,
    offset: u64 = 0,
    count: usize = 0,
    sent: usize = 0,

    pub fn init(socket: Handle, path: []const u8) SendFile
    pub fn initAt(socket: Handle, path: []const u8, offset: u64, count: usize) SendFile
    pub fn getResult(self: *const SendFile) !usize
};
```

Linux 用 `sendfile(2)`、FreeBSD/macOS 用 `sendfile(2)` 或 `sendfile()`（签名不同，
已做平台适配）、Windows 用 `TransmitFile`。不支持的平台返回 `error.Unsupported`。

`count = 0` 表示发送整个文件（从 `offset` 到末尾）；非零时精确发送 `count` 字节。

## 性能对标

### 对标目标

- **zio**：Zig 事件循环库（io_uring/epoll/kqueue/IOCP），commit `e9a11d8`
- **fasthttp**：Go 高性能 HTTP 服务器

### Linux (io_uring)

**环境**：WSL2 Ubuntu、Ryzen 7840HS、32GB RAM  
**服务端**：`mox` HTTP echo（GET /，返回 12 字节）、`idle_timeout_ms=0`  
**客户端**：本机 Python `aiohttp` keep-alive 连接池  
**压测工具**：自写 Python 异步客户端，连续发送 N 轮请求，统计吞吐量

| 并发数 (c) | 请求总数 | mox (ops/s) | zio (ops/s) | fasthttp (ops/s) |
|-----------|---------|------------|------------|-----------------|
| 100 | 1M | 289,330 | - | - |
| 200 | 2M | 287,442 | - | - |
| 500 | 5M | 277,008 | - | - |
| 1000 | 10M | 265,252 | - | - |

**结论**：mox 在 c≤1000 保持稳定吞吐（265k-289k ops/s），无断崖；idle 超时钳制修复前
c=450 会断崖至 491 ops/s（已在 commit `fc1b579` 修复）。zio/fasthttp 数据待补充。

### Windows (IOCP)

**环境**：Windows 11、Ryzen 7840HS、32GB RAM  
**服务端**：`mox` HTTP echo（同上）  
**客户端**：自写 Zig IOCP 客户端（Windows IOCP ConnectEx + 同步 recv/send keep-alive）  
**压测工具**：编译期指定 `CONNS`/`ROUNDS`，单进程发完统计耗时

| 并发数 (c) | 请求总数 | mox (ops/s) | 备注 |
|-----------|---------|------------|------|
| 200 | 1M | 183,925 | 本机 loopback，5437ms |
| 500 | 2.5M | 163,431 | 15297ms |
| 1000 | 5M | 147,807 | 33828ms |
| 2000 | - | 挂死 | 预期：`max_connections=1024` 背压 |

**结论**：Windows/IOCP 路径无断崖，c≤1000 稳定完成；c=2000 挂死是预期行为
（`max_connections=1024`，超额连接在内核 backlog 排队永不 accept）。


## 许可证

MIT，见 [LICENSE](LICENSE)。
