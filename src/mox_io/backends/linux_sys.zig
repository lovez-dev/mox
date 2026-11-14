//! Linux 共用系统操作：同步 socket、文件系统与地址编组。
//! io_uring 和 epoll 共同依赖本模块；本模块不依赖任何事件后端或 Loop。
const std = @import("std");
const linux = std.os.linux;
const types = @import("../types.zig");
const sys = @import("../sys.zig");
const net = std.Io.net;
const Handle = types.Handle;
pub const IOV_MAX = 32;
fn fdOf(h: Handle) i32 {
    return @intCast(h);
}

fn signed(rc: usize) isize {
    return @bitCast(rc);
}

fn cvt(rc: usize) !usize {
    if (signed(rc) < 0) return sys.fromSyscall(signed(rc));
    return rc;
}

fn cvtFd(rc: usize) !i32 {
    _ = try cvt(rc);
    return @intCast(rc);
}

pub fn buildUnixSockaddrPub(path: []const u8, storage: *linux.sockaddr.un) !linux.socklen_t {
    return buildUnixSockaddr(path, storage);
}

pub fn buildUnixSockaddr(path: []const u8, storage: *linux.sockaddr.un) !linux.socklen_t {
    // 留一个字节给 NUL。
    if (path.len >= storage.path.len) return error.NameTooLong;
    if (path.len == 0) return error.InvalidPath;
    storage.family = linux.AF.UNIX;
    @memcpy(storage.path[0..path.len], path);
    storage.path[path.len] = 0;
    // 长度按「结构头 + 路径 + NUL」算，不传整个 108 字节，否则内核会读到
    // 缓冲区里的垃圾字节。
    return @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1);
}

pub fn vtCreateUnix(userdata: ?*anyopaque) anyerror!types.Handle {
    _ = userdata;
    return createSocket(linux.AF.UNIX, linux.SOCK.STREAM, 0);
}

pub fn vtBindUnix(userdata: ?*anyopaque, socket: types.Handle, path: []const u8) anyerror!void {
    _ = userdata;
    var sa: linux.sockaddr.un = undefined;
    const len = try buildUnixSockaddr(path, &sa);
    const rc_s = signed(linux.bind(fdOf(socket), @ptrCast(&sa), len));
    if (rc_s < 0) {
        if (rc_s == -@as(isize, @backingInt(linux.E.ADDRINUSE))) return error.PathAlreadyExists;
        return error.BindFailed;
    }
}

pub fn openSync(path: [*:0]const u8, flags: linux.O, mode: linux.mode_t) !linux.fd_t {
    const rc = linux.openat(linux.AT.FDCWD, path, flags, mode);
    const rc_s = signed(rc);
    if (rc_s < 0) return switch (-rc_s) {
        @backingInt(linux.E.NOENT) => error.FileNotFound,
        @backingInt(linux.E.ACCES) => error.AccessDenied,
        @backingInt(linux.E.ISDIR) => error.IsDirectory,
        @backingInt(linux.E.NAMETOOLONG) => error.NameTooLong,
        else => error.OpenFailed,
    };
    return @intCast(rc_s);
}

pub fn vtSendFileTo(
    userdata: ?*anyopaque,
    socket: types.Handle,
    path: []const u8,
    offset: u64,
    count: usize,
) anyerror!usize {
    _ = userdata;
    var zbuf: [4096]u8 = undefined;
    const zpath = try pathZ(path, &zbuf);

    const in_fd = openSync(zpath, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch |e| return e;
    defer _ = linux.close(in_fd);

    const out_fd = fdOf(socket);
    var off: linux.off_t = @intCast(offset);
    // `count == 0` 表示整文件：先问出大小再发。
    var remaining: usize = if (count == 0) blk: {
        const st = try stat(path);
        break :blk @intCast(st.size - @min(st.size, offset));
    } else count;

    var total: usize = 0;
    while (remaining > 0) {
        const chunk = @min(remaining, 0x7ffff000);
        const rc = linux.sendfile(out_fd, in_fd, &off, chunk);
        const rc_s: isize = @bitCast(rc);
        if (rc_s < 0) {
            if (total != 0) break; // 已经发出去一部分，当作短写
            return switch (-rc_s) {
                @backingInt(linux.E.NOENT) => error.FileNotFound,
                @backingInt(linux.E.PIPE) => error.BrokenPipe,
                else => error.SendFileFailed,
            };
        }
        if (rc_s == 0) break; // 文件读完
        total += @intCast(rc_s);
        remaining -= @intCast(rc_s);
    }
    return total;
}

// ---- sockaddr 编组 ---------------------------------------------------------

/// 把 `address` 以 `sockaddr` 形式写入 `storage`，返回其长度。
pub fn buildSockaddr(address: net.IpAddress, storage: []u8) linux.socklen_t {
    switch (address) {
        .ip4 => |a| {
            const sa = linux.sockaddr.in{
                .port = std.mem.nativeToBig(u16, a.port),
                .addr = @bitCast(a.bytes),
            };
            @memcpy(storage[0..@sizeOf(linux.sockaddr.in)], std.mem.asBytes(&sa));
            return @sizeOf(linux.sockaddr.in);
        },
        .ip6 => |a| {
            const sa = linux.sockaddr.in6{
                .port = std.mem.nativeToBig(u16, a.port),
                .flowinfo = 0,
                .addr = a.bytes,
                .scope_id = 0,
            };
            @memcpy(storage[0..@sizeOf(linux.sockaddr.in6)], std.mem.asBytes(&sa));
            return @sizeOf(linux.sockaddr.in6);
        },
    }
}

fn fromSockaddr(storage: *const [128]u8) net.IpAddress {
    const family = @as(*align(1) const linux.sa_family_t, @ptrCast(storage)).*;
    if (family == linux.AF.INET) {
        const sa: *align(1) const linux.sockaddr.in = @ptrCast(storage);
        return .{ .ip4 = .{ .bytes = @bitCast(sa.addr), .port = std.mem.bigToNative(u16, sa.port) } };
    }
    const sa: *align(1) const linux.sockaddr.in6 = @ptrCast(storage);
    return .{ .ip6 = .{ .bytes = sa.addr, .port = std.mem.bigToNative(u16, sa.port) } };
}

// ---- 平台套接字辅助函数（与 Windows 侧对齐） -------------------------------

pub fn createSocket(domain: u32, kind: u32, protocol: u32) !Handle {
    return @intCast(try cvtFd(linux.socket(domain, kind, protocol)));
}

pub fn createTcpSocket(address: net.IpAddress) !Handle {
    const domain: u32 = switch (address) {
        .ip4 => linux.AF.INET,
        .ip6 => linux.AF.INET6,
    };
    return createSocket(domain, linux.SOCK.STREAM, linux.IPPROTO.TCP);
}

/// UDP 能力用的阻塞数据报 helper；在 `Work` 池线程里调用。
pub fn createUdpSocket(address: net.IpAddress) !Handle {
    const domain: u32 = switch (address) {
        .ip4 => linux.AF.INET,
        .ip6 => linux.AF.INET6,
    };
    return createSocket(domain, linux.SOCK.DGRAM, linux.IPPROTO.UDP);
}

pub fn recvFromBlocking(h: Handle, buf: []u8, from: []u8) !usize {
    var len: linux.socklen_t = @intCast(from.len);
    const sa: *linux.sockaddr = @ptrCast(@alignCast(from.ptr));
    return cvt(linux.recvfrom(fdOf(h), buf.ptr, buf.len, 0, sa, &len));
}

pub fn sendToBlocking(h: Handle, buf: []const u8, address: net.IpAddress) !usize {
    var storage: [128]u8 = undefined;
    const len = buildSockaddr(address, &storage);
    const sa: *const linux.sockaddr = @ptrCast(@alignCast(&storage));
    return cvt(linux.sendto(fdOf(h), buf.ptr, buf.len, 0, sa, len));
}

pub fn bindSocket(h: Handle, address: net.IpAddress) !void {
    var storage: [128]u8 = undefined;
    const len = buildSockaddr(address, &storage);
    const sa: *const linux.sockaddr = @ptrCast(@alignCast(&storage));
    _ = try cvt(linux.bind(fdOf(h), sa, len));
}

pub fn listenSocket(h: Handle, backlog: c_int) !void {
    _ = try cvt(linux.listen(fdOf(h), @intCast(backlog)));
}

pub fn localAddress(h: Handle) !net.IpAddress {
    var storage: [128]u8 = undefined;
    var len: linux.socklen_t = storage.len;
    const sa: *linux.sockaddr = @ptrCast(@alignCast(&storage));
    _ = try cvt(linux.getsockname(fdOf(h), sa, &len));
    return fromSockaddr(&storage);
}

pub fn acceptSocket(h: Handle) !struct { socket: Handle, address: net.IpAddress } {
    var storage: [128]u8 = undefined;
    var len: linux.socklen_t = storage.len;
    const sa: *linux.sockaddr = @ptrCast(@alignCast(&storage));
    const cfd = try cvtFd(linux.accept(fdOf(h), sa, &len));
    return .{ .socket = @intCast(cfd), .address = fromSockaddr(&storage) };
}

pub fn connectSocket(h: Handle, address: net.IpAddress) !void {
    var storage: [128]u8 = undefined;
    const len = buildSockaddr(address, &storage);
    const sa: *const linux.sockaddr = @ptrCast(@alignCast(&storage));
    _ = try cvt(linux.connect(fdOf(h), @ptrCast(sa), len));
}

pub fn setReuseAddress(h: Handle, on: bool) !void {
    const v: c_int = if (on) 1 else 0;
    try std.posix.setsockopt(fdOf(h), linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&v));
}

/// 语义选项 → Linux `setsockopt`。`SOL.SOCKET` / `IPPROTO.TCP` 的常量在
/// `std.os.linux` 里已经齐备，这里只做映射，不重复定义数值。
pub fn setSockOpt(h: Handle, opt: types.SockOpt, value: u32) !void {
    const v: c_int = @intCast(value);
    const bytes = std.mem.asBytes(&v);
    const fd = fdOf(h);
    switch (opt) {
        .tcp_nodelay => try std.posix.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, bytes),
        .keepalive_idle => try std.posix.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.KEEPIDLE, bytes),
        .recv_buf => try std.posix.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVBUF, bytes),
        .send_buf => try std.posix.setsockopt(fd, linux.SOL.SOCKET, linux.SO.SNDBUF, bytes),
    }
}

/// 只关发送方向。调用后对端仍能读到我们已经发出的全部数据，是优雅收尾。
pub fn shutdownSend(h: Handle) !void {
    _ = try cvt(linux.shutdown(fdOf(h), linux.SHUT.WR));
}

/// 按方向关闭。`shutdownSend` 只关写，这个能关读/写/双向。
pub fn shutdownSocket(h: Handle, how: types.ShutdownHow) !void {
    const flag: i32 = switch (how) {
        .read => linux.SHUT.RD,
        .write => linux.SHUT.WR,
        .both => linux.SHUT.RDWR,
    };
    _ = try cvt(linux.shutdown(fdOf(h), flag));
}

/// 阻塞版分散聚合发送（epoll 后端与 kqueue 的同步路径用）。
///
/// 循环直到所有缓冲都发完或遇到短写：`sendmsg` 允许部分发送，调用方拿到的
/// 是总字节数，短写意味着内核发送缓冲满了。
pub fn sendMsgBlocking(h: Handle, bufs: []const []const u8) !void {
    var iov: [IOV_MAX]std.posix.iovec_const = undefined;
    if (bufs.len > IOV_MAX) return error.TooManyBuffers;
    for (bufs, 0..) |b, i| iov[i] = .{ .base = b.ptr, .len = b.len };
    var msg: linux.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = @intCast(bufs.len),
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    _ = try cvt(linux.sendmsg(fdOf(h), &msg, linux.MSG.NOSIGNAL));
}

/// 阻塞版分散聚合接收。
pub fn recvMsgBlocking(h: Handle, bufs: []const []u8) !void {
    var iov: [IOV_MAX]std.posix.iovec = undefined;
    if (bufs.len > IOV_MAX) return error.TooManyBuffers;
    for (bufs, 0..) |b, i| iov[i] = .{ .base = b.ptr, .len = b.len };
    var msg: linux.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = @intCast(bufs.len),
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    _ = try cvt(linux.recvmsg(fdOf(h), &msg, 0));
}

pub fn closeSocket(h: Handle) void {
    _ = linux.close(fdOf(h));
}

pub fn sendBlocking(h: Handle, bytes: []const u8) !usize {
    var off: usize = 0;
    while (off < bytes.len) {
        // 走 `sendto` 而非 `write`，只为能带 `MSG_NOSIGNAL`（见 `vtSend` 的注释）。
        off += try cvt(linux.sendto(fdOf(h), bytes.ptr + off, bytes.len - off, linux.MSG.NOSIGNAL, null, 0));
    }
    return off;
}

/// 阻塞接收，仅用于测试 / benchmark 的客户端线程。
pub fn recvBlocking(h: Handle, buf: []u8) !usize {
    return cvt(linux.read(fdOf(h), buf.ptr, buf.len));
}

/// 测试探针：返回内核实际回填的 `(sq_entries, cq_entries)`。
///
/// 存在的唯一理由是验证 `Options.queue_size` 真的传到了后端、而不是被
/// 悄悄忽略——这是只能黑盒观测内部状态的正确性要求，所以开一个只读钩子。
/// 生产代码不该调用它。
/// 测试探针：返回累计 `io_uring_enter` 调用次数。
///
/// 用来证明「批量提交」真的生效。早期 `getSqe` 每次 eager flush，导致
/// 每操作 2 次 enter（实测 25000 次往返 → 50101 次），吞吐比 zio 低 22%。
/// 这是只能黑盒观测内部行为的正确性约束，故开只读钩子；生产代码不该调用。
pub fn tickCount() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

// ---- 扁平文件 I/O（在 `Work` 池线程中执行） --------------------------------

pub fn fileSize(path: []const u8) !u64 {
    const fd = try std.posix.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = linux.close(fd);
    const end = try cvt(linux.lseek(fd, 0, linux.SEEK.END));
    return @intCast(end);
}

pub fn readFileInto(path: []const u8, buf: []u8) !usize {
    const fd = try std.posix.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = linux.close(fd);
    var total: usize = 0;
    while (total < buf.len) {
        const n = try cvt(linux.read(fd, buf.ptr + total, buf.len - total));
        if (n == 0) break;
        total += n;
    }
    return total;
}

pub fn writeFileAll(path: []const u8, bytes: []const u8) !void {
    const fd = try std.posix.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    defer _ = linux.close(fd);
    var off: usize = 0;
    while (off < bytes.len) {
        off += try cvt(linux.write(fd, bytes.ptr + off, bytes.len - off));
    }
}

// ---- 目录与元数据（同样在 `Work` 池线程中执行） --------------------------

/// 路径转 NUL 结尾的定长缓冲。路径超长直接报错，不截断——截断会静默
/// 操作到别的文件，比失败更糟。
fn pathZ(path: []const u8, buf: []u8) ![*:0]const u8 {
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

/// 创建目录（含所有缺失的父目录，等价 `mkdir -p`）。
/// `mode` 受进程 umask 影响，与 `mkdir(1)` 一致。
pub fn makeDir(path: []const u8, mode: u32) !void {
    if (path.len == 0) return error.InvalidPath;
    var buf: [1024]u8 = undefined;
    var i: usize = 0;
    // 逐级创建：遇到 '/' 就尝试建前缀，已存在（EEXIST）视为正常。
    while (i <= path.len) : (i += 1) {
        if (i != path.len and path[i] != '/') continue;
        if (i == 0) continue;
        const prefix = try pathZ(path[0..i], &buf);
        const rc = linux.mkdirat(linux.AT.FDCWD, prefix, @intCast(mode));
        const rc_s: isize = signed(rc);
        // EEXIST 不算失败；其他错误上报。
        if (rc_s < 0 and rc_s != -@as(isize, @backingInt(linux.E.EXIST))) return error.MakeDirFailed;
    }
    return;
}

/// 删除空目录。非空时返回 `error.DirNotEmpty`（不递归，避免误删）。
pub fn removeDir(path: []const u8) !void {
    var buf: [1024]u8 = undefined;
    const p = try pathZ(path, &buf);
    // `AT.REMOVEDIR` 让 unlinkat 走 rmdir 语义。
    const rc = linux.unlinkat(linux.AT.FDCWD, p, linux.AT.REMOVEDIR);
    const rc_s: isize = signed(rc);
    if (rc_s == 0) return;
    if (rc_s == -@as(isize, @backingInt(linux.E.NOTEMPTY))) return error.DirNotEmpty;
    if (rc_s == -@as(isize, @backingInt(linux.E.NOENT))) return error.FileNotFound;
    return error.RemoveDirFailed;
}

/// 重命名 / 移动。跨设备时内核返回 `EXDEV`，这里如实上报而不是偷偷
/// 退化成「复制 + 删除」——那会在中途失败时留下半个文件。
pub fn rename(old_path: []const u8, new_path: []const u8) !void {
    var obuf: [1024]u8 = undefined;
    var nbuf: [1024]u8 = undefined;
    const o = try pathZ(old_path, &obuf);
    const n = try pathZ(new_path, &nbuf);
    const rc = linux.renameat(linux.AT.FDCWD, o, linux.AT.FDCWD, n);
    const rc_s: isize = signed(rc);
    if (rc_s == 0) return;
    if (rc_s == -@as(isize, @backingInt(linux.E.XDEV))) return error.CrossDevice;
    if (rc_s == -@as(isize, @backingInt(linux.E.NOENT))) return error.FileNotFound;
    return error.RenameFailed;
}

/// 创建符号链接：`target` 是链接指向的路径（可以是相对路径），`link_path`
/// 是要创建的链接本身。
pub fn symLink(target: []const u8, link_path: []const u8) !void {
    var tbuf: [1024]u8 = undefined;
    var lbuf: [1024]u8 = undefined;
    const t = try pathZ(target, &tbuf);
    const l = try pathZ(link_path, &lbuf);
    const rc = linux.symlinkat(t, linux.AT.FDCWD, l);
    const rc_s: isize = signed(rc);
    if (rc_s == 0) return;
    if (rc_s == -@as(isize, @backingInt(linux.E.EXIST))) return error.PathAlreadyExists;
    return error.SymLinkFailed;
}

/// 文件类型。与 `std.fs.File.Kind` 的常用子集对齐，够静态服务判断
/// 「是不是普通文件」用。必须与 `types.FileKind` 字段顺序一致——
/// `vtStatPath` 通过 backing int 做转换，加这一条编译期断言锁死不变量。
pub const FileKind = enum { file, directory, sym_link, other };
comptime {
    const root_kind = @typeInfo(types.FileKind).@"enum";
    const self_kind = @typeInfo(FileKind).@"enum";
    if (root_kind.field_names.len != self_kind.field_names.len) @compileError("uring.FileKind 与 types.FileKind 字段数不一致");
    for (root_kind.field_values, self_kind.field_values, 0..) |rv, sv, i| {
        if (rv != sv) @compileError("uring.FileKind 与 types.FileKind 取值错位: " ++ root_kind.field_names[i]);
    }
}

/// 路径元数据。`mtime_ms` 是 Unix 毫秒，便于直接做 `If-Modified-Since`。
pub const Stat = struct {
    kind: FileKind,
    size: u64,
    /// 最后修改时间（Unix 毫秒）。
    mtime_ms: i64,
};

/// 取路径元数据。**跟随符号链接**（与 `stat(1)` 一致）；要拿链接本身用
/// `AT.SYMLINK_NOFOLLOW` 的变体，这里不提供。
pub fn stat(path: []const u8) !Stat {
    var buf: [1024]u8 = undefined;
    const p = try pathZ(path, &buf);
    var stx: linux.Statx = std.mem.zeroes(linux.Statx);
    // 0.17 的 std 只绑了 `statx`（没有 `fstatat` 包装）。掩码要显式要
    // TYPE / SIZE / MTIME 三项；内核可能回填不了全部，故按 `stx.mask` 判断。
    const mask = linux.STATX{
        .TYPE = true,
        .MODE = true,
        .SIZE = true,
        .MTIME = true,
    };
    const rc_s = signed(linux.statx(linux.AT.FDCWD, p, 0, mask, &stx));
    if (rc_s < 0) {
        if (rc_s == -@as(isize, @backingInt(linux.E.NOENT))) return error.FileNotFound;
        return error.StatFailed;
    }
    return statFromStatx(&stx);
}

/// 把 `statx` 的回填结果转成跨平台 `Stat`。
/// 路径版与句柄版共用，避免两处各写一份类型/mtime 翻译。
fn statFromStatx(stx: *const linux.Statx) Stat {
    const kind: FileKind = switch (stx.mode & linux.S.IFMT) {
        linux.S.IFREG => .file,
        linux.S.IFDIR => .directory,
        linux.S.IFLNK => .sym_link,
        else => .other,
    };
    // 内核没回填 mtime 时给 0，调用方据此认为「未知」，而不是假装 1970。
    const mtime_ms: i64 = if (stx.mask.MTIME)
        stx.mtime.sec * 1000 + @divTrunc(@as(i64, stx.mtime.nsec), 1_000_000)
    else
        0;
    return .{
        .kind = kind,
        .size = if (stx.mask.SIZE) stx.size else 0,
        .mtime_ms = mtime_ms,
    };
}

/// 列目录项。`buf` 由调用方提供，返回**条目名切片**（不含路径前缀），
/// 超出缓冲时截断到能放下的部分——调用方据返回值判断是否还有剩余。
///
/// 不排序、不含 `.` 与 `..`：排序是策略，交给调用方。
pub fn listDir(path: []const u8, buf: []DirEntry) !usize {
    // `std.posix.openat` 接受 Zig 切片并自行处理 NUL 结尾，无需提前转。
    const fd = try std.posix.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    defer _ = linux.close(fd);

    var raw: [4096]u8 = undefined;
    var count: usize = 0;
    while (true) {
        const rc = linux.getdents64(fd, &raw, raw.len);
        const rc_s: isize = signed(rc);
        if (rc_s <= 0) break;
        const got: usize = @intCast(rc_s);
        var off: usize = 0;
        while (off < got) {
            // `linux.dirent64` 的 d_name 是柔性数组，手工按偏移取。
            const ent: *align(1) const linux.dirent64 = @ptrCast(raw[off..].ptr);
            const rec_len: usize = ent.reclen;
            if (rec_len == 0 or off + rec_len > got) break;
            const name_ptr = raw[off + @offsetOf(linux.dirent64, "name") .. off + rec_len];
            const name = std.mem.sliceTo(name_ptr, 0);
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                if (count >= buf.len) return count; // 缓冲满，截断
                if (name.len <= buf[count].name.len) {
                    @memcpy(buf[count].name[0..name.len], name);
                    buf[count].len = name.len;
                    buf[count].is_dir = ent.type == linux.DT.DIR;
                    count += 1;
                }
            }
            off += rec_len;
        }
    }
    return count;
}

/// `listDir` 的条目。名字定长，避免调用方管内存；超长名字被跳过
/// （`NAME_MAX` 通常 255，这里给 256）。
pub const DirEntry = struct {
    name: [256]u8 = undefined,
    len: usize = 0,
    is_dir: bool = false,

    pub fn slice(self: *const DirEntry) []const u8 {
        return self.name[0..self.len];
    }
};

/// 清理用的 void 版本：路径不存在等失败一律吞掉，专为 `defer` 设计。
/// 需要区分删成功/失败的业务路径请用 `deleteFileChecked`。
pub fn deleteFile(path: []const u8) void {
    deleteFileChecked(path) catch {};
}

/// 删除文件并映射 errno。VTable 的 `anyerror!void` 槽位走这里，
/// 不再把所有失败伪装成成功。
pub fn deleteFileChecked(path: []const u8) !void {
    var buf: [1024]u8 = undefined;
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const rc = linux.unlinkat(linux.AT.FDCWD, buf[0..path.len :0], 0);
    const rcs = signed(rc);
    if (rcs < 0) {
        // 幂等语义：文件已不存在视为删除成功（既有测试与 VTable 注释约定）。
        if (-rcs == @as(isize, @intCast(@backingInt(linux.E.NOENT)))) return;
        // 其余失败统一走 sys 的 errno → 具名映射（EISDIR→IsDirectory 等），
        // 不再一律折叠成 DeleteFailed。
        return sys.fromSyscall(rcs);
    }
}

/// 从 `offset` 处读入 `buf`，返回实际读到的字节数（文件尾会短读）。
/// 与 `readFileInto` 的区别是支持随机访问，是分段读大文件的基础。
pub fn readFileAt(path: []const u8, offset: u64, buf: []u8) !usize {
    const fd = try std.posix.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = linux.close(fd);
    _ = try cvt(linux.lseek(fd, @intCast(offset), linux.SEEK.SET));
    var total: usize = 0;
    while (total < buf.len) {
        const n = try cvt(linux.read(fd, buf.ptr + total, buf.len - total));
        if (n == 0) break;
        total += n;
    }
    return total;
}

/// 在文件末尾追加 `bytes`；文件不存在时创建。只做追加，不动既有内容。
pub fn appendFile(path: []const u8, bytes: []const u8) !void {
    const fd = try std.posix.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
    defer _ = linux.close(fd);
    var off: usize = 0;
    while (off < bytes.len) {
        off += try cvt(linux.write(fd, bytes.ptr + off, bytes.len - off));
    }
}

/// 把文件截断到 `size` 字节。
pub fn truncateFile(path: []const u8, size: u64) !void {
    const fd = try std.posix.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .WRONLY }, 0);
    defer _ = linux.close(fd);
    _ = try cvt(linux.ftruncate(fd, @intCast(size)));
}

// ---- 文件句柄层（阶段 A）--------------------------------------------------
// 路径式 API 每次都要 open/close；这里把句柄暴露出去，让调用方能
// 「打开一次、读写多次、显式关闭」，并支持随机访问（offset 显式传入）。
// 句柄就是 fd，按 `types.Handle`（usize）对外。

/// 打开文件并返回句柄（fd）。错误翻译与 `openSync` 一致。
pub fn openFile(path: []const u8, mode: types.FileMode) !types.Handle {
    var buf: [1024]u8 = undefined;
    const pz = try pathZ(path, &buf);
    const flags: linux.O = switch (mode) {
        .read_only => .{ .ACCMODE = .RDONLY },
        .write_only => .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        .read_write => .{ .ACCMODE = .RDWR, .CREAT = true },
        .append => .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
    };
    const fd = try openSync(pz, flags, 0o644);
    return @intCast(fd);
}

/// 从 `offset` 读入 `buf`。返回实际读到的字节数；文件尾短读不报错。
pub fn readFileHandle(file: types.Handle, offset: u64, buf: []u8) !usize {
    const fd: linux.fd_t = @intCast(file);
    var total: usize = 0;
    while (total < buf.len) {
        // pread 不移动文件偏移，多个读者可以并发用同一 fd 读不同区间。
        const n = try cvt(linux.pread(fd, buf.ptr + total, buf.len - total, @intCast(offset + total)));
        if (n == 0) break; // EOF
        total += n;
    }
    return total;
}

/// 从 `offset` 写入全部 `bytes`。返回写入的字节数。
pub fn writeFileHandle(file: types.Handle, offset: u64, bytes: []const u8) !usize {
    const fd: linux.fd_t = @intCast(file);
    var total: usize = 0;
    while (total < bytes.len) {
        const n = try cvt(linux.pwrite(fd, bytes.ptr + total, bytes.len - total, @intCast(offset + total)));
        if (n == 0) return error.WriteZero;
        total += n;
    }
    return total;
}

/// 关闭句柄。重复关闭或无效句柄不报错（幂等）。
pub fn closeFile(file: types.Handle) void {
    const fd: linux.fd_t = @intCast(file);
    if (fd >= 0) _ = linux.close(fd);
}

// ---- 句柄级元数据与同步（阶段 B）------------------------------------------

/// 取句柄元数据。用 `statx` 的 `AT_EMPTY_PATH` 形式：
/// 路径传空串、`dirfd` 就是句柄本身，避免重新解析路径（也就没有
/// 「open 之后路径被换掉」的竞态）。
pub fn statFile(file: types.Handle) !Stat {
    const fd: linux.fd_t = @intCast(file);
    var stx: linux.Statx = std.mem.zeroes(linux.Statx);
    const mask = linux.STATX{ .TYPE = true, .MODE = true, .SIZE = true, .MTIME = true };
    // 空路径指针 + AT_EMPTY_PATH：直接对 dirfd 本身取元数据。
    const empty: [*:0]const u8 = "";
    const rc_s = signed(linux.statx(fd, empty, linux.AT.EMPTY_PATH, mask, &stx));
    if (rc_s < 0) {
        if (rc_s == -@as(isize, @backingInt(linux.E.BADF))) return error.InvalidHandle;
        return error.StatFailed;
    }
    return statFromStatx(&stx);
}

/// 把句柄对应文件截断到 `size` 字节。
pub fn setFileSize(file: types.Handle, size: u64) !void {
    const fd: linux.fd_t = @intCast(file);
    _ = try cvt(linux.ftruncate(fd, @intCast(size)));
}

/// 把缓冲内容刷到磁盘。`fdatasync` 只保证数据（不保证元数据如 mtime），
/// 对「写完就想持久」的场景足够，且比 `fsync` 便宜。
pub fn syncFile(file: types.Handle) !void {
    const fd: linux.fd_t = @intCast(file);
    _ = try cvt(linux.fdatasync(fd));
}

// ---- 元数据写入、路径解析与硬链接（阶段 F）--------------------------------

/// 改权限位（`fchmod`）。`mode` 是 POSIX 权限位。
pub fn setFilePermissions(file: types.Handle, mode: u32) !void {
    const fd: linux.fd_t = @intCast(file);
    _ = try cvt(linux.fchmod(fd, mode));
}

/// 改属主（`fchown`）。
pub fn setFileOwner(file: types.Handle, uid: u32, gid: u32) !void {
    const fd: linux.fd_t = @intCast(file);
    _ = try cvt(linux.fchown(fd, uid, gid));
}

/// 改时间戳（`futimens`）。时间是 Unix 纪元纳秒。
pub fn setFileTimestamps(file: types.Handle, atime_ns: i64, mtime_ns: i64) !void {
    const fd: linux.fd_t = @intCast(file);
    const times = [_]linux.timespec{
        .{ .sec = @divFloor(atime_ns, 1_000_000_000), .nsec = @mod(atime_ns, 1_000_000_000) },
        .{ .sec = @divFloor(mtime_ns, 1_000_000_000), .nsec = @mod(mtime_ns, 1_000_000_000) },
    };
    _ = try cvt(linux.futimens(fd, &times));
}

/// 按路径改权限位（`fchmodat`）。
pub fn setPermissions(path: []const u8, mode: u32) !void {
    var zbuf: [1024]u8 = undefined;
    const p = try pathZ(path, &zbuf);
    const rc = linux.fchmodat(linux.AT.FDCWD, p, mode);
    const rc_s = signed(rc);
    if (rc_s < 0) {
        return switch (-rc_s) {
            @as(isize, @backingInt(linux.E.NOENT)) => error.FileNotFound,
            @as(isize, @backingInt(linux.E.ACCES)) => error.AccessDenied,
            else => error.SetPermissionsFailed,
        };
    }
}

/// 按路径改属主（`fchownat`）。
pub fn setOwner(path: []const u8, uid: u32, gid: u32) !void {
    var zbuf: [1024]u8 = undefined;
    const p = try pathZ(path, &zbuf);
    const rc = linux.fchownat(linux.AT.FDCWD, p, uid, gid, 0);
    const rc_s = signed(rc);
    if (rc_s < 0) {
        return switch (-rc_s) {
            @as(isize, @backingInt(linux.E.NOENT)) => error.FileNotFound,
            @as(isize, @backingInt(linux.E.ACCES)) => error.AccessDenied,
            else => error.SetOwnerFailed,
        };
    }
}

/// 按路径改时间戳（`utimensat`）。
pub fn setTimestamps(path: []const u8, atime_ns: i64, mtime_ns: i64) !void {
    var zbuf: [1024]u8 = undefined;
    const p = try pathZ(path, &zbuf);
    const times = [_]linux.timespec{
        .{ .sec = @divFloor(atime_ns, 1_000_000_000), .nsec = @mod(atime_ns, 1_000_000_000) },
        .{ .sec = @divFloor(mtime_ns, 1_000_000_000), .nsec = @mod(mtime_ns, 1_000_000_000) },
    };
    const rc = linux.utimensat(linux.AT.FDCWD, p, &times, 0);
    const rc_s = signed(rc);
    if (rc_s < 0) {
        return switch (-rc_s) {
            @as(isize, @backingInt(linux.E.NOENT)) => error.FileNotFound,
            @as(isize, @backingInt(linux.E.ACCES)) => error.AccessDenied,
            else => error.SetTimestampsFailed,
        };
    }
}

/// 检查路径可达性（`access`）。`mode`: 0=存在、4=可读、2=可写、1=可执行。
pub fn access(path: []const u8, mode: u32) !void {
    var zbuf: [1024]u8 = undefined;
    const p = try pathZ(path, &zbuf);
    const rc = linux.access(p, mode);
    const rc_s = signed(rc);
    if (rc_s < 0) {
        return switch (-rc_s) {
            @as(isize, @backingInt(linux.E.NOENT)) => error.FileNotFound,
            @as(isize, @backingInt(linux.E.ACCES)) => error.AccessDenied,
            @as(isize, @backingInt(linux.E.PERM)) => error.AccessDenied,
            else => error.AccessFailed,
        };
    }
}

/// 解析符号链接拿绝对路径（`realpath`）。
///
/// Linux 上不链 libc，没有 `realpath(3)` 可用。替代方案：先 `open` 拿 fd，
/// 再 `readlinkat("/proc/self/fd/N")` 读内核记录的已解析路径。
/// 前提是 `/proc` 已挂载（Linux 上始终如此）。
pub fn realPath(path: []const u8, buf: []u8) !usize {
    var zbuf: [1024]u8 = undefined;
    const p = try pathZ(path, &zbuf);
    // O_PATH 不检查读写权限，只拿路径信息，对 realpath 足够。
    const fd = try cvtFd(linux.open(p, .{ .PATH = true }, 0));
    defer _ = linux.close(fd);
    var proc_path_buf: [64]u8 = undefined;
    const proc_path = try std.fmt.bufPrint(&proc_path_buf, "/proc/self/fd/{d}", .{fd});
    var proc_z: [64]u8 = undefined;
    const pp = try pathZ(proc_path, &proc_z);
    const rc = linux.readlink(pp, buf.ptr, buf.len);
    const rc_s = signed(rc);
    if (rc_s < 0) return error.RealPathFailed;
    const n: usize = @intCast(rc_s);
    // 与 `readLink` 同样的理由：装满缓冲时静默截断，宁可报错。
    if (n >= buf.len) return error.NameTooLong;
    return n;
}

/// 创建硬链接（`linkat`）。两个路径指向同一 inode。
pub fn hardLink(old_path: []const u8, new_path: []const u8) !void {
    var obuf: [1024]u8 = undefined;
    var nbuf: [1024]u8 = undefined;
    const o = try pathZ(old_path, &obuf);
    const n = try pathZ(new_path, &nbuf);
    const rc = linux.linkat(linux.AT.FDCWD, o, linux.AT.FDCWD, n, 0);
    const rc_s = signed(rc);
    if (rc_s < 0) {
        return switch (-rc_s) {
            @as(isize, @backingInt(linux.E.NOENT)) => error.FileNotFound,
            @as(isize, @backingInt(linux.E.EXIST)) => error.PathAlreadyExists,
            @as(isize, @backingInt(linux.E.PERM)) => error.AccessDenied,
            else => error.HardLinkFailed,
        };
    }
}

// ---- 符号链接读取 + 目录流式句柄（阶段 C）--------------------------------

/// 读符号链接指向的目标。目标比 `buf` 长时报 `NameTooLong`，不静默截断。
pub fn readLink(link_path: []const u8, buf: []u8) !usize {
    var pz: [1024]u8 = undefined;
    const p = try pathZ(link_path, &pz);
    const rc = linux.readlink(p, buf.ptr, buf.len);
    const rc_s = signed(rc);
    if (rc_s < 0) {
        return switch (-rc_s) {
            @as(isize, @backingInt(linux.E.NOENT)) => error.FileNotFound,
            @as(isize, @backingInt(linux.E.INVAL)) => error.NotASymLink,
            else => error.ReadLinkFailed,
        };
    }
    const n: usize = @intCast(rc_s);
    // `readlink` 在缓冲正好装满时会截断且不报错（POSIX 行为），
    // 所以 n == buf.len 无法区分「刚好装满」与「被截断」。
    // 宁可报错也不返回一个可能被切掉的路径。
    if (n >= buf.len) return error.NameTooLong;
    return n;
}

/// 打开目录拿 fd。之后用 `readDirHandle` 增量读。
pub fn openDir(path: []const u8) !types.Handle {
    // `openat` 的 DIRECTORY 标志保证拿到的确实是目录（不是文件/链接）。
    const fd = std.posix.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0) catch |e| {
        return switch (e) {
            error.FileNotFound => error.FileNotFound,
            error.AccessDenied => error.AccessDenied,
            error.NotDir => error.NotDirectory, // 源自 std 的名字是 NotDir
            else => error.OpenFailed,
        };
    };
    return @intCast(fd);
}

/// 从目录句柄读下一批条目。
///
/// **关键正确性问题**：`getdents64` 一次返回一整批条目，内核的 fd 偏移
/// 直接前移到批次末尾。如果调用方缓冲装不下整批，剩下的条目就丢了
/// （下一次 `getdents64` 从批次末尾继续）。
///
/// 解法：消费完能放下的条目后，把 fd 偏移 `lseek` 回**最后一个已消费条目**
/// 记录的 `d_off`，下次从这里继续。`d_off` 是内核给的「下一个条目」偏移，
/// 所以回退到它正是「已消费条目的下一条」。
pub fn readDirHandle(dir: types.Handle, buf: []types.DirEntry) !usize {
    if (buf.len == 0) return 0;
    const fd: linux.fd_t = @intCast(dir);

    var raw: [4096]u8 = undefined;
    const rc = linux.getdents64(fd, &raw, raw.len);
    const rc_s = signed(rc);
    if (rc_s < 0) {
        return switch (-rc_s) {
            @as(isize, @backingInt(linux.E.BADF)) => error.InvalidHandle,
            @as(isize, @backingInt(linux.E.NOTDIR)) => error.NotDirectory,
            else => error.ReadDirFailed,
        };
    }
    if (rc_s == 0) return 0; // 读完

    const got: usize = @intCast(rc_s);
    var off: usize = 0;
    var count: usize = 0;
    // 已消费条目的下一个偏移；用于缓冲满时回退。
    var resume_off: ?u64 = null;

    while (off < got) {
        const ent: *align(1) const linux.dirent64 = @ptrCast(raw[off..].ptr);
        const rec_len: usize = ent.reclen;
        if (rec_len == 0 or off + rec_len > got) break;
        const name_ptr = raw[off + @offsetOf(linux.dirent64, "name") .. off + rec_len];
        const name = std.mem.sliceTo(name_ptr, 0);

        const is_dot = std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..");
        if (!is_dot) {
            if (count >= buf.len) {
                // 缓冲满了：回退到这个条目的偏移，下次从这里重读。
                // `d_off` 是「下一条目」的偏移，但我们要重读**当前**这条，
                // 所以回退到当前条目自己的偏移（off 之前那条的 d_off 已记录）。
                break;
            }
            if (name.len <= buf[count].name.len) {
                @memcpy(buf[count].name[0..name.len], name);
                buf[count].len = name.len;
                buf[count].is_dir = ent.type == linux.DT.DIR;
                count += 1;
                resume_off = ent.off;
            } else {
                // 名字超长被跳过，但仍算已消费，偏移要跟上。
                resume_off = ent.off;
            }
        }
        off += rec_len;
    }

    // 如果没消费完整批（还有剩余），把 fd 偏移拉回到「已消费的最后一
    // 条之后」。`d_off` 正是内核给的该语义。
    if (off < got) {
        if (resume_off) |r| {
            _ = linux.lseek(fd, @intCast(r), linux.SEEK.SET);
        }
    }
    return count;
}

/// 关闭目录句柄。幂等。
pub fn closeDir(dir: types.Handle) void {
    const fd: linux.fd_t = @intCast(dir);
    if (fd >= 0) _ = linux.close(fd);
}

pub fn vtCreateSocket(userdata: ?*anyopaque, address: net.IpAddress) anyerror!types.Handle {
    _ = userdata;
    return try createTcpSocket(address);
}

pub fn vtSetReuseAddress(userdata: ?*anyopaque, socket: types.Handle, on: bool) anyerror!void {
    _ = userdata;
    try setReuseAddress(socket, on);
}

pub fn vtSetSockOpt(userdata: ?*anyopaque, socket: types.Handle, opt: types.SockOpt, value: u32) anyerror!void {
    _ = userdata;
    try setSockOpt(socket, opt, value);
}

pub fn vtShutdownSend(userdata: ?*anyopaque, socket: types.Handle) anyerror!void {
    _ = userdata;
    try shutdownSend(socket);
}

pub fn vtBind(userdata: ?*anyopaque, socket: types.Handle, address: net.IpAddress) anyerror!void {
    _ = userdata;
    try bindSocket(socket, address);
}

pub fn vtListen(userdata: ?*anyopaque, socket: types.Handle, backlog: c_int) anyerror!void {
    _ = userdata;
    try listenSocket(socket, backlog);
}

pub fn vtFileSize(userdata: ?*anyopaque, path: []const u8) anyerror!u64 {
    _ = userdata;
    return fileSize(path);
}

/// 阻塞读文件适配器：忽略 `userdata`，转发到本后端的通用文件实现。
pub fn vtReadFileInto(userdata: ?*anyopaque, path: []const u8, buf: []u8) anyerror!usize {
    _ = userdata;
    return readFileInto(path, buf);
}

pub fn vtWriteFileAll(userdata: ?*anyopaque, path: []const u8, bytes: []const u8) anyerror!void {
    _ = userdata;
    return writeFileAll(path, bytes);
}

pub fn vtReadFileAt(userdata: ?*anyopaque, path: []const u8, offset: u64, buf: []u8) anyerror!usize {
    _ = userdata;
    return readFileAt(path, offset, buf);
}

pub fn vtAppendFile(userdata: ?*anyopaque, path: []const u8, bytes: []const u8) anyerror!void {
    _ = userdata;
    return appendFile(path, bytes);
}

pub fn vtTruncateFile(userdata: ?*anyopaque, path: []const u8, size: u64) anyerror!void {
    _ = userdata;
    return truncateFile(path, size);
}

pub fn vtOpenFile(userdata: ?*anyopaque, path: []const u8, mode: types.FileMode) anyerror!types.Handle {
    _ = userdata;
    return openFile(path, mode);
}

pub fn vtReadFileHandle(userdata: ?*anyopaque, file: types.Handle, offset: u64, buf: []u8) anyerror!usize {
    _ = userdata;
    return readFileHandle(file, offset, buf);
}

pub fn vtWriteFileHandle(userdata: ?*anyopaque, file: types.Handle, offset: u64, bytes: []const u8) anyerror!usize {
    _ = userdata;
    return writeFileHandle(file, offset, bytes);
}

pub fn vtCloseFile(userdata: ?*anyopaque, file: types.Handle) void {
    _ = userdata;
    closeFile(file);
}

pub fn vtStatFile(userdata: ?*anyopaque, file: types.Handle) anyerror!types.Stat {
    _ = userdata;
    const st = try statFile(file);
    return .{ .kind = @fromBackingInt(@intCast(@backingInt(st.kind))), .size = st.size, .mtime_ms = st.mtime_ms };
}

pub fn vtSetFileSize(userdata: ?*anyopaque, file: types.Handle, size: u64) anyerror!void {
    _ = userdata;
    return setFileSize(file, size);
}

pub fn vtSyncFile(userdata: ?*anyopaque, file: types.Handle) anyerror!void {
    _ = userdata;
    return syncFile(file);
}

pub fn vtSetFilePermissions(userdata: ?*anyopaque, file: types.Handle, mode: u32) anyerror!void {
    _ = userdata;
    return setFilePermissions(file, mode);
}

pub fn vtSetFileOwner(userdata: ?*anyopaque, file: types.Handle, uid: u32, gid: u32) anyerror!void {
    _ = userdata;
    return setFileOwner(file, uid, gid);
}

pub fn vtSetFileTimestamps(userdata: ?*anyopaque, file: types.Handle, atime_ns: i64, mtime_ns: i64) anyerror!void {
    _ = userdata;
    return setFileTimestamps(file, atime_ns, mtime_ns);
}

pub fn vtSetPermissions(userdata: ?*anyopaque, path: []const u8, mode: u32) anyerror!void {
    _ = userdata;
    return setPermissions(path, mode);
}

pub fn vtSetOwner(userdata: ?*anyopaque, path: []const u8, uid: u32, gid: u32) anyerror!void {
    _ = userdata;
    return setOwner(path, uid, gid);
}

pub fn vtSetTimestamps(userdata: ?*anyopaque, path: []const u8, atime_ns: i64, mtime_ns: i64) anyerror!void {
    _ = userdata;
    return setTimestamps(path, atime_ns, mtime_ns);
}

pub fn vtAccess(userdata: ?*anyopaque, path: []const u8, mode: u32) anyerror!void {
    _ = userdata;
    return access(path, mode);
}

pub fn vtRealPath(userdata: ?*anyopaque, path: []const u8, buf: []u8) anyerror!usize {
    _ = userdata;
    return realPath(path, buf);
}

pub fn vtHardLink(userdata: ?*anyopaque, old_path: []const u8, new_path: []const u8) anyerror!void {
    _ = userdata;
    return hardLink(old_path, new_path);
}

pub fn vtReadLink(userdata: ?*anyopaque, link_path: []const u8, buf: []u8) anyerror!usize {
    _ = userdata;
    return readLink(link_path, buf);
}

pub fn vtOpenDir(userdata: ?*anyopaque, path: []const u8) anyerror!types.Handle {
    _ = userdata;
    return openDir(path);
}

pub fn vtReadDirHandle(userdata: ?*anyopaque, dir: types.Handle, buf: []types.DirEntry) anyerror!usize {
    _ = userdata;
    return readDirHandle(dir, buf);
}

pub fn vtCloseDir(userdata: ?*anyopaque, dir: types.Handle) void {
    _ = userdata;
    closeDir(dir);
}

pub fn vtMakeDir(userdata: ?*anyopaque, path: []const u8, mode: u32) anyerror!void {
    _ = userdata;
    return makeDir(path, mode);
}

pub fn vtRemoveDir(userdata: ?*anyopaque, path: []const u8) anyerror!void {
    _ = userdata;
    return removeDir(path);
}

pub fn vtRename(userdata: ?*anyopaque, old_path: []const u8, new_path: []const u8) anyerror!void {
    _ = userdata;
    return rename(old_path, new_path);
}

pub fn vtSymLink(userdata: ?*anyopaque, target: []const u8, link_path: []const u8) anyerror!void {
    _ = userdata;
    return symLink(target, link_path);
}

pub fn vtStatPath(userdata: ?*anyopaque, path: []const u8) anyerror!types.Stat {
    _ = userdata;
    const st = try stat(path);
    return .{ .kind = @fromBackingInt(@intCast(@backingInt(st.kind))), .size = st.size, .mtime_ms = st.mtime_ms };
}

pub fn vtListDir(userdata: ?*anyopaque, path: []const u8, buf: []types.DirEntry) anyerror!usize {
    _ = userdata;
    return listDir(path, @ptrCast(buf));
}

pub fn vtDeleteFile(userdata: ?*anyopaque, path: []const u8) anyerror!void {
    _ = userdata;
    try deleteFileChecked(path);
}
