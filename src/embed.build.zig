//! mox 的编译期 VFS 生成插件（在调用方的 build.zig 里执行）。
//!
//! 递归扫描若干目录，把每个文件以字节数组形式内联进一份生成的 Zig
//! 源码，导出 `files`（按路径排序）与 `mount(loop)`。调用方在运行时
//! 一句 `try mox_vfs.mount(&loop)`，就能让 `mox_io.Loop.memory_fs`
//! 命中这些静态资源，静态路由不再碰磁盘。
//!
//! 为什么生成 .zig 源码而不是数据文件：`@embedFile` 不能跨包路径，
//! 而且在 build 期展开成 `[_]Entry` 能让编译期做排序 / 去重校验，
//! 运行期零解析、零分配。
//!
//! 用法（调用方 build.zig）：
//!     const mox_build = std.Build.lazyImport(b, @This(), "mox") orelse
//!         @panic("mox 依赖未就绪");
//!     const embed = mox_build.addEmbed(b, .{
//!         .dirs = &.{
//!             .{ .dir = "assets", .mount = "/assets" },
//!             .{ .dir = "templates", .mount = "/tmpl" },
//!         },
//!     });
//!     exe.step.dependOn(embed.step);
//!     exe.root_module.addImport("mox_vfs", embed.module);
//!
//! 运行时：
//!     var loop = try mox_io.open(gpa, .{});
//!     defer loop.deinit();
//!     try @import("mox_vfs").mount(&loop);

const std = @import("std");

pub const Options = struct {
    /// 一个待扫描目录；`mount` 给该目录下所有路径加前缀，必须以 `/` 开头
    /// 且与 HTTP 请求路径一致（例如 `/assets` 对应 `/assets/app.css`）。
    /// 为空表示不加前缀、文件直接挂在 VFS 根下（此时相对路径前应自带 `/`，
    /// 由 `dir` 内的目录结构决定）。
    pub const Mount = struct {
        dir: []const u8,
        mount: []const u8 = "",
    };
    dirs: []const Mount,
    /// 单文件体积上限；超限直接让构建失败，避免把大文件默默内联。
    max_file_size: usize = 8 << 20,
    /// 在生成产物里注入构建时的 git 版本戳（`git_rev` 字段）。
    /// 取 `"<short-rev>"`，工作树有改动时追加 `-dirty`；git 不可用或
    /// 不在仓库里时回落为 `"dirty"`，不会让构建失败。
    git_rev: bool = false,
};

pub const Generated = struct {
    /// 依赖这个 step 保证生成产物是最新的。
    step: *std.Build.Step,
    /// 生成的模块，用 `addImport("mox_vfs", ...)` 挂给可执行文件。
    module: *std.Build.Module,
};

/// 生成产物模板：`@ENTRIES@` 会被排序后的条目替换，`@GIT_REV@` 换成版本戳。
/// 所有声明都收在 `Embed` 结构里，避免污染调用方的命名空间。
const body =
    \\const std = @import("std");
    \\
    \\pub const Embed = struct {
    \\    pub const Entry = struct { path: []const u8, size: usize, data: []const u8 };
    \\
    \\    /// 按 path 升序（生成器保证），可用二分查找。
    \\    pub const files = [_]Entry{
    \\    @ENTRIES@
    \\    };
    \\
    \\    /// 构建时注入的 git 版本戳；`git_rev = false` 时为 "dirty"。
    \\    pub const git_rev = "@GIT_REV@";
    \\
    \\    pub const count = Embed.files.len;
    \\
    \\    comptime {
    \\        @setEvalBranchQuota(1_000_000);
    \\        for (Embed.files, 0..) |f, i| {
    \\            if (i > 0 and std.mem.order(u8, Embed.files[i - 1].path, f.path) != .lt)
    \\                @compileError("mox_vfs: 路径未排序或重复：" ++ f.path);
    \\        }
    \\    }
    \\
    \\    fn orderPath(path: []const u8, e: Entry) std.math.Order {
    \\        return std.mem.order(u8, path, e.path);
    \\    }
    \\
    \\    /// O(log n) 查找；未命中返回 null。
    \\    pub fn get(path: []const u8) ?[]const u8 {
    \\        const i = std.sort.binarySearch(Entry, &Embed.files, path, orderPath) orelse return null;
    \\        return Embed.files[i].data;
    \\    }
    \\
    \\    /// O(log n) 存在性判断。
    \\    pub fn exists(path: []const u8) bool {
    \\        return std.sort.binarySearch(Entry, &Embed.files, path, orderPath) != null;
    \\    }
    \\
    \\    /// 同前缀的条目在有序数组里是连续的一段：二分找下界后向后扫。
    \\    /// 返回 `files` 的零拷贝切片。
    \\    pub fn list(prefix: []const u8) []const Entry {
    \\        var lo: usize = 0;
    \\        var hi: usize = Embed.files.len;
    \\        while (lo < hi) {
    \\            const mid = lo + (hi - lo) / 2;
    \\            if (std.mem.order(u8, Embed.files[mid].path, prefix) == .lt) lo = mid + 1 else hi = mid;
    \\        }
    \\        var end = lo;
    \\        while (end < Embed.files.len and std.mem.startsWith(u8, Embed.files[end].path, prefix)) end += 1;
    \\        return Embed.files[lo..end];
    \\    }
    \\
    \\    /// 把全部文件挂到 `mox_io.Loop.memory_fs` 上。
    \\    /// 用 `anytype` 是为了让生成模块不依赖 mox 的模块名——调用方
    \\    /// 用什么名字 import mox_io 都无所谓，只要传进来的东西有
    \\    /// `mountMemory([]const u8, []const u8)` 即可。
    \\    /// 已存在的同名路径会被覆盖（与 `MemoryFs.mount` 语义一致）。
    \\    pub fn mount(loop: anytype) !void {
    \\        for (Embed.files) |f| try loop.mountMemory(f.path, f.data);
    \\    }
    \\};
    \\
    \\pub const files = Embed.files;
    \\pub const git_rev = Embed.git_rev;
    \\pub const count = Embed.count;
    \\pub const get = Embed.get;
    \\pub const exists = Embed.exists;
    \\pub const list = Embed.list;
    \\pub const mount = Embed.mount;
;

const FileEntry = struct { path: []const u8, data: []const u8 };

fn lessThan(_: void, a: FileEntry, b: FileEntry) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

/// 拼接一个 VFS key：规范化分隔符 + 加挂载前缀。
/// 强制前缀以 `/` 开头，避免生成一个运行时永远匹配不到的
/// `assets/app.css` 而 HTTP 请求却是 `/assets/app.css`。
fn makeKey(a: std.mem.Allocator, mount: []const u8, rel: []const u8) []const u8 {
    const norm = normalizePath(a, rel);
    if (mount.len == 0) {
        if (norm.len == 0 or norm[0] != '/') {
            std.debug.print("[mox_vfs] mount 为空时路径必须以 / 开头：{s}\n", .{norm});
            @panic("mox_vfs: 路径缺少前导 /");
        }
        return norm;
    }
    if (mount[0] != '/') {
        std.debug.print("[mox_vfs] mount 必须以 / 开头：{s}\n", .{mount});
        @panic("mox_vfs: mount 缺少前导 /");
    }
    const trimmed = std.mem.trimEnd(u8, mount, "/");
    return std.fmt.allocPrint(a, "{s}/{s}", .{ trimmed, std.mem.trimStart(u8, norm, "/") }) catch @panic("OOM");
}

/// 构建期工作：扫目录、排序、查重、拼出条目文本。
fn genEntries(b: *std.Build, opts: Options) []const u8 {
    const a = b.allocator;
    const io = b.graph.io;
    var list: std.ArrayList(FileEntry) = .empty;

    for (opts.dirs) |m| {
        var root = std.Io.Dir.cwd().openDir(io, m.dir, .{ .iterate = true }) catch {
            std.debug.print("[mox_vfs] 目录不存在：{s}\n", .{m.dir});
            continue;
        };
        defer root.close(io);
        var walker = root.walk(a) catch @panic("OOM");
        defer walker.deinit();
        while (walker.next(io) catch @panic("mox_vfs: 遍历目录失败")) |ent| {
            if (ent.kind != .file) continue;
            const data = ent.dir.readFileAlloc(io, ent.basename, a, .limited(opts.max_file_size + 1)) catch @panic("mox_vfs: 读取文件失败");
            if (data.len > opts.max_file_size) {
                std.debug.print("[mox_vfs] 文件过大 {d} > {d}：{s}/{s}\n", .{ data.len, opts.max_file_size, m.dir, ent.basename });
                @panic("mox_vfs: 文件超过大小上限");
            }
            const key = makeKey(a, m.mount, ent.path);
            list.append(a, .{ .path = key, .data = data }) catch @panic("OOM");
        }
    }

    std.mem.sort(FileEntry, list.items, {}, lessThan);
    for (list.items[1..], list.items[0 .. list.items.len - 1]) |cur, prev| {
        if (std.mem.eql(u8, prev.path, cur.path)) {
            std.debug.print("[mox_vfs] 路径重复：{s}\n", .{cur.path});
            @panic("mox_vfs: 重复路径");
        }
    }

    var out: std.ArrayList(u8) = .empty;
    for (list.items) |f| emitEntry(a, &out, f);
    return out.items;
}

/// 一条条目写成纯 Zig 源码。每行 16 字节便于 diff；行尾的逗号由
/// need_sep 控制，避免和条目末尾的逗号重复。
fn emitEntry(a: std.mem.Allocator, out: *std.ArrayList(u8), f: FileEntry) void {
    out.print(a, "    .{{ .path = \"{s}\", .size = {d}, .data = &[_]u8{{", .{ f.path, f.data.len }) catch @panic("OOM");
    var need_sep = false;
    for (f.data, 0..) |byte, i| {
        if (need_sep) out.appendSlice(a, ", ") catch @panic("OOM");
        need_sep = true;
        out.print(a, "0x{x:0>2}", .{byte}) catch @panic("OOM");
        if ((i + 1) % 16 == 0) {
            out.appendSlice(a, ",\n        ") catch @panic("OOM");
            need_sep = false;
        }
    }
    out.appendSlice(a, "} },\n") catch @panic("OOM");
}

/// 把 Windows 路径分隔符统一成 `/`，保证 VFS key 跨平台稳定。
fn normalizePath(a: std.mem.Allocator, path: []const u8) []u8 {
    const copy = a.dupe(u8, path) catch @panic("OOM");
    for (copy) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return copy;
}

/// 查询构建时的 git 版本戳：`"<short-rev>"`，工作树有改动追加 `-dirty`。
/// git 缺失 / 不在仓库 / 命令失败一律回落 `"dirty"`，绝不让构建失败。
fn gitRev(b: *std.Build) []const u8 {
    const a = b.allocator;
    const io = b.graph.io;
    const rev = blk: {
        const r = std.process.run(a, io, .{ .argv = &.{ "git", "rev-parse", "--short=12", "HEAD" } }) catch break :blk "";
        const s = std.mem.trim(u8, r.stdout, " \r\n");
        // 先 dupe 再释放 stdout，否则裁剪出的切片会悬空。
        const owned = a.dupe(u8, s) catch break :blk "";
        a.free(r.stdout);
        a.free(r.stderr);
        if (r.term != .exited or r.term.exited != 0) break :blk "";
        break :blk owned;
    };
    if (rev.len == 0) return "dirty";
    const dirty = blk: {
        const r = std.process.run(a, io, .{ .argv = &.{ "git", "diff", "--quiet" } }) catch break :blk false;
        break :blk !r.term.success();
    };
    if (!dirty) return rev;
    return std.fmt.allocPrint(a, "{s}-dirty", .{rev}) catch rev;
}

/// 完全在进程内生成：扫目录 + 模板替换，然后交给 `WriteFiles`。
/// 不需要辅助可执行文件，也不落临时文件。
pub fn add(b: *std.Build, opts: Options) Generated {
    const a = b.allocator;
    const rev = if (opts.git_rev) gitRev(b) else "dirty";
    var product: []const u8 = body;
    product = std.mem.replaceOwned(u8, a, product, "@ENTRIES@", genEntries(b, opts)) catch @panic("OOM");
    product = std.mem.replaceOwned(u8, a, product, "@GIT_REV@", rev) catch @panic("OOM");

    const wf = b.addWriteFiles();
    const out_file = wf.add("mox_vfs_gen.zig", product);
    return .{
        .step = &wf.step,
        .module = b.createModule(.{ .root_source_file = out_file }),
    };
}
