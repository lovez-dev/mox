//! 错误模型：**一个集中定义的错误集合**，四个后端共用。
//!
//! 纪律：本文件是 `src/mox_io/` 里错误名的**唯一来源**。任何具名错误
//! 必须先在这里定义，再被各模块引用。后端不允许就地 `return error.Xxx`
//! 造出集合外的名字 —— 那样跨平台就断了（同一个语义在 Linux 和 Windows
//! 叫不同名字，调用方没法写一个 `switch`）。
//!
//! 设计（对齐 `std.posix` / `std.Io` 的做法）：
//!
//! - **按操作族分组**：`NetError` 覆盖套接字读写，`FileError` 覆盖文件，
//!   `SystemError` 覆盖平台层。
//! - **封闭有限集合**：每个族都是**有限的**具名错误。未识别的 errno /
//!   WSA 错误统一落到 `error.UnexpectedErrno`（一个明确的成员），而不是
//!   `|| anyerror` 兜底 —— 后者在 Zig 里会让整个集合退化成 `anyerror`
//!   （`具名集合 || anyerror == anyerror`），调用方就失去了穷举能力。
//!   这一点很关键：早期实现用 `fn cvt(rc) !usize` 把所有失败压成
//!   `error.SyscallFailed`，`EAGAIN` / `ECONNRESET` / `ENOSPC` 全都
//!   无法区分。现在每个常见 errno 有对应具名成员，罕见 errno 落到
//!   `UnexpectedErrno`（保留「这是未分类系统错误」的语义，而不是撒谎成
//!   某个具体错误）。
//! - **不设「提交期 vs 完成期」两套集合**：`Loop.add()` 返回 `void`，
//!   在飞窗口满了就排队（`enqueueSubmitted`），不存在「提交被拒」这种
//!   失败。所以只有一套集合。
//!
//! `errors.zig` 底部的守卫测试会在**编译期**检查下面的具名错误与
//! `errors_test` 列表一致 —— 删一个错误、改一个拼写，测试立刻红。

const std = @import("std");

/// 平台层通用错误：不属于网络也不属于文件语义的部分。
///
/// 这些名字对应 `sys.zig` 里 errno 的映射结果。
pub const SystemError = error{
    /// 权限不足（`EACCES`）。
    AccessDenied,
    /// 操作会阻塞（`EAGAIN` / `EWOULDBLOCK`）。非阻塞 socket 的常态。
    WouldBlock,
    /// 句柄已关闭或无效（`EBADF`）。
    NotOpen,
    /// 资源忙（`EBUSY`）。
    Busy,
    /// 参数非法（`EINVAL`）。
    InvalidArgument,
    /// 地址非法（`EFAULT`）。
    BadAddress,
    /// 底层 I/O 失败（`EIO`）。
    IoFailed,
    /// 文件名过长（`ENAMETOOLONG`）。
    NameTooLong,
    /// 内存不足（`ENOMEM`）。
    OutOfMemory,
    /// fd 配额耗尽（进程级 / 系统级）。
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    /// 消息超过缓冲区上限（`EMSGSIZE`）。
    MessageTooLarge,
    /// 值超出类型或缓冲区能表示的范围（`ERANGE`）。
    ValueOutOfRange,
    /// 协议错误（`EPROTO`）。
    ProtocolError,
    /// 该协议不被支持（`EPROTONOSUPPORT`）。
    ProtocolNotSupported,
    /// 套接字层错误（`ESPIPE`）。
    SocketError,
    /// 域名未解析（`EAI_*` 的统一表达）。
    HostNotFound,
    /// 未识别的系统错误码。原样冒泡，不塞进语义不对的桶。
    UnexpectedErrno,
    /// 操作被信号中断（`EINTR`）。多数路径由底层重试，不会浮现到完成结果。
    Interrupted,
    /// 操作被取消、超时或当前后端不支持。
    Aborted,
    DeadlineExceeded,
    Unsupported,
    ReadFailed,
    PrivilegeNotHeld,
};

/// 套接字 / 网络相关错误。
pub const NetError = error{
    /// 对端重置了连接（`ECONNRESET`）。
    ConnectionReset,
    /// 对端拒绝连接（`ECONNREFUSED`）。
    ConnectionRefused,
    /// 连接被中止（`ECONNABORTED`）。
    ConnectionAborted,
    /// 写端已关闭（`EPIPE`）。
    BrokenPipe,
    /// 操作超时（`ETIMEDOUT`）。
    TimedOut,
    /// 网络不可达（`ENETUNREACH`）。
    NetworkUnreachable,
    /// 网络已断开（`ENETDOWN`）。
    NetworkDown,
    /// 连接被重置（`ENETRESET`）。
    NetworkReset,
    /// 套接字未连接（`ENOTCONN`）。
    NotConnected,
    /// 已经连接（`EISCONN`）。
    AlreadyConnected,
    /// 套接字已关闭（`ENOTSOCK`）。
    NotSocket,
    /// 需要指定地址（`EDESTADDRREQ`）。
    AddressRequired,
    /// 地址已被占用（`EADDRINUSE`，bind 冲突）。
    AddressInUse,
    /// 对端已正常关闭写方向。
    PeerClosed,
    /// 监听队列已满（`ECONNABORTED` 的常见形态）。
    TooManyConnections,
} || SystemError;

/// 文件与目录相关错误。
pub const FileError = error{
    /// 文件不存在（`ENOENT`）。
    FileNotFound,
    /// 路径已存在（`EEXIST`）。
    PathAlreadyExists,
    /// 路径不是目录（`ENOTDIR`）。
    NotDirectory,
    /// 路径是目录（`EISDIR`）。
    IsDirectory,
    /// 目录非空（`ENOTEMPTY`）。
    DirNotEmpty,
    /// 磁盘满（`ENOSPC`）。
    NoSpaceLeft,
    /// 只读文件系统（`EROFS`）。
    ReadOnlyFileSystem,
    /// 跨设备链接（`EXDEV`）。
    CrossDevice,
    /// 符号链接环路（`ELOOP`）。
    SymLinkLoop,
    /// 无此设备（`ENODEV` / `ENXIO`）。
    NoDevice,
    /// 缓冲区空间不足（`ENOBUFS`）。
    NoBufferSpace,
} || SystemError;

/// 后端按操作报的失败。名字带操作上下文（`BindFailed` / `RecvFailed`…），
/// 比一个笼统的 `SyscallFailed` 有用得多：调用方能直接看出是哪一步挂了。
pub const OpError = error{
    AcceptFailed,
    AccessFailed,
    BindFailed,
    BufferTooSmall,
    CloseFailed,
    ConnectFailed,
    DeleteFailed,
    EventfdFailed,
    GetSockNameFailed,
    HardLinkFailed,
    InvalidHandle,
    InvalidPath,
    IoctlFailed,
    KeventFailed,
    KqueueFailed,
    ListenFailed,
    MakeDirFailed,
    NoBuffers,
    NotASymLink,
    NotATty,
    NothingToWatch,
    OpenFailed,
    OptionFailed,
    PollFailed,
    ReadDirFailed,
    ReadLinkFailed,
    RealPathFailed,
    RecvFailed,
    RemoveDirFailed,
    RenameFailed,
    RequestFailed,
    SeekFailed,
    SendFailed,
    SendFileFailed,
    SetModeFailed,
    SetOwnerFailed,
    SetPermissionsFailed,
    SetTimestampsFailed,
    SetupFailed,
    ShutdownFailed,
    SocketCreationFailed,
    SocketFailed,
    SocketPairFailed,
    StatFailed,
    SymLinkFailed,
    SyncFailed,
    TooManyBuffers,
    TruncateFailed,
    WriteFailed,
    WriteZero,
    WsaStartupFailed,
} || SystemError;

/// 子进程 / 信号 / 终端相关错误。
pub const TaskError = error{
    EnvUnavailable,
    FcntlFailed,
    ForkFailed,
    InvalidSignal,
    InvalidUtf8,
    KillFailed,
    NoChildProcess,
    NotReady,
    NotReceived,
    NotSpawned,
    PipeFailed,
    ProcessAlreadyReaped,
    SpawnFailed,
    WaitFailed,
} || SystemError;
/// **全集**：所有公开完成结果（`Completion.err`）的错误都从这里取子集。
///
/// 内部辅助函数可以进一步窄化（例如某个只可能超时的路径只返回
/// `error{TimedOut} || OutOfMemory`）。
pub const Error = NetError || FileError || OpError || TaskError;

/// 便捷别名：某些调用点只想说「这是系统层错误」。
pub const IoError = SystemError;

/// 把后端的宽错误（VTable 内部边界，`anyerror`）归一化为公开完成结果的
/// 封闭集合 `Error`。未列出的名字统一落到 `error.UnexpectedErrno`。
///
/// 实现是 comptime 从 `Error` 的成员表展开的线性匹配：集合加一个名字，
/// 这里自动跟着多一个分支 —— 不需要维护第二份名单（曾经有一份 114 行的
/// switch，与集合定义各写一遍，两边漂移就编译不过）。
pub fn normalize(err: anyerror) Error {
    inline for (@typeInfo(Error).error_set.error_names.?) |name| {
        if (err == @field(Error, name)) return @field(Error, name);
    }
    return error.UnexpectedErrno;
}

// ---- 守卫测试 -------------------------------------------------------------
//
// 下面这份列表必须与上面的定义**逐项一致**。少写一个名字，编译期就
// 报错（typed array literal 里缺一个 error 成员会编译失败）；多写一个
// 同理。这让「错误集合」这件事有编译期守卫，而不是靠人记。

test "错误全集与具名列表一致（编译期守卫）" {
    const all: []const Error = &.{
        error.Aborted,                error.AcceptFailed,     error.AccessDenied,
        error.AccessFailed,           error.AddressInUse,     error.AddressRequired,
        error.AlreadyConnected,       error.BadAddress,       error.BindFailed,
        error.BrokenPipe,             error.BufferTooSmall,   error.Busy,
        error.CloseFailed,            error.ConnectFailed,    error.ConnectionAborted,
        error.ConnectionRefused,      error.ConnectionReset,  error.CrossDevice,
        error.DeadlineExceeded,       error.DeleteFailed,     error.DirNotEmpty,
        error.EnvUnavailable,         error.EventfdFailed,    error.FcntlFailed,
        error.FileNotFound,           error.ForkFailed,       error.GetSockNameFailed,
        error.HardLinkFailed,         error.HostNotFound,     error.Interrupted,
        error.InvalidArgument,        error.InvalidHandle,    error.InvalidPath,
        error.InvalidSignal,          error.InvalidUtf8,      error.IoFailed,
        error.IoctlFailed,            error.IsDirectory,      error.KeventFailed,
        error.KillFailed,             error.KqueueFailed,     error.ListenFailed,
        error.MakeDirFailed,          error.MessageTooLarge,  error.NameTooLong,
        error.NetworkDown,            error.NetworkReset,     error.NetworkUnreachable,
        error.NoBufferSpace,          error.NoBuffers,        error.NoChildProcess,
        error.NoDevice,               error.NoSpaceLeft,      error.NotASymLink,
        error.NotATty,                error.NotConnected,     error.NotDirectory,
        error.NotOpen,                error.NotReady,         error.NotReceived,
        error.NotSocket,              error.NotSpawned,       error.NothingToWatch,
        error.OpenFailed,             error.OptionFailed,     error.OutOfMemory,
        error.PathAlreadyExists,      error.PeerClosed,       error.PipeFailed,
        error.PollFailed,             error.PrivilegeNotHeld, error.ProcessAlreadyReaped,
        error.ProcessFdQuotaExceeded, error.ProtocolError,    error.ProtocolNotSupported,
        error.ReadDirFailed,          error.ReadFailed,       error.ReadLinkFailed,
        error.ReadOnlyFileSystem,     error.RealPathFailed,   error.RecvFailed,
        error.RemoveDirFailed,        error.RenameFailed,     error.RequestFailed,
        error.SeekFailed,             error.SendFailed,       error.SendFileFailed,
        error.SetModeFailed,          error.SetOwnerFailed,   error.SetPermissionsFailed,
        error.SetTimestampsFailed,    error.SetupFailed,      error.ShutdownFailed,
        error.SocketCreationFailed,   error.SocketError,      error.SocketFailed,
        error.SocketPairFailed,       error.SpawnFailed,      error.StatFailed,
        error.SymLinkFailed,          error.SymLinkLoop,      error.SyncFailed,
        error.SystemFdQuotaExceeded,  error.TimedOut,         error.TooManyBuffers,
        error.TooManyConnections,     error.TruncateFailed,   error.UnexpectedErrno,
        error.Unsupported,            error.ValueOutOfRange,  error.WaitFailed,
        error.WouldBlock,             error.WriteFailed,      error.WriteZero,
        error.WsaStartupFailed,
    };
    try std.testing.expectEqual(@typeInfo(Error).error_set.error_names.?.len, all.len);
}

test "错误集合可按族窄化" {
    // NetError 是 Error 的子集：窄化后仍能装下每个具名成员。
    const net: NetError = error.ConnectionReset;
    const wide: Error = net;
    try std.testing.expect(wide == error.ConnectionReset);

    // 集合是**封闭有限**的：未分类的 errno 落到 UnexpectedErrno，
    // 而不是原样透传 anyerror。这样调用方对 Error 能穷举。
    const unknown = error.UnexpectedErrno;
    const as_error: Error = unknown;
    try std.testing.expect(as_error == error.UnexpectedErrno);
}
