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
    len: usize = 0,
    err: ?anyerror = null,

    /// `memory` 传 `Loop.memory_fs.lookup(path)` 的结果即可；`null` 则回落
    /// 到后端 `readFileInto`（真实文件，Work 池线程阻塞读）。
    pub fn init(io: Io, path: []const u8, buf: []u8, memory: ?[]const u8) ReadFile {
        return .{ .work = Work.init(run), .io = io, .path = path, .buf = buf, .memory = memory };
    }

    fn run(w: *Work) void {
        const self: *ReadFile = @fieldParentPtr("work", w);
        if (self.memory) |bytes| {
            const n = @min(bytes.len, self.buf.len);
            @memcpy(self.buf[0..n], bytes[0..n]);
            self.len = n;
            self.err = if (n != bytes.len) error.BufferTooSmall else null;
            return;
        }
        self.len = self.io.vtable.readFileInto(self.io.userdata, self.path, self.buf) catch |e| {
            self.err = e;
            return;
        };
    }

    pub fn getResult(self: *const ReadFile) ![]const u8 {
        if (self.err) |e| return e;
        return self.buf[0..self.len];
    }
};

/// 整文件写入。没有异步后端入口（平台层 `writeFileAll` 是同步辅助函数），
/// 因此固定走 `Work` 池：池线程做阻塞的 open/write/close，回调落在循环线程。
/// 与 `ReadFile` 对称，`Work` 节点内嵌，零额外分配。
pub const WriteFile = struct {
    work: Work,
    io: Io,
    path: []const u8,
    bytes: []const u8,
    written: usize = 0,
    err: ?anyerror = null,

    /// `bytes` 由调用方持有，必须活到回调触发为止（本结构不复制内容）。
    pub fn init(io: Io, path: []const u8, bytes: []const u8) WriteFile {
        return .{ .work = Work.init(run), .io = io, .path = path, .bytes = bytes };
    }

    fn run(w: *Work) void {
        const self: *WriteFile = @fieldParentPtr("work", w);
        self.io.vtable.writeFileAll(self.io.userdata, self.path, self.bytes) catch |e| {
            self.err = e;
            return;
        };
        self.written = self.bytes.len;
    }

    /// 成功后返回实际写入的字节数；失败时返回池线程里捕获的错误。
    pub fn getResult(self: *const WriteFile) !usize {
        if (self.err) |e| return e;
        return self.written;
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
