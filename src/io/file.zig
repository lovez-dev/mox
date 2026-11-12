//! 文件读取：默认在 `Work` 池线程里阻塞读，完成回调回到循环线程。
//!
//! 文件没有可移植的原生异步接口，因此阻塞读是通用兜底。读操作只持有 `Io`
//! 的值拷贝（`{ userdata, vtable }` 是平凡的），从而能安全地在池线程里调用
//! `io.vtable.readFileInto`，不必触碰只属于循环线程的 `*Loop`。
//!
//! `MemoryFs` 是可选的内存文件源：命中时不再 open/read/close 真实磁盘，
//! 仍走 `Loop.add → Work → 回调` 这条链路，但池线程只做一次 memcpy、不做
//! 阻塞 I/O，回调照旧在循环线程触发，因此 `server.zig` 的静态路由形状不变。

const std = @import("std");
const root = @import("io.zig");

const Io = root.Io;
const Work = root.Work;
const Handle = root.Handle;
const INVALID_HANDLE = root.INVALID_HANDLE;
const Stat = root.Stat;

/// 进程内内存文件表。条目由调用方在启动时 `mount`，生命周期必须长于
/// 任何 `ReadFile`；通常挂在 `Loop` 上，随循环一起销毁。
///
/// 线性查找：静态资源数量是几十量级，且 `mount` 只在初始化时发生，
/// 不在热路径上增删。路径按字节精确匹配，不做任何规范化——调用方传什么
/// 就查什么，避免「../」之类的隐式语义。
pub const MemoryFs = struct {
    pub const Entry = struct {
        path: []const u8,
        bytes: []const u8,
    };

    entries: std.ArrayListUnmanaged(Entry) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MemoryFs {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MemoryFs) void {
        // 只释放条目数组；`path` / `bytes` 归调用方所有，不在此释放。
        self.entries.deinit(self.allocator);
        self.entries = .empty;
    }

    /// 注册一个内存文件。同名路径再次 mount 会覆盖旧条目，便于热替换。
    /// 不复制 `path` / `bytes`，调用方必须保证它们在挂载期间存活。
    pub fn mount(self: *MemoryFs, path: []const u8, bytes: []const u8) !void {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.path, path)) {
                e.bytes = bytes;
                return;
            }
        }
        try self.entries.append(self.allocator, .{ .path = path, .bytes = bytes });
    }

    pub fn lookup(self: *const MemoryFs, path: []const u8) ?[]const u8 {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.path, path)) return e.bytes;
        }
        return null;
    }

    pub fn size(self: *const MemoryFs, path: []const u8) ?u64 {
        return if (self.lookup(path)) |b| b.len else null;
    }
};

pub const ReadFile = struct {
    work: Work,
    io: Io,
    path: []const u8,
    buf: []u8,
    /// 非空表示命中内存文件：`run` 直接 memcpy，不碰磁盘、不进池外的 I/O。
    memory: ?[]const u8 = null,
    /// 起始偏移。为 0 时走整文件 `readFileInto`；非 0 走 `readFileAt`
    /// （随机访问），是分段读大文件的基础。
    offset: u64 = 0,
    len: usize = 0,
    err: ?anyerror = null,

    /// `memory` 传 `Loop.memory_fs.lookup(path)` 的结果即可；`null` 则回落
    /// 到后端 `readFileInto`（真实文件，Work 池线程阻塞读）。
    pub fn init(io: Io, path: []const u8, buf: []u8, memory: ?[]const u8) ReadFile {
        return .{ .work = Work.init(run), .io = io, .path = path, .buf = buf, .memory = memory };
    }

    /// 从 `offset` 开始读。命中内存文件时按偏移切片，不碰磁盘。
    pub fn initAt(io: Io, path: []const u8, offset: u64, buf: []u8, memory: ?[]const u8) ReadFile {
        return .{ .work = Work.init(run), .io = io, .path = path, .buf = buf, .memory = memory, .offset = offset };
    }

    fn run(w: *Work) void {
        const self: *ReadFile = @fieldParentPtr("work", w);
        if (self.memory) |bytes| {
            // 偏移超出文件长度时读到 0 字节，与真实文件的短读语义一致。
            const rest = if (self.offset < bytes.len) bytes[@intCast(self.offset)..] else bytes[bytes.len..];
            const n = @min(rest.len, self.buf.len);
            @memcpy(self.buf[0..n], rest[0..n]);
            self.len = n;
            self.err = if (n != rest.len) error.BufferTooSmall else null;
            return;
        }
        self.len = if (self.offset == 0)
            self.io.vtable.readFileInto(self.io.userdata, self.path, self.buf) catch |e| {
                self.err = e;
                return;
            }
        else
            self.io.vtable.readFileAt(self.io.userdata, self.path, self.offset, self.buf) catch |e| {
                self.err = e;
                return;
            };
    }

    pub fn getResult(self: *const ReadFile) ![]const u8 {
        if (self.err) |e| return e;
        return self.buf[0..self.len];
    }
};

/// 把文件内容零拷贝送进套接字。POSIX 走 `sendfile(2)`：数据从页缓存直接进
/// socket 缓冲，不经用户态。Windows 无对应绑定，节点返回 `error.Unsupported`
/// （调用方应回落到「读进缓冲再 `send`」）。
///
/// 走 `Work` 池而不是异步后端：`sendfile` 本身在数据量大时才会阻塞，
/// 而它已经是零拷贝——把两者结合，就同时拿到「不阻塞循环」和「不复制数据」。
pub const SendFile = struct {
    work: Work,
    io: Io,
    socket: Handle,
    path: []const u8,
    offset: u64 = 0,
    /// 最多发多少字节。0 表示整文件。
    count: usize = 0,
    sent: usize = 0,
    err: ?anyerror = null,

    pub fn init(io: Io, socket: Handle, path: []const u8) SendFile {
        return .{ .work = Work.init(run), .io = io, .socket = socket, .path = path };
    }

    pub fn initCount(io: Io, socket: Handle, path: []const u8, offset: u64, count: usize) SendFile {
        return .{ .work = Work.init(run), .io = io, .socket = socket, .path = path, .offset = offset, .count = count };
    }

    fn run(w: *Work) void {
        const self: *SendFile = @fieldParentPtr("work", w);
        const f = self.io.vtable.sendFileTo orelse {
            self.err = error.Unsupported;
            return;
        };
        self.sent = f(self.io.userdata, self.socket, self.path, self.offset, self.count) catch |e| {
            self.err = e;
            return;
        };
    }

    pub fn getResult(self: *const SendFile) !usize {
        if (self.err) |e| return e;
        return self.sent;
    }
};

/// 整文件写入。没有异步后端入口（平台层 `writeFileAll` 是同步辅助函数），
/// 因此固定走 `Work` 池：池线程做阻塞的 open/write/close，回调落在循环线程。
/// 与 `ReadFile` 对称，`Work` 节点内嵌，零额外分配。
pub const WriteFile = struct {
    /// 覆盖既有内容（默认），还是追加到末尾。
    pub const Mode = enum { overwrite, append };

    work: Work,
    io: Io,
    path: []const u8,
    bytes: []const u8,
    mode: Mode = .overwrite,
    written: usize = 0,
    err: ?anyerror = null,

    /// `bytes` 由调用方持有，必须活到回调触发为止（本结构不复制内容）。
    pub fn init(io: Io, path: []const u8, bytes: []const u8) WriteFile {
        return .{ .work = Work.init(run), .io = io, .path = path, .bytes = bytes };
    }

    /// 追加模式：保留既有内容，把 `bytes` 写到末尾；文件不存在时创建。
    pub fn initAppend(io: Io, path: []const u8, bytes: []const u8) WriteFile {
        return .{ .work = Work.init(run), .io = io, .path = path, .bytes = bytes, .mode = .append };
    }

    fn run(w: *Work) void {
        const self: *WriteFile = @fieldParentPtr("work", w);
        switch (self.mode) {
            .overwrite => self.io.vtable.writeFileAll(self.io.userdata, self.path, self.bytes) catch |e| {
                self.err = e;
                return;
            },
            .append => self.io.vtable.appendFile(self.io.userdata, self.path, self.bytes) catch |e| {
                self.err = e;
                return;
            },
        }
        self.written = self.bytes.len;
    }

    /// 成功后返回实际写入的字节数；失败时返回池线程里捕获的错误。
    pub fn getResult(self: *const WriteFile) !usize {
        if (self.err) |e| return e;
        return self.written;
    }
};

/// 把文件截断到指定长度。走 `Work` 池，与读写对称。
pub const TruncateFile = struct {
    work: Work,
    io: Io,
    path: []const u8,
    size: u64,
    err: ?anyerror = null,

    pub fn init(io: Io, path: []const u8, size: u64) TruncateFile {
        return .{ .work = Work.init(run), .io = io, .path = path, .size = size };
    }

    fn run(w: *Work) void {
        const self: *TruncateFile = @fieldParentPtr("work", w);
        self.io.vtable.truncateFile(self.io.userdata, self.path, self.size) catch |e| {
            self.err = e;
        };
    }

    pub fn getResult(self: *const TruncateFile) !void {
        if (self.err) |e| return e;
    }
};

/// 删除文件。走 `Work` 池。
/// 注意：平台层 `deleteFile` 返回 `void`，所有失败都被吞掉（含文件不存在
/// 与权限不足），所以 `getResult()` 实际上永远不会报错。
pub const DeleteFile = struct {
    work: Work,
    io: Io,
    path: []const u8,
    err: ?anyerror = null,

    pub fn init(io: Io, path: []const u8) DeleteFile {
        return .{ .work = Work.init(run), .io = io, .path = path };
    }

    fn run(w: *Work) void {
        const self: *DeleteFile = @fieldParentPtr("work", w);
        self.io.vtable.deleteFile(self.io.userdata, self.path) catch |e| {
            self.err = e;
        };
    }

    pub fn getResult(self: *const DeleteFile) !void {
        if (self.err) |e| return e;
    }
};

// ---- 文件句柄层节点（阶段 A）----------------------------------------------
// 路径式 API 每次调用都要重新 open/close；这四个节点把句柄交给调用方，
// 让它「打开一次、读写多次、显式关闭」。全部走 `Work` 池：文件没有
// 可移植的原生异步接口，用池线程阻塞是最诚实的做法。
//
// 生命周期约定（重要）：
// - `OpenFile` 成功后句柄归调用方，必须由调用方 `CloseFile` 关闭。
//   节点本身不关闭，否则调用方拿到的是已失效句柄。
// - `path` / `bytes` / `buf` 都由调用方持有，必须活到回调触发为止。

/// 打开文件，拿到句柄。
pub const OpenFile = struct {
    work: Work,
    io: Io,
    path: []const u8,
    mode: root.FileMode = .read_only,
    file: Handle = INVALID_HANDLE,
    err: ?anyerror = null,

    pub fn init(io: Io, path: []const u8, mode: root.FileMode) OpenFile {
        return .{ .work = Work.init(run), .io = io, .path = path, .mode = mode };
    }

    fn run(w: *Work) void {
        const self: *OpenFile = @fieldParentPtr("work", w);
        const vt = self.io.vtable.openFile orelse {
            self.err = error.Unsupported;
            return;
        };
        self.file = vt(self.io.userdata, self.path, self.mode) catch |e| {
            self.err = e;
            return;
        };
    }

    /// 成功后返回句柄。**调用方负责关闭**。
    pub fn getResult(self: *const OpenFile) !Handle {
        if (self.err) |e| return e;
        return self.file;
    }
};

/// 从已打开的句柄按 `offset` 读入 `buf`。
pub const ReadFileHandle = struct {
    work: Work,
    io: Io,
    file: Handle,
    offset: u64 = 0,
    buf: []u8,
    len: usize = 0,
    err: ?anyerror = null,

    pub fn init(io: Io, file: Handle, offset: u64, buf: []u8) ReadFileHandle {
        return .{ .work = Work.init(run), .io = io, .file = file, .offset = offset, .buf = buf };
    }

    fn run(w: *Work) void {
        const self: *ReadFileHandle = @fieldParentPtr("work", w);
        const vt = self.io.vtable.readFileHandle orelse {
            self.err = error.Unsupported;
            return;
        };
        self.len = vt(self.io.userdata, self.file, self.offset, self.buf) catch |e| {
            self.err = e;
            return;
        };
    }

    /// 成功返回 `buf[0..实际字节数]`（文件尾短读不报错）。
    pub fn getResult(self: *const ReadFileHandle) ![]const u8 {
        if (self.err) |e| return e;
        return self.buf[0..self.len];
    }
};

/// 向已打开的句柄按 `offset` 写入 `bytes`。
pub const WriteFileHandle = struct {
    work: Work,
    io: Io,
    file: Handle,
    offset: u64 = 0,
    bytes: []const u8,
    written: usize = 0,
    err: ?anyerror = null,

    /// `bytes` 由调用方持有，必须活到回调触发为止（不复制内容）。
    pub fn init(io: Io, file: Handle, offset: u64, bytes: []const u8) WriteFileHandle {
        return .{ .work = Work.init(run), .io = io, .file = file, .offset = offset, .bytes = bytes };
    }

    fn run(w: *Work) void {
        const self: *WriteFileHandle = @fieldParentPtr("work", w);
        const vt = self.io.vtable.writeFileHandle orelse {
            self.err = error.Unsupported;
            return;
        };
        self.written = vt(self.io.userdata, self.file, self.offset, self.bytes) catch |e| {
            self.err = e;
            return;
        };
    }

    pub fn getResult(self: *const WriteFileHandle) !usize {
        if (self.err) |e| return e;
        return self.written;
    }
};

/// 关闭句柄。**同步完成**：关闭本身不阻塞，没必要进池，
/// 也避免「调用方以为关了、其实还在排队」的悬垂窗口。
pub const CloseFile = struct {
    io: Io,
    file: Handle,

    pub fn init(io: Io, file: Handle) CloseFile {
        return .{ .io = io, .file = file };
    }

    /// 立即关闭。幂等：重复关闭或无效句柄不报错。
    pub fn close(self: *const CloseFile) void {
        if (self.io.vtable.closeFile) |vt| vt(self.io.userdata, self.file);
    }
};

// ---- 句柄级元数据与同步节点（阶段 B）--------------------------------------
// 三个都走 `Work` 池，与读写节点对称。

/// 取句柄元数据（类型/大小/mtime）。
pub const StatFile = struct {
    work: Work,
    io: Io,
    file: Handle,
    stat: Stat = .{ .kind = .other, .size = 0, .mtime_ms = 0 },
    err: ?anyerror = null,

    pub fn init(io: Io, file: Handle) StatFile {
        return .{ .work = Work.init(run), .io = io, .file = file };
    }

    fn run(w: *Work) void {
        const self: *StatFile = @fieldParentPtr("work", w);
        const vt = self.io.vtable.statFile orelse {
            self.err = error.Unsupported;
            return;
        };
        self.stat = vt(self.io.userdata, self.file) catch |e| {
            self.err = e;
            return;
        };
    }

    pub fn getResult(self: *const StatFile) !Stat {
        if (self.err) |e| return e;
        return self.stat;
    }
};

/// 把句柄对应文件截断到指定长度。
pub const SetFileSize = struct {
    work: Work,
    io: Io,
    file: Handle,
    size: u64,
    err: ?anyerror = null,

    pub fn init(io: Io, file: Handle, size: u64) SetFileSize {
        return .{ .work = Work.init(run), .io = io, .file = file, .size = size };
    }

    fn run(w: *Work) void {
        const self: *SetFileSize = @fieldParentPtr("work", w);
        const vt = self.io.vtable.setFileSize orelse {
            self.err = error.Unsupported;
            return;
        };
        vt(self.io.userdata, self.file, self.size) catch |e| {
            self.err = e;
            return;
        };
    }

    pub fn getResult(self: *const SetFileSize) !void {
        if (self.err) |e| return e;
    }
};

/// 把缓冲内容刷到磁盘（`fsync` / `FlushFileBuffers`）。
pub const SyncFile = struct {
    work: Work,
    io: Io,
    file: Handle,
    err: ?anyerror = null,

    pub fn init(io: Io, file: Handle) SyncFile {
        return .{ .work = Work.init(run), .io = io, .file = file };
    }

    fn run(w: *Work) void {
        const self: *SyncFile = @fieldParentPtr("work", w);
        const vt = self.io.vtable.syncFile orelse {
            self.err = error.Unsupported;
            return;
        };
        vt(self.io.userdata, self.file) catch |e| {
            self.err = e;
            return;
        };
    }

    pub fn getResult(self: *const SyncFile) !void {
        if (self.err) |e| return e;
    }
};

test "MemoryFs 查找与覆盖" {
    var fs = MemoryFs.init(std.testing.allocator);
    defer fs.deinit();
    try fs.mount("/a", "hello");
    try std.testing.expectEqualStrings("hello", fs.lookup("/a").?);
    try std.testing.expectEqual(@as(u64, 5), fs.size("/a").?);
    try std.testing.expect(fs.lookup("/b") == null);
    try fs.mount("/a", "world!!");
    try std.testing.expectEqualStrings("world!!", fs.lookup("/a").?);
    try std.testing.expectEqual(@as(usize, 1), fs.entries.items.len);
}
