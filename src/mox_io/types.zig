//! 基础类型：**不带行为的纯数据类型**。
//!
//! 纪律：本模块只放「跨层共享的、不依赖任何其他 mox_io 模块的类型」。
//! 有行为的类型（节点、引擎、后端）留在各自模块里。
//!
//! 为什么要单独一个文件（而不是继续放在 `mox_io.zig` 里）：
//!
//! `mox_io.zig` 同时扮演三个角色 —— ①类型仓库 ②`Io`/`VTable` 接口
//! 定义 ③门面 re-export。结果是**每个模块都要 import `mox_io.zig`**，
//! 而 `mox_io.zig` 又 import 它们，形成大面积反向依赖。
//!
//! 拆开之后依赖方向是单向的：
//!
//! ```text
//! types.zig  ←  completion.zig  ←  loop.zig
//!     ↑              ↑                 ↑
//!     └──────── backends/ ──────────────┘
//! ```
//!
//! `mox_io.zig` 退化成「接口 + 门面」，它可以 import 所有人（因为它不
//! 被别人真正依赖实现细节），而底层模块只依赖 `types.zig`。

const std = @import("std");

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

/// `shutdown` 的方向。与 POSIX `SHUT_*` 一一对应。
pub const ShutdownHow = enum {
    /// 关读方向：本端不再 `recv`，对端发来的数据被内核丢弃。
    read,
    /// 关写方向：本端不再 `send`，内核发完已排队的再发 FIN。
    write,
    /// 双向都关。
    both,
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

// ---- 文件系统类型 ---------------------------------------------------------

/// 文件类型。与各平台 `S.IFMT` / `FILE_ATTRIBUTE_DIRECTORY` 的常用子集对齐，
/// 够静态服务判断「是不是普通文件」用。
pub const FileKind = enum { file, directory, sym_link, other };

/// 打开文件的方式。`read_write` 同时允许读写（随机访问更新场景）。
pub const FileMode = enum {
    /// 只读。文件必须已存在。
    read_only,
    /// 只写，打开时清空内容（不存在则创建）。
    write_only,
    /// 读写，不清空；文件不存在则创建。
    read_write,
    /// 只写，在末尾追加（不存在则创建）。
    append,
};

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

test "cap 对同一名字稳定、对不同名字区分" {
    // 编译期常量：后端与调用方各自算出同一个 ID。
    try std.testing.expectEqual(cap("mox.io.udp.v1"), cap("mox.io.udp.v1"));
    try std.testing.expect(cap("mox.io.udp.v1") != cap("mox.io.dns.v1"));
}

// ---- 就绪事件位 -----------------------------------------------------------

pub const Ready = packed struct(u8) {
    read: bool = false,
    write: bool = false,
    /// 对端已关闭 / 出错。多数平台会与 read 同时置位，调用方读一次拿到 EOF。
    /// 不叫 `error`：那是 Zig 关键字，字段名不能用它。
    failed: bool = false,
    hangup: bool = false,
    _pad: u4 = 0,

    pub fn bits(self: Ready) u8 {
        return @bitCast(self);
    }

    pub fn fromBits(v: u8) Ready {
        return @bitCast(v);
    }

    /// 任意方向就绪（`error` / `hangup` 也算，否则调用方会永远等下去）。
    pub fn any(self: Ready) bool {
        return self.read or self.write or self.failed or self.hangup;
    }
};

/// 阻塞 accept 的结果；新套接字由调用方关闭。
pub const Accepted = struct {
    socket: Handle,
    address: std.Io.net.IpAddress,
};
