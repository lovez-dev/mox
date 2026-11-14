//! `mox_io` 公共门面：导出类型、完成节点、同步操作与 Loop 构造入口。
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
//! 依赖方向：types/errors → io 契约 → 完成节点、Loop、后端。
//! 同步操作经 Io 调用，异步操作经 Loop 驱动；平台选择只在构造时发生。

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const io_mod = @import("io.zig");
pub const platform = @import("platform.zig").platform;
// ---- 基础类型（定义在 types.zig） ----------------------------------------
//
// 这里只做 re-export，不重复定义。拆分理由见 `types.zig` 的文件头：
// `mox_io.zig` 同时当类型仓库 + 接口 + 门面，会让所有模块反向依赖它。

pub const Handle = types.Handle;
pub const INVALID_HANDLE = types.INVALID_HANDLE;
pub const SockOpt = types.SockOpt;
pub const ShutdownHow = types.ShutdownHow;
pub const Scratch = types.Scratch;
pub const Ref = types.Ref;
pub const CapTable = types.CapTable;
pub const cap = types.cap;
pub const FileKind = types.FileKind;
pub const FileMode = types.FileMode;
pub const Stat = types.Stat;
pub const DirEntry = types.DirEntry;

/// 后端契约：`Io` + `VTable`。定义在 `io.zig`（接口层不依赖实现模块）。
pub const Io = io_mod.Io;
pub const VTable = io_mod.VTable;
pub const BlockingNet = io_mod.BlockingNet;
pub const Accepted = types.Accepted;
pub const Options = io_mod.Options;

// ---- 模块门面 -------------------------------------------------------------
//
// 调用方只 import `mox_io`；这里把三个文件的公开表面收拢到一处。
const completion_mod = @import("completion.zig");
const loop_mod = @import("loop.zig");

pub const Completion = completion_mod.Completion;
pub const Ready = types.Ready;
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
pub const Async = completion_mod.Async;
pub const Group = completion_mod.Group;
pub const NetSendMsg = completion_mod.NetSendMsg;
pub const NetRecvMsg = completion_mod.NetRecvMsg;
pub const NetShutdown = completion_mod.NetShutdown;
pub const NetPoll = completion_mod.NetPoll;
/// 分散聚合 I/O 的后端私有暂存区容量（以 `usize` 计）。
pub const MSG_HDR_WORDS = completion_mod.MSG_HDR_WORDS;
pub const Loop = loop_mod.Loop;

pub const ReadFile = @import("file.zig").ReadFile;
pub const WriteFile = @import("file.zig").WriteFile;
pub const TruncateFile = @import("file.zig").TruncateFile;
pub const DeleteFile = @import("file.zig").DeleteFile;
pub const OpenFile = @import("file.zig").OpenFile;
pub const ReadFileHandle = @import("file.zig").ReadFileHandle;
pub const WriteFileHandle = @import("file.zig").WriteFileHandle;
pub const CloseFile = @import("file.zig").CloseFile;
pub const StatFile = @import("file.zig").StatFile;
pub const SetFileSize = @import("file.zig").SetFileSize;
pub const SyncFile = @import("file.zig").SyncFile;
pub const SetFilePermissions = @import("file.zig").SetFilePermissions;
pub const SetFileOwner = @import("file.zig").SetFileOwner;
pub const SetFileTimestamps = @import("file.zig").SetFileTimestamps;
pub const SetPermissions = @import("file.zig").SetPermissions;
pub const SetOwner = @import("file.zig").SetOwner;
pub const SetTimestamps = @import("file.zig").SetTimestamps;
pub const Access = @import("file.zig").Access;
pub const RealPath = @import("file.zig").RealPath;
pub const HardLink = @import("file.zig").HardLink;
pub const ReadLink = @import("file.zig").ReadLink;
pub const OpenDir = @import("file.zig").OpenDir;
pub const ReadDirHandle = @import("file.zig").ReadDirHandle;
pub const CloseDir = @import("file.zig").CloseDir;

/// 编译期选定的本目标后端。新增后端 = 写一个导出 `create(allocator) !Io`
/// 的文件，再在这里加一个分支。
///
/// kqueue 后端目前只在 Darwin 与 FreeBSD 上验证过可编译；NetBSD / OpenBSD /
/// DragonFly 的 `Kevent.flags` 宽度与 `sendfile` 签名不同，且没有运行时验证，
/// 所以不宣称支持——明确报错好过悄悄编译失败或给出「能跑」的假象。
/// UDP 能力表：所有平台共用一份适配，把 `platform` 的阻塞数据报 helper
/// 包装成能力函数。后端若将来提供原生异步版本，替换这里的 `ptr` 即可。
pub const udp = @import("udp.zig");
pub const dns = @import("dns.zig");

/// 高层 TCP 门面（薄封装）：`Tcp` / `Listener` / `listenLoopback`。
/// 只包装已有的同步平台原语，**不改** `Loop` / `VTable` 的任何签名；
/// 异步路径仍走 `Loop` + `Net*` 节点。详见 `net.zig`。
pub const net = @import("net.zig");
pub const Tcp = net.Tcp;
pub const Listener = net.Listener;

/// 子进程能力：`spawn`（同步）+ `Wait`（异步等退出，走 `Work` 池）+ `killGroup`。
/// 手写平台层（POSIX fork/exec/waitpid、Windows CreateProcessW），不借 `std.Io`；详见 `process.zig`。
pub const process = @import("process.zig");
pub const Process = process.Process;
pub const ProcessWait = process.Wait;
/// 信号订阅：POSIX self-pipe + `Work` 线程阻塞读；Windows 返回 `error.Unsupported`。
/// `Loop.init` 已把 `SIGPIPE` 设为 `SIG_IGN`，不要再用本模块订阅它。详见 `signal.zig`。
pub const signal = @import("signal.zig");
pub const Signal = signal.Signal;

/// TTY / 终端支持：模式切换（raw/cooked/cbreak）、尺寸查询、保存/恢复状态。
/// 只暴露同步接口（终端操作微秒级完成，无需异步化）。详见 `tty.zig`。
pub const tty = @import("tty.zig");
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
    _ = @import("net.zig");
    // tty.zig 原先漏在这里：它的测试从未被 `zig build test` 跑过。
    _ = @import("tty.zig");
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
