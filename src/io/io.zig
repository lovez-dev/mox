//! `mox_io` 模块根：I/O 抽象契约 + 门面 + 后端选择器。
//!
//! 目录平铺：`completion` 是节点、`loop` 是引擎、`queue`/`timer`/`pool`
//! 是数据结构、`file` 是阻塞兜底、`tests` 聚合测试、`backends/` 是平台实现。
//!
//! 对外形状是 `Io{ userdata, vtable }`：新增后端只需填满一个 `VTable`，
//! 上层（HTTP、框架）只认 `Io`，不接触任何平台类型。
//!
//! I/O 模型是「完成 / 回调」，不是 `async`/`await`：没有 future、没有每操作
//! 任务、没有每连接栈。每个操作是一块由调用方持有、内嵌的 `Completion` 节点，
//! 交给 `Loop.add`，完成后由 `Loop.run` 回填结果并回调。每连接开销是固定节点，
//! 而非纤程栈——这是选它而非 `std.Io` 的原因。
//!
//! 分层：`root.zig`（契约 + 门面 + 选择器）→ `completion.zig`（节点类型族）
//! → `loop.zig`（引擎）→ `backends/`（各平台实现）。后端只认本文件，
//! 引擎只通过 `root.vtable.*` 驱动后端，运行时零平台类型。

const std = @import("std");
const builtin = @import("builtin");

/// 套接字 / 句柄。mox 支持的所有平台上套接字都是指针宽度，故用一个整数表示；
/// 后端按需自行转换。
pub const Handle = usize;
pub const INVALID_HANDLE: Handle = std.math.maxInt(Handle);

/// 跨平台语义化的套接字选项。各后端把它映射到本平台的 `setsockopt`；
/// 只收录三家后端都能一致表达的那几个 —— 语义不齐的选项宁可先不做，
/// 也好过在某个平台上静默变成另一件事。
pub const SockOpt = enum {
    /// 关掉 Nagle 合并，小响应立即上线。延迟敏感、吞吐不敏感的 HTTP 应开。
    tcp_nodelay,
    /// 关闭条件：空闲多久（秒）后开始发保活探测。`0` 表示关掉保活。
    keepalive_idle,
    /// 内核接收缓冲字节数（`0` 表示交由系统自适应）。
    recv_buf,
    /// 内核发送缓冲字节数（`0` 表示交由系统自适应）。
    send_buf,
};

/// 由 `Completion` 持有、按 8 字节对齐的不透明内核暂存区。尺寸取各后端单操作
/// 所需最大值（Windows 的 `OVERLAPPED` + `WSABUF` 约 48 字节；io_uring 只存
/// 一个 `user_data` 字）。由后端重新解释，接口层绝不碰它。
pub const Scratch = extern struct {
    bytes: [64]u8 align(8),
};

/// `waitBatch` 在操作完成时返回的结果。`scratch` 就是提交时传入的那块内存，调用方
/// 用 `@fieldParentPtr` 直接映射回对应的 `Completion`。
pub const Ref = struct {
    scratch: *Scratch,
    bytes: usize,
    failed: bool,
    /// 由内核分配的新 fd，用于调用方无法预先建 socket 的后端（io_uring / kqueue）。
    /// 其余情况为 `INVALID_HANDLE`；循环在成功时把它写入 `NetAccept.accept_socket`。
    /// 放在 `Ref` 上，后端就只需认识 `Scratch`，无需知道 `Completion`。
    new_handle: Handle = INVALID_HANDLE,
};

/// 能力 ID：编译期对新能力的名字做 FNV-1a，不需要维护全局枚举。
/// 后端与调用方各自 `comptime` 计算同一个 ID，永远不会冲突或漏配。
pub fn cap(comptime name: []const u8) u64 {
    return std.hash.Fnv1a_64.hash(name);
}

/// 可选能力表。核心 `VTable` 只放每个后端都必须实现的 TCP / 定时器热路径；
/// UDP、DNS、进程、信号等按需扩展项通过它提供。
///
/// 查询是「线性扫一张只在初始化时构造的只读表」，不在每次 I/O 上发生；
/// 调用方应把结果缓存在自己的状态里。新增能力 = 加一个 `cap("...")` 常量
/// + 后端往表里加一行，`VTable` 布局完全不变，老后端自动返回 `null`。
pub const CapTable = struct {
    pub const Entry = struct {
        id: u64,
        ptr: *const anyopaque,
    };
    entries: []const Entry,

    pub fn get(self: *const CapTable, comptime T: type, id: u64) ?T {
        for (self.entries) |e| {
            if (e.id == id) return @ptrCast(@alignCast(e.ptr));
        }
        return null;
    }
};

pub const Io = struct {
    userdata: ?*anyopaque,
    vtable: *const VTable,
    /// 可选能力；没有扩展能力的后端保持 `null`。
    caps: ?*const CapTable = null,

    /// 取一个可选能力。类型由调用方与后端约定，编译期固定，运行时零开销。
    pub fn capability(self: Io, comptime T: type, id: u64) ?T {
        const table = self.caps orelse return null;
        return table.get(T, id);
    }
};
/// 文件类型。与各平台 `S.IFMT` / `FILE_ATTRIBUTE_DIRECTORY` 的常用子集对齐，
/// 够静态服务判断「是不是普通文件」用。
pub const FileKind = enum { file, directory, sym_link, other };

/// 路径元数据。`mtime_ms` 是 Unix 毫秒，便于直接做 `If-Modified-Since`。
/// 拿不到时置 0（调用方据此认为「未知」，而不是假装 1970）。
pub const Stat = struct {
    kind: FileKind,
    size: u64,
    mtime_ms: i64,
};

/// 目录条目。名字定长，避免调用方管内存；超长名字被跳过
/// （`NAME_MAX` 通常 255，这里给 256）。
pub const DirEntry = struct {
    name: [256]u8 = undefined,
    len: usize = 0,
    is_dir: bool = false,

    pub fn slice(self: *const DirEntry) []const u8 {
        return self.name[0..self.len];
    }
};

pub const VTable = struct {
    /// 释放后端资源（`userdata` 指向的状态），只调一次。
    deinit: *const fn (userdata: ?*anyopaque) void,

    /// 单调毫秒时钟，供定时器使用。
    now: *const fn (userdata: ?*anyopaque) u64,

    /// 创建一个与 `address` 同地址族、可用于重叠 I/O 的 TCP 套接字。
    /// 监听用它建 listener，AcceptEx 用它建预备 socket。
    createSocket: *const fn (userdata: ?*anyopaque, address: std.Io.net.IpAddress) anyerror!Handle,

    /// 设置 `SO_REUSEADDR`，监听前调用。
    setReuseAddress: *const fn (userdata: ?*anyopaque, socket: Handle, on: bool) anyerror!void,

    /// 把套接字绑定到 `address`。
    bind: *const fn (userdata: ?*anyopaque, socket: Handle, address: std.Io.net.IpAddress) anyerror!void,

    /// 开始监听，`backlog` 为等待队列长度。
    listen: *const fn (userdata: ?*anyopaque, socket: Handle, backlog: c_int) anyerror!void,

    /// 返回文件字节数；静态文件响应据此分配缓冲区（在 `Work` 线程上调用）。
    fileSize: *const fn (userdata: ?*anyopaque, path: []const u8) anyerror!u64,
    /// 在 `Work` 池线程里阻塞读文件。文件没有可移植的原生异步接口，
    /// 这是所有后端共用的兜底；通过 `Io` 值调用，不依赖 `*Loop`。
    readFileInto: *const fn (userdata: ?*anyopaque, path: []const u8, buf: []u8) anyerror!usize,
    /// 在 `Work` 池线程里阻塞整文件写入（覆盖既有内容）。与 `readFileInto`
    /// 同样是所有后端共用的兜底：没有可移植的原生异步写接口。
    writeFileAll: *const fn (userdata: ?*anyopaque, path: []const u8, bytes: []const u8) anyerror!void,
    /// 从 `offset` 处阻塞读入 `buf`（`Work` 池线程）。支持随机访问，
    /// 是分段读大文件的基础；文件尾会短读而不是报错。
    readFileAt: *const fn (userdata: ?*anyopaque, path: []const u8, offset: u64, buf: []u8) anyerror!usize,
    /// 在文件末尾阻塞追加 `bytes`（`Work` 池线程）；文件不存在时创建。
    appendFile: *const fn (userdata: ?*anyopaque, path: []const u8, bytes: []const u8) anyerror!void,
    /// 把文件阻塞截断到 `size` 字节（`Work` 池线程）。
    truncateFile: *const fn (userdata: ?*anyopaque, path: []const u8, size: u64) anyerror!void,
    /// 删除文件（`Work` 池线程）。平台层实现返回 `void`，**所有**失败
    /// （文件不存在、权限不足等）都被吞掉，因此这个槽位不会产生错误。
    deleteFile: *const fn (userdata: ?*anyopaque, path: []const u8) anyerror!void,
    /// 创建目录（含缺失父目录，等价 `mkdir -p`）。`Work` 池线程。
    makeDir: *const fn (userdata: ?*anyopaque, path: []const u8, mode: u32) anyerror!void,
    /// 删除**空**目录。非空时报 `error.DirNotEmpty`，不递归。
    removeDir: *const fn (userdata: ?*anyopaque, path: []const u8) anyerror!void,
    /// 重命名 / 移动。跨设备报 `error.CrossDevice`，不退化成复制+删除。
    rename: *const fn (userdata: ?*anyopaque, old_path: []const u8, new_path: []const u8) anyerror!void,
    /// 创建符号链接。
    symLink: *const fn (userdata: ?*anyopaque, target: []const u8, link_path: []const u8) anyerror!void,
    /// 取路径元数据（跟随符号链接）。
    statPath: *const fn (userdata: ?*anyopaque, path: []const u8) anyerror!Stat,
    /// 列目录项。`buf` 由调用方提供，返回条目数（超出时截断）。
    listDir: *const fn (userdata: ?*anyopaque, path: []const u8, buf: []DirEntry) anyerror!usize,
    /// 把套接字的完成包路由到本后端（Windows 上同时为监听套接字启用 `AcceptEx`）。
    associate: *const fn (userdata: ?*anyopaque, socket: Handle, key: usize) anyerror!void,
    /// 发起一次重叠接收。返回 `null` 表示尚未完成，稍后由 `wait` 投递。
    recv: *const fn (userdata: ?*anyopaque, socket: Handle, buf: []u8, scratch: *Scratch) anyerror!?usize,

    /// 发起一次重叠发送。返回 `null` 表示尚未完成。
    send: *const fn (userdata: ?*anyopaque, socket: Handle, buf: []const u8, scratch: *Scratch) anyerror!?usize,

    /// 发起一次重叠 UDP 数据报接收：`from` 由内核回填发送方 sockaddr。
    /// `hdr` 是节点自带的后端私有存储（至少 32 个 usize）——io_uring 要在其中
    /// 放置 msghdr 与 iovec，它们必须活到完成包被收割，所以不能放栈上，也放不进
    /// 64 字节的 `Scratch`。不提供（`null`）时 `Udp` 回落到 `Work` 池阻塞接收。
    udpRecv: ?*const fn (
        userdata: ?*anyopaque,
        socket: Handle,
        buf: []u8,
        from: []u8,
        hdr: []usize,
        scratch: *Scratch,
    ) anyerror!void = null,

    /// 发起一次重叠 UDP 数据报发送。地址由各后端自己编码成 sockaddr 并存在
    /// `hdr` 里（Linux 与 Windows 的 sockaddr 布局不同，能力层保持平台中立）。
    udpSend: ?*const fn (
        userdata: ?*anyopaque,
        socket: Handle,
        buf: []const u8,
        to: std.Io.net.IpAddress,
        hdr: []usize,
        scratch: *Scratch,
    ) anyerror!void = null,

    /// 发起一次重叠接受，结果写入 `accept_socket`。返回 `null` 表示尚未完成。
    accept: *const fn (userdata: ?*anyopaque, listen: Handle, accept_socket: Handle, addr_buf: []u8, scratch: *Scratch) anyerror!?usize,

    /// 完成对已接受套接字的收尾（Windows 的 `SO_UPDATE_ACCEPT_CONTEXT`）；
    /// 不需要的后端置为空操作。
    updateAccept: *const fn (userdata: ?*anyopaque, listen: Handle, accept_socket: Handle) void,

    /// 发起到 `address` 的重叠连接；完成同样经 `wait` 投递。
    connect: *const fn (userdata: ?*anyopaque, socket: Handle, address: std.Io.net.IpAddress, scratch: *Scratch) anyerror!void,

    /// 完成对已连接套接字的收尾（Windows 的 `SO_UPDATE_CONNECT_CONTEXT`）。
    updateConnect: *const fn (userdata: ?*anyopaque, socket: Handle) void,

    /// 设置一个套接字选项。`SockOpt` 给语义名，各后端自行映射到
    /// `setsockopt` 的 level/optname；不提供（`null`）时调用方拿到
    /// `error.Unsupported`，据此降级而不是崩溃。
    setSockOpt: ?*const fn (userdata: ?*anyopaque, socket: Handle, opt: SockOpt, value: u32) anyerror!void = null,

    /// 半关闭：只关发送方向（`SHUT_WR`），对端仍能把已发出的数据收完。
    /// 这是优雅收尾的常规做法，与 `close` 直接终止语义不同。
    shutdownSend: ?*const fn (userdata: ?*anyopaque, socket: Handle) anyerror!void = null,

    /// 取消一个已提交、尚未完成的操作。后端必须保证最终仍会投递一个完成包
    /// （可以是 aborted / ECANCELED），使 `Loop` 能安全回收该节点；
    /// 循环收到后会因 `cancelled` 标志直接丢弃，不回调。
    cancel: *const fn (userdata: ?*anyopaque, socket: Handle, scratch: *Scratch) void,

    /// 挂一个任意 fd 等就绪。回调**只通知方向**，不代收数据（见 `WatchFd`）。
    ///
    /// 就绪位经 `Ref.bytes` 回传（`Ready.bits()`），由 `Loop` 统一翻译进
    /// `WatchFd.ready` —— 后端不必知道节点布局，三个后端形状一致。
    ///
    /// 整槽为 `?` 是为了 Windows 能置 `null`：IOCP 是完成模型，没有「等就绪」
    /// 这回事，硬实现要另起 `WSAPoll` 线程，等于塞第二条事件循环。为 `null`
    /// 时调用方拿到 `error.Unsupported`。
    watchFd: ?*const fn (userdata: ?*anyopaque, fd: Handle, want: Ready, scratch: *Scratch) anyerror!?void = null,

    // ---- Unix domain socket（可选：Windows 上整组为 `null`） -------------
    //
    // UDS 的地址是文件系统路径，与 `IpAddress` 完全不同的类型，所以不复用
    // `createSocket` / `bind` / `connect` 三个槽位，而是单开一组。可选是为了
    // 让不支持的后端（Windows）整组置 `null`，调用方拿 `error.Unsupported`
    // 降级，而不是被迫实现一个假动作。
    //
    // 收发复用 `recv` / `send` / `accept`：连接建立后它们与 TCP 同形。

    /// 建一个 `AF_UNIX` / `SOCK_STREAM` 套接字。
    createUnix: ?*const fn (userdata: ?*anyopaque) anyerror!Handle = null,
    /// 把 UDS 绑到文件系统路径。路径已存在时后端应报 `error.PathAlreadyExists`
    /// （调用方通常先 `deleteFile` 清掉残留的 socket 文件）。
    bindUnix: ?*const fn (userdata: ?*anyopaque, socket: Handle, path: []const u8) anyerror!void = null,
    /// 异步连到 UDS。返回 `null` 表示尚未完成，完成经 `wait` 投递
    /// （与 TCP 的 `connect` 同语义）。
    connectUnix: ?*const fn (userdata: ?*anyopaque, socket: Handle, path: []const u8, scratch: *Scratch) anyerror!?void = null,

    // ---- 原生异步文件 I/O（可选：只有 io_uring 提供） --------------------
    //
    // 其它后端为 `null`，调用方回落到 `ReadFile` / `WriteFile` 的 `Work` 版本。
    // 这是「有则更好、无则照常」的能力，不是必需的。

    /// 发起异步读文件：`path` 必须 NUL 结尾且活到完成。
    readFileAsync: ?*const fn (userdata: ?*anyopaque, path: [*:0]const u8, offset: u64, buf: []u8, scratch: *Scratch) anyerror!?void = null,
    /// 发起异步写文件（覆盖）。
    writeFileAsync: ?*const fn (userdata: ?*anyopaque, path: [*:0]const u8, offset: u64, bytes: []const u8, scratch: *Scratch) anyerror!?void = null,

    /// 把文件内容零拷贝送进套接字（Linux `sendfile` / BSD `sendfile`）。
    /// 返回实际发送字节数。`offset` 是文件内起始偏移，由后端推进。
    /// 不支持时（Windows）为 `null`，调用方回落到「读进缓冲再 `send`」。
    sendFileTo: ?*const fn (userdata: ?*anyopaque, socket: Handle, path: []const u8, offset: u64, count: usize) anyerror!usize = null,

    /// 关闭套接字。
    close: *const fn (userdata: ?*anyopaque, socket: Handle) void,

    /// 批量收割完成包：一次系统调用最多填 `refs.len` 个，返回实际数量。
    /// 超时且一个都没有时返回 0。调用方（Loop）负责逐个回填与回调。
    waitBatch: *const fn (userdata: ?*anyopaque, timeout_ms: u32, refs: []Ref) anyerror!usize,

    /// 唤醒阻塞在 `waitBatch` 里的线程。`Work` 池线程与跨线程 `submit`
    /// 完成后调用它，让 `run` 停止阻塞并投递完成。
    notify: *const fn (userdata: ?*anyopaque) void,
};

// ---- 模块门面 -------------------------------------------------------------
//
// 调用方只 import `mox_io`；这里把三个文件的公开表面收拢到一处。
const completion_mod = @import("completion.zig");
const loop_mod = @import("loop.zig");

pub const Completion = completion_mod.Completion;
pub const Ready = completion_mod.Ready;
pub const ReadFileAsync = completion_mod.ReadFileAsync;
pub const WriteFileAsync = completion_mod.WriteFileAsync;
pub const WatchFd = completion_mod.WatchFd;
pub const Callback = completion_mod.Callback;
pub const Op = completion_mod.Op;
pub const Timer = completion_mod.Timer;
pub const NetRecv = completion_mod.NetRecv;
pub const NetSend = completion_mod.NetSend;
pub const NetClose = completion_mod.NetClose;
pub const NetAccept = completion_mod.NetAccept;
pub const NetConnect = completion_mod.NetConnect;
pub const Work = completion_mod.Work;
pub const Loop = loop_mod.Loop;

pub const ReadFile = @import("file.zig").ReadFile;
pub const WriteFile = @import("file.zig").WriteFile;
pub const TruncateFile = @import("file.zig").TruncateFile;
pub const DeleteFile = @import("file.zig").DeleteFile;

/// 编译期选定的本目标后端。新增后端 = 写一个导出 `create(allocator) !Io`
/// 的文件，再在这里加一个分支。
pub const platform = switch (builtin.os.tag) {
    .windows => @import("backends/windows.zig"),
    .linux => @import("backends/linux.zig"),
    .macos, .freebsd, .netbsd, .openbsd, .dragonfly => @import("backends/kqueue.zig"),
    else => @compileError("mox_io: no backend for this target yet"),
};

/// UDP 能力表：所有平台共用一份适配，把 `platform` 的阻塞数据报 helper
/// 包装成能力函数。后端若将来提供原生异步版本，替换这里的 `ptr` 即可。
pub const udp = @import("udp.zig");
pub const dns = @import("dns.zig");

/// 子进程能力：`spawn`（同步）+ `Wait`（异步等退出，走 `Work` 池）+ `killGroup`。
/// 手写平台层（POSIX fork/exec/waitpid、Windows CreateProcessW），不借 `std.Io`；详见 `process.zig`。
pub const process = @import("process.zig");
pub const Process = process.Process;
pub const ProcessWait = process.Wait;
/// 信号订阅：POSIX self-pipe + `Work` 线程阻塞读；Windows 返回 `error.Unsupported`。
/// `Loop.init` 已把 `SIGPIPE` 设为 `SIG_IGN`，不要再用本模块订阅它。详见 `signal.zig`。
pub const signal = @import("signal.zig");
pub const Signal = signal.Signal;
pub const Signals = signal.Signals;

const udp_storage = udp.VTable{
    .create = struct {
        fn f(userdata: ?*anyopaque, address: std.Io.net.IpAddress) anyerror!Handle {
            _ = userdata;
            return platform.createUdpSocket(address);
        }
    }.f,
    .bind = struct {
        fn f(userdata: ?*anyopaque, socket: Handle, address: std.Io.net.IpAddress) anyerror!void {
            _ = userdata;
            return platform.bindSocket(socket, address);
        }
    }.f,
    .recvFrom = struct {
        fn f(userdata: ?*anyopaque, socket: Handle, buf: []u8, from: []u8) anyerror!usize {
            _ = userdata;
            return platform.recvFromBlocking(socket, buf, from);
        }
    }.f,
    .sendTo = struct {
        fn f(userdata: ?*anyopaque, socket: Handle, buf: []const u8, address: std.Io.net.IpAddress) anyerror!usize {
            _ = userdata;
            return platform.sendToBlocking(socket, buf, address);
        }
    }.f,
    .close = struct {
        fn f(userdata: ?*anyopaque, socket: Handle) void {
            _ = userdata;
            platform.closeSocket(socket);
        }
    }.f,
};

const udp_entries = [_]CapTable.Entry{
    .{ .id = udp.id, .ptr = &udp_storage },
    .{ .id = dns.id, .ptr = &dns.descriptor },
};
const udp_cap_table = CapTable{ .entries = &udp_entries };

/// 给后端返回的 `Io` 补上模块级可选能力。后端自己不需要认识能力表。
fn withCaps(io_value: Io) Io {
    var out = io_value;
    if (out.caps == null) out.caps = &udp_cap_table;
    return out;
}

/// 构造 `Loop` 时的可调参数。
///
/// 命名与形状对齐 zio 的 `Loop.Options` / `RuntimeOptions`：运行时实例级配置，
/// 同一个进程里可以开多个不同配置的 `Loop`，互不影响。
///
/// **为什么不是编译期全局 `mox_options`**：zio 那份是给「调度模型」这类
/// 一旦不同就不兼容的开关用的（它要保证同一二进制里所有依赖看到同一份）。
/// mox 的这几项都是纯资源尺寸，实例间不同完全安全，做成实例参数更有用。
pub const Options = struct {
    /// 后端事件队列容量（格数）。
    ///
    /// io_uring 下它同时决定 SQ 环大小，CQ 环取它的 8 倍；epoll / kqueue /
    /// IOCP 下决定一次 `waitBatch` 能取回的就绪事件数。默认 256（实测最优）。
    ///
    /// 必须是 2 的幂且不为 0——`io_uring_setup` 和环掩码都依赖这一点。
    queue_size: u16 = 256,

    /// 在飞窗口上限：同时下发给后端、完成包还没回来的操作数。
    ///
    /// **不要手填。** `null` 表示由后端按 `queue_size` 自动推导（当前取
    /// `queue_size * 4`，即 CQ 环容量的一半）。传大了会在大批量提交时
    /// 灌爆 CQ 环、内核丢弃完成包、回调永不触发——这是实测踩过的坑。
    /// 传小了只会降低吞吐，不会错。
    inflight_max: ?usize = null,

    /// `Work` 线程池上限。0 表示用平台默认值（4）。
    max_workers: usize = 0,

    /// Linux 后端覆盖。`null` = 自动（优先 io_uring，setup 失败回落 epoll）。
    /// 非 Linux 平台上这个值被忽略。
    backend: ?Backend = null,

    pub const Backend = enum { uring, epoll };

    /// 把用户填的值解析成实际生效的配置。`queue_size` 非法时报错而不是
    /// 静默截断——静默改尺寸会让人以为自己测的是另一种配置。
    pub fn validate(self: Options) !Options {
        const qs = self.queue_size;
        if (qs == 0 or (qs & (qs - 1)) != 0) return error.InvalidQueueSize;
        return self;
    }
};

/// 用平台默认后端、默认配置构造一个 `Loop`。
///
/// 保留单参数入口是为了向后兼容：现有调用点（`server.zig`、bench、示例）
/// 全都不用改。要调参用 `openWith`。
pub fn open(alloc: std.mem.Allocator) !Loop {
    return openWith(alloc, .{});
}

/// 用自定义配置构造一个 `Loop`。
///
/// ```zig
/// var loop = try mox_io.openWith(gpa, .{
///     .queue_size = 512,
///     .max_workers = 8,
///     .backend = .epoll,
/// });
/// ```
pub fn openWith(alloc: std.mem.Allocator, opts: Options) !Loop {
    const resolved = try opts.validate();
    const io_value = withCaps(try platform.createWith(alloc, resolved));
    return Loop.initWithOptions(io_value, alloc, resolved);
}

test {
    // `zig test` 只跑从根文件可达的测试；这里把各层测试与后端测试聚合进来。
    _ = @import("completion.zig");
    _ = @import("loop.zig");
    _ = @import("queue.zig");
    _ = @import("timer.zig");
    _ = @import("pool.zig");
    _ = @import("file.zig");
    _ = @import("tests.zig");
    _ = @import("udp.zig");
    _ = @import("dns.zig");
    if (builtin.os.tag == .windows) {
        _ = @import("backends/windows.zig");
    } else if (builtin.os.tag == .linux) {
        _ = @import("backends/uring.zig");
        _ = @import("backends/linux.zig");
        _ = @import("backends/epoll.zig");
    } else if (builtin.os.tag == .macos or builtin.os.tag == .freebsd) {
        _ = @import("backends/kqueue.zig");
    }
}
