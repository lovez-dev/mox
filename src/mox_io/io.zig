//! 后端契约：`Io`（后端句柄）与 `VTable`（扁平的函数指针表）。
//!
//! 纪律：本模块是**接口层**，只依赖 `types.zig` 的纯数据类型，不依赖任何
//! 实现模块（`completion.zig` / `loop.zig` / 各后端）。这样后端实现可以
//! 单向依赖接口，不会形成环。
//!
//! 真实形状（不要照旧草案写）：
//!
//! - 没有 `Backend` 包装类型，没有 `submit` / `flush` / `poll` 三段式。
//!   **提交与收割合并在 `waitBatch(userdata, timeout_ms, refs) !usize`**。
//! - 唤醒是 `notify(userdata)`。
//! - 能力走 `Io.capability(T, id)`（`CapTable` 描述符），不是位图。
//! - 取消是 `cancel(userdata, socket, scratch) void`（不返回状态）。
//!
//! 所有槽位的错误都是 `anyerror`：**同一个错误名在四个后端含义一致**，
//! POSIX errno 由 `sys.zig` 映射，WSA/Win32 错误由 Windows 后端映射。

const std = @import("std");

const types = @import("types.zig");

const Handle = types.Handle;
const SockOpt = types.SockOpt;
const ShutdownHow = types.ShutdownHow;
const Scratch = types.Scratch;
const FileKind = types.FileKind;
const FileMode = types.FileMode;
const Stat = types.Stat;
const DirEntry = types.DirEntry;
const Ready = types.Ready;
const Ref = types.Ref;

/// `Io`：后端句柄 + 虚表 + 可选能力。循环只通过它驱动后端。
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

const CapTable = types.CapTable;

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

    // ---- 文件句柄层（阶段 A）--------------------------------------------
    // 路径式 API 每次调用都要重新 open/close，无法复用句柄、无法随机读、
    // 也没法在「打开后到关闭前」持有稳定状态。下面四个原语补上这一层：
    // 打开一次拿 Handle，之后用 Handle 读写，最后显式关闭。
    // 全部在 `Work` 池线程执行（文件没有可移植的原生异步接口）。

    /// 按 `FileMode` 打开文件并返回句柄。`create` 为真时文件不存在则创建。
    openFile: ?*const fn (userdata: ?*anyopaque, path: []const u8, mode: FileMode) anyerror!Handle = null,
    /// 从 `offset` 读入 `buf`，返回实际读到的字节数（文件尾短读，不报错）。
    readFileHandle: ?*const fn (userdata: ?*anyopaque, file: Handle, offset: u64, buf: []u8) anyerror!usize = null,
    /// 从 `offset` 写入全部 `bytes`，返回写入字节数。
    writeFileHandle: ?*const fn (userdata: ?*anyopaque, file: Handle, offset: u64, bytes: []const u8) anyerror!usize = null,
    /// 关闭句柄。句柄无效或重复关闭不报错（幂等）。
    closeFile: ?*const fn (userdata: ?*anyopaque, file: Handle) void = null,

    // ---- 句柄级元数据与同步（阶段 B）--------------------------------------
    // 路径式 `statPath`/`truncateFile` 要先解析路径再 open，句柄在手时
    // 再走一遍路径既浪费又可能竞态（路径被换掉）。这三个原语直接吃句柄。

    /// 取句柄对应的元数据（类型/大小/mtime）。不需要重新解析路径。
    statFile: ?*const fn (userdata: ?*anyopaque, file: Handle) anyerror!Stat = null,
    /// 把句柄对应文件截断到 `size` 字节。句柄必须可写。
    setFileSize: ?*const fn (userdata: ?*anyopaque, file: Handle, size: u64) anyerror!void = null,
    /// 把缓冲内容刷到磁盘（`fsync` / `FlushFileBuffers`）。
    syncFile: ?*const fn (userdata: ?*anyopaque, file: Handle) anyerror!void = null,
    /// 把文件阻塞截断到 `size` 字节（`Work` 池线程）。
    truncateFile: *const fn (userdata: ?*anyopaque, path: []const u8, size: u64) anyerror!void,
    /// 删除文件（`Work` 池线程）。平台层同时提供 void 的清理版本与
    /// checked 版本；VTable 走 checked，errno 会翻译成具体 `error`。
    deleteFile: *const fn (userdata: ?*anyopaque, path: []const u8) anyerror!void,
    /// 创建目录（含缺失父目录，等价 `mkdir -p`）。`Work` 池线程。
    makeDir: *const fn (userdata: ?*anyopaque, path: []const u8, mode: u32) anyerror!void,
    /// 删除**空**目录。非空时报 `error.DirNotEmpty`，不递归。
    removeDir: *const fn (userdata: ?*anyopaque, path: []const u8) anyerror!void,
    /// 重命名 / 移动。跨设备报 `error.CrossDevice`，不退化成复制+删除。
    rename: *const fn (userdata: ?*anyopaque, old_path: []const u8, new_path: []const u8) anyerror!void,
    /// 创建符号链接。
    symLink: *const fn (userdata: ?*anyopaque, target: []const u8, link_path: []const u8) anyerror!void,

    // ---- 符号链接读取 + 目录流式句柄（阶段 C）------------------------------
    // `listDir` 是一次性把整目录塞进调用方缓冲：目录很大时要么截断要么
    // 调用方给巨大缓冲。这三个原语把目录变成可增量读的流，跟 `FileOpen`
    // 那套对称。

    /// 读符号链接指向的目标路径。返回目标路径写入 `buf` 的长度。
    /// 目标比 `buf` 长时报 `error.NameTooLong`（不静默截断——截断后的路径
    /// 是错的，比报错更危险）。
    readLink: ?*const fn (userdata: ?*anyopaque, link_path: []const u8, buf: []u8) anyerror!usize = null,
    /// 打开目录，返回目录句柄（用于 `readDirHandle`）。
    openDir: ?*const fn (userdata: ?*anyopaque, path: []const u8) anyerror!Handle = null,
    /// 从目录句柄读下一批条目，返回条目数。返回 0 表示读完。
    /// 返回数等于 `buf.len` 时**可能**还有剩余，调用方应继续读。
    readDirHandle: ?*const fn (userdata: ?*anyopaque, dir: Handle, buf: []DirEntry) anyerror!usize = null,
    /// 关闭目录句柄。幂等。
    closeDir: ?*const fn (userdata: ?*anyopaque, dir: Handle) void = null,

    // ---- 元数据写入、路径解析与硬链接（阶段 F）------------------------------
    // 与上面 `statFile`/`setFileSize`/`syncFile` 同类：全部走 `Work` 池线程，
    // 可空 = 后端可不实现（如 Windows 没有 POSIX 权限位）。

    /// 改文件权限位（`fchmod` / `chmod`）。`mode` 是 POSIX 权限位（如 `0o644`）。
    /// Windows 没有 POSIX 权限位，该槽位为 `null`。
    setFilePermissions: ?*const fn (userdata: ?*anyopaque, file: Handle, mode: u32) anyerror!void = null,
    /// 改文件属主（`fchown`）。`uid`/`gid` 是 POSIX 用户/组 ID。
    /// Windows 没有 uid/gid，该槽位为 `null`。
    setFileOwner: ?*const fn (userdata: ?*anyopaque, file: Handle, uid: u32, gid: u32) anyerror!void = null,
    /// 改文件时间戳（`futimens` / `SetFileTime`）。时间是 Unix 纪元纳秒。
    setFileTimestamps: ?*const fn (userdata: ?*anyopaque, file: Handle, atime_ns: i64, mtime_ns: i64) anyerror!void = null,
    /// 按路径改权限位（`fchmodat` / `chmod`）。句柄版本更安全（无竞态），
    /// 但调用方不一定持有句柄。
    setPermissions: ?*const fn (userdata: ?*anyopaque, path: []const u8, mode: u32) anyerror!void = null,
    /// 按路径改属主（`fchownat` / `chown`）。Windows 为 `null`。
    setOwner: ?*const fn (userdata: ?*anyopaque, path: []const u8, uid: u32, gid: u32) anyerror!void = null,
    /// 按路径改时间戳（`utimensat` / `SetFileTime`）。
    setTimestamps: ?*const fn (userdata: ?*anyopaque, path: []const u8, atime_ns: i64, mtime_ns: i64) anyerror!void = null,
    /// 检查路径可达性（`access`）。`mode` 是 POSIX 检查位：
    /// `0`=存在、`4`=可读、`2`=可写、`1`=可执行（可按位或）。
    /// 不可达时报具体错误（`FileNotFound` / `AccessDenied`）。
    access: ?*const fn (userdata: ?*anyopaque, path: []const u8, mode: u32) anyerror!void = null,
    /// 解析符号链接拿绝对路径（`realpath`）。结果写入 `buf`，返回长度。
    /// 路径不存在时报 `FileNotFound`。
    realPath: ?*const fn (userdata: ?*anyopaque, path: []const u8, buf: []u8) anyerror!usize = null,
    /// 创建硬链接（`linkat`）。两个路径指向同一 inode。
    hardLink: ?*const fn (userdata: ?*anyopaque, old_path: []const u8, new_path: []const u8) anyerror!void = null,
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

    /// 全方向关闭：`how` 指定读、写还是双向。`shutdownSend` 只能关写方向，
    /// 想同时拒绝后续读取（例如协议错误后强制断开）就需要这个。
    ///
    /// 与 `close` 的区别：`shutdown` 只改连接状态，不释放句柄，套接字仍可
    /// 用于后续的 `recv` 探测（读到 0 字节 = 对端已关）或最终 `close`。
    shutdown: ?*const fn (userdata: ?*anyopaque, socket: Handle, how: ShutdownHow) anyerror!void = null,

    /// 分散聚合发送：一次系统调用把多个缓冲发出去（`sendmsg` 的 iovec）。
    /// 用于 HTTP/2 分帧、WebSocket 拼头+载荷，避免多次 `send` 的边界问题。
    ///
    /// `hdr` 是节点自带的后端私有存储（至少 32 个 usize）——io_uring 与
    /// IOCP 都要在其中放 `msghdr`/`WSABUF` 数组，它们必须活到完成包被收割。
    /// 不提供（`null`）时节点层回落成「依次 `send`」。
    sendMsg: ?*const fn (
        userdata: ?*anyopaque,
        socket: Handle,
        bufs: []const []const u8,
        hdr: []usize,
        scratch: *Scratch,
    ) anyerror!void = null,

    /// 分散聚合接收：一次系统调用把数据摊到多个缓冲（`recvmsg` 的 iovec）。
    /// 相比先 `recv` 到一个大缓冲再手动切分，省掉一次内存拷贝。
    recvMsg: ?*const fn (
        userdata: ?*anyopaque,
        socket: Handle,
        bufs: []const []u8,
        hdr: []usize,
        scratch: *Scratch,
    ) anyerror!void = null,

    /// 取消一个已提交、尚未完成的操作。后端必须保证最终仍会投递一个完成包
    /// （可以是 aborted / ECANCELED），使 `Loop` 能安全回收该节点；
    /// 循环收到后会因 `cancelled` 标志直接丢弃，不回调。
    cancel: *const fn (userdata: ?*anyopaque, socket: Handle, scratch: *Scratch) void,

    /// 挂一个任意 fd 等就绪。回调**只通知方向**，不代收数据（见 `WatchFd`）。
    ///
    /// 就绪位经 `Ref.bytes` 回传（`Ready.bits()`），由 `Loop` 统一翻译进
    /// `WatchFd.ready` —— 后端不必知道节点布局，三个后端形状一致。
    ///
    /// 整槽为 `?` 是为了 Windows 能置 `null`。理由**不是**「IOCP 做不到就绪
    /// 通知」——实测它做得到（零字节重叠读在数据到达时才完成）。真实原因是
    /// **句柄类型**：`WatchFd` 的目标场景是管道、串口、`stdin`，而匿名管道和
    /// 控制台句柄挂不进 IOCP（`ERROR_INVALID_PARAMETER`），只有 socket 和
    /// 命名管道可以。所以 `WatchFd` 在 Windows 上如实返回 `Unsupported`，
    /// 而 socket 就绪等待走下面单独的 `netPoll`。
    watchFd: ?*const fn (userdata: ?*anyopaque, fd: Handle, want: Ready, scratch: *Scratch) anyerror!?void = null,

    /// 等 socket 可读/可写（`NetPoll`）。就绪位经 `Ref.bytes` 回传。
    ///
    /// 与 `watchFd` 分开是因为两个平台的最优实现不同：
    /// - Linux/BSD：与 `watchFd` 完全一样，直接复用。
    /// - Windows：`watchFd` 对管道/控制台无解，但 **socket 有解**——投一个
    ///   零字节 `WSARecv`（等可读）或 `WSASend`（等可写），它在真正就绪时
    ///   才完成。这走的是既有的 IOCP 完成包通道，不新增线程。
    ///
    /// 为 `null` 时调用方拿到 `error.Unsupported`。
    netPoll: ?*const fn (userdata: ?*anyopaque, socket: Handle, want: Ready, scratch: *Scratch) anyerror!?void = null,

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

    /// 关闭套接字。**吞掉错误**：关 fd 失败（`EBADF`）几乎总是「重复关闭」，
    /// 调用方按惯例不该因此 panic。需要区分失败请用 `closeChecked`。
    close: *const fn (userdata: ?*anyopaque, socket: Handle) void,

    /// 关闭套接字并回报失败。与 `close` 的区别只有「错误不被吞掉」：
    /// `EBADF` / `WSAENOTSOCK` 映射为 `error.NotOpen`，其余为 `error.CloseFailed`。
    ///
    /// 可选槽位：`null` 表示该后端不区分（等价于 `close` 成功返回）。
    /// 存在的理由与 `deleteFileChecked` 一样 —— 「静默失败」在生产环境里
    /// 排障成本极高；`delete_failures` 计数器就是为此存在的。
    closeChecked: ?*const fn (userdata: ?*anyopaque, socket: Handle) anyerror!void = null,

    /// 批量收割完成包：一次系统调用最多填 `refs.len` 个，返回实际数量。
    /// 超时且一个都没有时返回 0。调用方（Loop）负责逐个回填与回调。
    waitBatch: *const fn (userdata: ?*anyopaque, timeout_ms: u32, refs: []Ref) anyerror!usize,

    /// 唤醒阻塞在 `waitBatch` 里的线程。`Work` 池线程与跨线程 `submit`
    /// 完成后调用它，让 `run` 停止阻塞并投递完成。
    notify: *const fn (userdata: ?*anyopaque) void,
};

// ---- 运行时配置 -----------------------------------------------------------

/// 构造 `Loop` 时的可调参数。
///
/// 命名与形状对齐 zio 的 `Loop.Options` / `RuntimeOptions`：运行时实例级配置，
/// 同一个进程里可以开多个不同配置的 `Loop`，互不影响。
///
/// **为什么不是编译期全局 `mox_options`**：zio 那份是给「调度模型」这类
/// 一旦不同就不兼容的开关用的（它要保证同一二进制里所有依赖看到同一份）。
/// mox 的这几项都是纯资源尺寸，实例间不同完全安全，做成实例参数更有用。
pub const Options = struct {
    /// 后端事件队列容量（格数）。默认 256（实测最优）。
    ///
    /// io_uring 下它决定 SQ 环大小，CQ 环取它的 8 倍、溢出队列同 CQ。
    /// epoll / kqueue 用它决定待办池与完成队列的预分配容量；
    /// IOCP 的内核完成批量数组仍固定为 64，忽略此参数。
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
