//! 子进程：`spawn` + 异步等待退出 + 进程组。手写平台层，不借 `std.Io`。
//!
//! ## 为什么不用 `std.process`
//!
//! Zig 0.17 把 fork/exec、PATH 解析、`CreateProcessW` 全部收进了 `std.Io` 的
//! vtable：`std.process.spawn(io, ...)` 要求一个 `std.Io`，而 `std.posix` 已
//! 不再暴露 `fork`/`execve`。为了 spawn 而引入第二套 `std.Io` 运行时，会破坏
//! mox「自有 I/O 抽象」的前提，因此这里按 mox 一贯做法**手写**：
//!
//! - POSIX：`fork` + `execve` + `waitpid`，子进程 exec 失败通过 `CLOEXEC`
//!   管道回传 errno（与 libuv 同法）。
//! - Windows：`CreateProcessW` + `WaitForSingleObject` + `TerminateProcess`，
//!   组终止用作业对象（Job Object）。
//!
//! 只把标准库当 syscall/libc 绑定用（`std.c`、`std.os.windows`），与
//! `backends/uring.zig`、`backends/kqueue.zig`、`backends/windows.zig` 一致。
//!
//! ## 阻塞在哪
//!
//! `spawn` 是**同步**的：在调用线程里跑完 fork/exec 或 `CreateProcessW`。
//! `wait` 是**异步**的：`Wait` 节点占一个 `Work` 池线程阻塞等退出，回调回到
//! 循环线程——与文件 I/O 同一权衡。

const std = @import("std");
const builtin = @import("builtin");
const Work = @import("completion.zig").Work;

const is_windows = builtin.os.tag == .windows;
const is_linux = builtin.os.tag == .linux;
// Linux 走裸 syscall（`std.os.linux`），其余 POSIX 走 libc（`std.c`）。
// 为什么不统一用 `std.c`：一旦链上 libc，`std.Thread.spawn` 会改走
// `pthread_create`，而 mox 的 Work 池给线程设了 256 KiB 栈，glibc 会以
// EINVAL 拒绝（std 把它映射成 `unreachable` → 进程直接 panic）。
// 只把 Linux 的 syscall 绑定拿来用，就能既拿到 fork/execve 又不把 libc 拖进来。
const sysc = if (is_windows) struct {} else std.c;
const lx = if (is_linux) std.os.linux else struct {};

pub const pid_t = if (is_windows) u32 else std.posix.pid_t;
pub const fd_t = if (is_windows) usize else std.posix.fd_t;

/// 父进程传给子进程的描述符来源。
pub const Stdio = union(enum) {
    /// 沿用父进程对应的流。
    inherit,
    /// 关掉（子进程看到的是无效描述符）。
    ignore,
    /// 接到一个已打开的描述符上。
    fd: fd_t,
    /// 由本模块建一根管道，父进程持有一端、子进程持有另一端。
    pipe,
};

/// `spawn` 的入参。
pub const Options = struct {
    /// 用于序列化 argv/envp 与 PATH 查找；`spawn` 返回后即可释放。
    allocator: std.mem.Allocator,
    /// `argv[0]` 可以是绝对路径、带 `/` 的相对路径，或裸命令名（走 PATH 查找）。
    argv: []const []const u8,
    /// 子进程工作目录；`null` 表示继承。
    cwd: ?[]const u8 = null,
    stdin: Stdio = .inherit,
    stdout: Stdio = .inherit,
    stderr: Stdio = .inherit,
    /// 建立新进程组（POSIX `setpgid(0,0)` / Windows `CREATE_NEW_PROCESS_GROUP`）。
    new_group: bool = false,
    /// 子进程以挂起状态启动（POSIX 先发 `SIGSTOP` / Windows `CREATE_SUSPENDED`）。
    start_suspended: bool = false,
    /// 仅 Windows：`CREATE_NO_WINDOW`。
    create_no_window: bool = false,
    /// 仅 Windows：额外建一个作业对象，使 `killGroup` 能整组终止（含 GUI 进程）。
    windows_job: bool = true,
};

/// 退出方式。与 `std.process.Child.Term` 形状一致，但由 mox 自己定义，
/// 不依赖标准库的进程模块。
pub const Exit = union(enum) {
    exited: u8,
    signaled: u8,
    stopped: u8,
    unknown: u32,

    pub fn success(self: Exit) bool {
        return switch (self) {
            .exited => |v| v == 0,
            else => false,
        };
    }

    pub fn code(self: Exit) ?u8 {
        return switch (self) {
            .exited => |v| v,
            else => null,
        };
    }
};

/// 一个已启动的子进程。
pub const Process = struct {
    /// POSIX 是 pid；Windows 是进程 ID。
    id: pid_t,
    /// 父进程侧读/写端（`pipe` 时非空）。
    stdin: ?fd_t = null,
    stdout: ?fd_t = null,
    stderr: ?fd_t = null,
    /// Windows：进程句柄与作业对象句柄；POSIX 上为 null。
    handle: ?*anyopaque = null,
    job: ?*anyopaque = null,
    /// 已回收则置 false，避免重复 `wait`/`kill`。
    alive: bool = true,

    /// 同步启动子进程。**会短暂阻塞调用线程**。
    pub fn spawn(options: Options) anyerror!Process {
        if (is_windows) return spawnWindows(options);
        return spawnPosix(options);
    }

    /// 同步等退出；会阻塞调用线程直到子进程结束。异步版本见 `Wait`。
    pub fn waitSync(self: *Process) anyerror!Exit {
        if (!self.alive) return error.ProcessAlreadyReaped;
        self.alive = false;
        if (is_windows) return waitWindows(self);
        return waitPosix(self);
    }

    /// 强制终止并回收（内部会同步等退出，因此会阻塞）。
    pub fn kill(self: *Process) void {
        if (!self.alive) return;
        if (is_windows) {
            killWindows(self);
        } else {
            killPosix(self);
        }
        self.alive = false;
    }

    /// 向整个进程组发信号并回收。
    /// POSIX 用 `kill(-pgid, sig)`；Windows 用作业对象整组终止（忽略 `sig`）。
    pub fn killGroup(self: *Process, sig: u8) anyerror!void {
        if (!self.alive) return error.ProcessAlreadyReaped;
        if (is_windows) {
            try killGroupWindows(self);
        } else {
            try killGroupPosix(self, sig);
        }
        self.alive = false;
    }

    pub fn stdoutFd(self: *const Process) ?fd_t {
        return self.stdout;
    }
    pub fn stdinFd(self: *const Process) ?fd_t {
        return self.stdin;
    }
    pub fn stderrFd(self: *const Process) ?fd_t {
        return self.stderr;
    }
};

/// 异步等待退出。内嵌 `Work` 节点、零额外分配；`Process` 由其持有者保证
/// 活到回调触发为止。
pub const Wait = struct {
    work: Work,
    process: *Process,
    exit: ?Exit = null,
    err: ?anyerror = null,

    pub fn init(process: *Process) Wait {
        return .{ .work = Work.init(run), .process = process };
    }

    fn run(w: *Work) void {
        const self: *Wait = @fieldParentPtr("work", w);
        self.exit = self.process.waitSync() catch |e| {
            self.err = e;
            return;
        };
    }

    /// 子进程的退出方式。失败时返回池线程里捕获的错误。
    pub fn getResult(self: *const Wait) anyerror!Exit {
        if (self.err) |e| return e;
        return self.exit.?;
    }
};

// ============================================================================
// POSIX
// ============================================================================

/// 统一的 POSIX syscall 包装层。
///
/// Linux 走 `std.os.linux` 裸 syscall（不引入 libc），darwin/BSD 走 `std.c`。
/// 两边的失败编码不同：裸 syscall 返回 `-errno`（`usize`），libc 返回 `-1`
/// 并把 errno 放在线程局部变量里。这一层把它们统一成「`isize`，失败为负」，
/// 上层只判断 `< 0`。
const os_call = struct {
    fn pipe2Cloexec(fds: *[2]fd_t) isize {
        if (is_linux) {
            const rc = lx.pipe2(fds, .{ .CLOEXEC = true });
            return @bitCast(rc);
        }
        if (sysc.pipe(fds) != 0) return -1;
        setCloexec(fds[0]) catch return -1;
        setCloexec(fds[1]) catch return -1;
        return 0;
    }

    fn fork() isize {
        if (is_linux) return @bitCast(lx.fork());
        return sysc.fork();
    }

    fn execve(
        path: [*:0]const u8,
        argv: [*:null]const ?[*:0]const u8,
        envp: [*:null]const ?[*:0]const u8,
    ) isize {
        if (is_linux) return @bitCast(lx.execve(path, argv, envp));
        return sysc.execve(path, argv, envp);
    }

    fn waitpid(pid: pid_t, status: ?*c_int, flags: u32) isize {
        if (is_linux) {
            var st: i32 = 0;
            const rc = lx.waitpid(pid, &st, flags);
            const signed: isize = @bitCast(rc);
            if (signed >= 0) {
                if (status) |out| out.* = st;
            }
            return signed;
        }
        return sysc.waitpid(pid, status, @intCast(flags));
    }

    fn dup2(old: fd_t, new: fd_t) isize {
        if (is_linux) return @bitCast(lx.dup2(old, new));
        return sysc.dup2(old, new);
    }

    fn close(fd: fd_t) isize {
        if (is_linux) return @bitCast(lx.close(fd));
        return sysc.close(fd);
    }

    fn read(fd: fd_t, buf: []u8) isize {
        if (is_linux) return @bitCast(lx.read(fd, buf.ptr, buf.len));
        return sysc.read(fd, buf.ptr, buf.len);
    }

    fn write(fd: fd_t, buf: []const u8) isize {
        if (is_linux) return @bitCast(lx.write(fd, buf.ptr, buf.len));
        return sysc.write(fd, buf.ptr, buf.len);
    }

    fn kill(pid: pid_t, sig: u8) isize {
        if (is_linux) return @bitCast(lx.kill(pid, @fromBackingInt(@intCast(sig))));
        return sysc.kill(pid, @fromBackingInt(@intCast(sig)));
    }

    fn setpgid(pid: pid_t, pgid: pid_t) isize {
        if (is_linux) return @bitCast(lx.setpgid(pid, pgid));
        return sysc.setpgid(pid, pgid);
    }

    fn chdir(path: [*:0]const u8) isize {
        if (is_linux) return @bitCast(lx.chdir(path));
        return sysc.chdir(path);
    }

    fn openExcl(path: [*:0]const u8) isize {
        if (is_linux) return @bitCast(lx.open(path, .{}, 0));
        return sysc.open(path, .{}, @as(sysc.mode_t, 0));
    }

    fn _exit(code: i32) noreturn {
        if (is_linux) lx.exit(code);
        sysc._exit(code);
    }

    /// 取最近一次失败的原因（裸 syscall 用返回值，libc 用线程局部 errno）。
    fn lastErrno(rc: isize) sysc.E {
        if (is_linux) {
            const e = lx.errno(rc);
            return @fromBackingInt(@intCast(@backingInt(e)));
        }
        return std.posix.errno(rc);
    }
};

/// 父进程读 exec 错误管道：EOF = exec 成功。
fn parentWaitExec(read_fd: fd_t) anyerror!void {
    var buf: [4]u8 = undefined;
    const n = os_call.read(read_fd, &buf);
    if (n < 0) return error.ReadFailed;
    if (n == 0) return; // EOF：exec 成功。
    var code: u32 = 0;
    @memcpy(std.mem.asBytes(&code)[0..@intCast(n)], buf[0..@intCast(n)]);
    return errnoToError(@as(sysc.E, @fromBackingInt(@intCast(code))));
}

const StdioFds = struct {
    child_in: ?fd_t = null,
    child_out: ?fd_t = null,
    child_err: ?fd_t = null,
    parent_in: ?fd_t = null,
    parent_out: ?fd_t = null,
    parent_err: ?fd_t = null,
    /// 子进程侧的管道端，父进程 fork 后要关掉。
    closers: [6]fd_t = .{ -1, -1, -1, -1, -1, -1 },
    n_closers: usize = 0,
};

fn setupStdio(options: Options) anyerror!StdioFds {
    var fds: StdioFds = .{};
    fds.child_in = try mapStdio(options.stdin, 0, &fds);
    fds.child_out = try mapStdio(options.stdout, 1, &fds);
    fds.child_err = try mapStdio(options.stderr, 2, &fds);
    return fds;
}

fn mapStdio(spec: Stdio, which: u2, fds: *StdioFds) anyerror!?fd_t {
    switch (spec) {
        .inherit, .ignore => return null,
        .fd => |f| {
            switch (which) {
                0 => fds.parent_in = f,
                1 => fds.parent_out = f,
                else => fds.parent_err = f,
            }
            return f;
        },
        .pipe => {
            var p: [2]fd_t = undefined;
            if (os_call.pipe2Cloexec(&p) < 0) return error.PipeFailed;
            // which==0：父写子读；其余：父读子写。
            if (which == 0) {
                fds.parent_in = p[1];
                return p[0];
            }
            if (which == 1) fds.parent_out = p[0] else fds.parent_err = p[0];
            if (fds.n_closers < fds.closers.len) {
                fds.closers[fds.n_closers] = p[1];
                fds.n_closers += 1;
            }
            return p[1];
        },
    }
}

fn closeChildEnds(fds: StdioFds) void {
    var i: usize = 0;
    while (i < fds.n_closers) : (i += 1) {
        if (fds.closers[i] >= 0) _ = os_call.close(fds.closers[i]);
    }
}

fn spawnPosix(options: Options) anyerror!Process {
    const alloc = options.allocator;

    // argv / envp 需要以 null 结尾的 C 字符串数组。
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv_z = try dupZStrings(arena, options.argv);
    const envp_z = try currentEnvironZ(arena);

    const exe = try resolveExe(alloc, options.argv[0]);
    defer alloc.free(exe);

    // exec 失败只能靠一根 CLOEXEC 管道回传：子进程 exec 成功则写端被内核关闭，
    // 父进程读到 EOF 即为成功；读到 4 字节 errno 即为失败。
    var err_pipe: [2]fd_t = undefined;
    if (os_call.pipe2Cloexec(&err_pipe) < 0) return error.PipeFailed;
    defer _ = os_call.close(err_pipe[0]);

    const stdio = try setupStdio(options);

    const fork_rc = os_call.fork();
    const pid: pid_t = @intCast(fork_rc);
    if (pid < 0) {
        closeChildEnds(stdio);
        _ = os_call.close(err_pipe[1]);
        return error.ForkFailed;
    }
    if (pid == 0) {
        // 子进程：任何失败都必须走 `_exit`，绝不能返回父进程的调用栈。
        childExec(&options, exe, argv_z, envp_z, stdio, err_pipe);
    }
    // 父进程：关掉子进程那侧的描述符。
    closeChildEnds(stdio);
    // 关键：父进程必须在阻塞读之前关掉自己的写端。否则父进程自己握着
    // `err_pipe[1]`，`read(err_pipe[0])` 永远等不到 EOF（子进程的 CLOEXEC
    // 只解决子进程那一份拷贝）。
    _ = os_call.close(err_pipe[1]);
    parentWaitExec(err_pipe[0]) catch |e| {
        _ = os_call.waitpid(pid, null, 0);
        return e;
    };

    return .{
        .id = pid,
        .stdin = stdio.parent_in,
        .stdout = stdio.parent_out,
        .stderr = stdio.parent_err,
    };
}

fn childExec(
    options: *const Options,
    exe: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    fds: StdioFds,
    err_pipe: [2]fd_t,
) noreturn {
    if (options.new_group) _ = os_call.setpgid(0, 0);
    if (options.cwd) |dir| {
        var buf: [4096]u8 = undefined;
        if (dir.len >= buf.len) childFail(err_pipe, .NAMETOOLONG);
        @memcpy(buf[0..dir.len], dir);
        buf[dir.len] = 0;
        const rc = os_call.chdir(buf[0..dir.len :0]);
        if (rc < 0) childFail(err_pipe, os_call.lastErrno(rc));
    }
    // 注意：`dup2` 成功时返回**新的描述符编号**（这里是 0/1/2），失败才返回 -1，
    // 所以判据必须是 `< 0`，不能写 `!= 0`。
    if (fds.child_in) |f| if (f != 0) {
        const rc = os_call.dup2(f, 0);
        if (rc < 0) childFail(err_pipe, os_call.lastErrno(rc));
        _ = os_call.close(f);
    };
    if (fds.child_out) |f| if (f != 1) {
        const rc = os_call.dup2(f, 1);
        if (rc < 0) childFail(err_pipe, os_call.lastErrno(rc));
        _ = os_call.close(f);
    };
    if (fds.child_err) |f| if (f != 2) {
        const rc = os_call.dup2(f, 2);
        if (rc < 0) childFail(err_pipe, os_call.lastErrno(rc));
        _ = os_call.close(f);
    };
    _ = os_call.close(err_pipe[0]);
    const exec_rc = os_call.execve(exe.ptr, argv, envp);
    // execve 只会在失败时返回。
    childFail(err_pipe, os_call.lastErrno(exec_rc));
}

/// 把 errno 写回管道并退出子进程。`noreturn`，绝不返回父进程调用栈。
fn childFail(err_pipe: [2]fd_t, errno_val: sysc.E) noreturn {
    var code: u32 = @intCast(@backingInt(errno_val));
    _ = os_call.write(err_pipe[1], std.mem.asBytes(&code)[0..4]);
    os_call._exit(127);
}

fn waitPosix(self: *Process) anyerror!Exit {
    var status: c_int = 0;
    const r = os_call.waitpid(self.id, &status, 0);
    if (r < 0) return error.WaitFailed;
    return decodeStatus(status);
}

fn decodeStatus(status: c_int) Exit {
    const s: u32 = @bitCast(status);
    if (s & 0x7f == 0) return .{ .exited = @intCast((s >> 8) & 0xff) };
    if (s & 0x7f != 0x7f) return .{ .signaled = @intCast(s & 0x7f) };
    return .{ .unknown = s };
}

fn killPosix(self: *Process) void {
    _ = os_call.kill(self.id, 15);
    _ = os_call.waitpid(self.id, null, 0);
}

fn killGroupPosix(self: *Process, sig: u8) anyerror!void {
    if (os_call.kill(-self.id, sig) < 0) return error.KillFailed;
    _ = os_call.waitpid(self.id, null, 0);
}

/// 给 `fd` 打上 `FD_CLOEXEC`。Linux 与 Darwin 的 `F_GETFD`/`F_SETFD`/`FD_CLOEXEC`
/// 取值一致，故无需分平台。
fn setCloexec(fd: fd_t) !void {
    const F_GETFD: c_int = 1;
    const F_SETFD: c_int = 2;
    const FD_CLOEXEC: c_int = 1;
    const cur = sysc.fcntl(fd, F_GETFD);
    if (cur < 0) return error.FcntlFailed;
    if (sysc.fcntl(fd, F_SETFD, cur | FD_CLOEXEC) < 0) return error.FcntlFailed;
}

/// 把 `[]const []const u8` 深拷贝成以 null 结尾的 C 字符串数组。
fn dupZStrings(arena: std.mem.Allocator, src: []const []const u8) ![*:null]const ?[*:0]const u8 {
    const out = try arena.allocSentinel(?[*:0]const u8, src.len, null);
    for (src, 0..) |s, i| {
        const z = try arena.dupeSentinel(u8, s, 0);
        out[i] = z.ptr;
    }
    return out.ptr;
}

/// 当前进程环境的快照，形式是 `KEY=VALUE` 的切片列表。
///
/// 为什么不直接用 `environ`：Zig 0.17 没有 `std.os.environ`，`std.c.environ`
/// 又要求链上 libc，而 mox 在 Linux 上刻意不链（见文件头关于线程栈的说明）。
/// 因此 Linux 读 `/proc/self/environ`（NUL 分隔），其余 POSIX 用 `std.c.environ`。
const EnvSnapshot = struct {
    block: []u8,
    entries: []const [:0]const u8,

    fn deinit(self: EnvSnapshot, alloc: std.mem.Allocator) void {
        alloc.free(self.entries);
        alloc.free(self.block);
    }
};

fn readEnv(alloc: std.mem.Allocator) !EnvSnapshot {
    if (is_linux) {
        const fd = os_call.openExcl("/proc/self/environ");
        if (fd < 0) return error.EnvUnavailable;
        defer _ = os_call.close(@intCast(fd));
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(alloc);
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = os_call.read(@intCast(fd), &chunk);
            if (n < 0) return error.EnvUnavailable;
            if (n == 0) break;
            try list.appendSlice(alloc, chunk[0..@intCast(n)]);
        }
        const block = try list.toOwnedSlice(alloc);
        errdefer alloc.free(block);
        return .{ .block = block, .entries = try splitEnv(alloc, block) };
    }
    // darwin/BSD 始终链 libSystem，直接借 environ 的内容。
    const raw: [*:null]?[*:0]u8 = sysc.environ;
    var len: usize = 0;
    while (raw[len] != null) len += 1;
    const block = try alloc.alloc(u8, 0);
    errdefer alloc.free(block);
    const entries = try alloc.alloc([:0]const u8, len);
    for (0..len) |i| entries[i] = std.mem.span(raw[i].?);
    return .{ .block = block, .entries = entries };
}

fn splitEnv(alloc: std.mem.Allocator, block: []u8) ![]const [:0]const u8 {
    var list: std.ArrayList([:0]const u8) = .empty;
    errdefer list.deinit(alloc);
    // 手工按 NUL 切：`splitScalar` 会把分隔符吃掉，拿不到「以 NUL 结尾」的切片。
    var start: usize = 0;
    for (block, 0..) |ch, i| {
        if (ch != 0) continue;
        if (i > start) try list.append(alloc, block[start..i :0]);
        start = i + 1;
    }
    return list.toOwnedSlice(alloc);
}

/// 取当前进程环境，序列化成 execve 需要的 `[*:null]?[*:0]const u8`。
fn currentEnvironZ(arena: std.mem.Allocator) ![*:null]const ?[*:0]const u8 {
    const snap = readEnv(arena) catch {
        // 拿不到环境就传空环境，至少让子进程能跑起来。
        const empty = try arena.allocSentinel(?[*:0]const u8, 0, null);
        return empty.ptr;
    };
    const out = try arena.allocSentinel(?[*:0]const u8, snap.entries.len, null);
    for (snap.entries, 0..) |e, i| out[i] = e.ptr;
    return out.ptr;
}

/// 在进程环境里找一个变量。Zig 0.17 不再提供 `std.posix.getenv`。
fn envValue(alloc: std.mem.Allocator, key: []const u8) ?[]const u8 {
    const snap = readEnv(alloc) catch return null;
    defer snap.deinit(alloc);
    for (snap.entries) |entry| {
        if (entry.len > key.len and entry[key.len] == '=' and
            std.mem.eql(u8, entry[0..key.len], key))
        {
            return entry[key.len + 1 ..];
        }
    }
    return null;
}

/// 解析可执行文件路径：含 `/` 直接用；否则按 PATH 逐个目录试。
fn resolveExe(alloc: std.mem.Allocator, name: []const u8) ![:0]u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        return alloc.dupeSentinel(u8, name, 0);
    }
    const path_env = envValue(alloc, "PATH") orelse "/usr/bin:/bin";
    var it = std.mem.tokenizeScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        const candidate = try std.fs.path.joinZ(alloc, &.{ dir, name });
        const fd = os_call.openExcl(candidate.ptr);
        if (fd >= 0) {
            _ = os_call.close(@intCast(fd));
            return candidate;
        }
        alloc.free(candidate);
    }
    return error.FileNotFound;
}

fn errnoToError(e: sysc.E) anyerror {
    return switch (e) {
        .ACCES => error.AccessDenied,
        .AGAIN => error.WouldBlock,
        .BADF => error.BadFileDescriptor,
        .FAULT => error.BadAddress,
        .INTR => error.Interrupted,
        .INVAL => error.InvalidArgument,
        .IO => error.InputOutput,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOENT => error.FileNotFound,
        .NOMEM => error.SystemResources,
        .NOSYS => error.Unsupported,
        .PERM => error.PermissionDenied,
        .PIPE => error.BrokenPipe,
        .CHILD => error.NoChildProcess,
        .NAMETOOLONG => error.NameTooLong,
        else => error.Unexpected,
    };
}

// ============================================================================
// Windows
// ============================================================================

const win = struct {
    const BOOL = std.os.windows.BOOL;
    const DWORD = std.os.windows.DWORD;
    const HANDLE = std.os.windows.HANDLE;
    const LPVOID = ?*anyopaque;
    const LPCWSTR = [*:0]const u16;
    const LPWSTR = [*:0]u16;

    const INFINITE: DWORD = 0xFFFFFFFF;
    const STARTF_USESTDHANDLES: DWORD = 0x0000_0100;
    const CREATE_SUSPENDED: DWORD = 0x0000_0004;
    const CREATE_NEW_PROCESS_GROUP: DWORD = 0x0000_0200;
    const CREATE_NO_WINDOW: DWORD = 0x0800_0000;
    const HANDLE_FLAG_INHERIT: DWORD = 0x0000_0001;
    const STILL_ACTIVE: DWORD = 259;

    const SECURITY_ATTRIBUTES = extern struct {
        nLength: DWORD = @sizeOf(SECURITY_ATTRIBUTES),
        lpSecurityDescriptor: LPVOID = null,
        bInheritHandle: BOOL = .FALSE,
    };

    const STARTUPINFOW = extern struct {
        cb: DWORD = @sizeOf(STARTUPINFOW),
        lpReserved: ?LPWSTR = null,
        lpDesktop: ?LPWSTR = null,
        lpTitle: ?LPWSTR = null,
        dwX: DWORD = 0,
        dwY: DWORD = 0,
        dwXSize: DWORD = 0,
        dwYSize: DWORD = 0,
        dwXCountChars: DWORD = 0,
        dwYCountChars: DWORD = 0,
        dwFillAttribute: DWORD = 0,
        dwFlags: DWORD = 0,
        wShowWindow: u16 = 0,
        cbReserved2: u16 = 0,
        lpReserved2: ?[*]u8 = null,
        hStdInput: ?HANDLE = null,
        hStdOutput: ?HANDLE = null,
        hStdError: ?HANDLE = null,
    };

    const PROCESS_INFORMATION = extern struct {
        hProcess: ?HANDLE = null,
        hThread: ?HANDLE = null,
        dwProcessId: DWORD = 0,
        dwThreadId: DWORD = 0,
    };

    extern "kernel32" fn CreateProcessW(
        lpApplicationName: ?LPCWSTR,
        lpCommandLine: LPWSTR,
        lpProcessAttributes: ?*SECURITY_ATTRIBUTES,
        lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
        bInheritHandles: BOOL,
        dwCreationFlags: DWORD,
        lpEnvironment: ?*anyopaque,
        lpCurrentDirectory: ?LPCWSTR,
        lpStartupInfo: *STARTUPINFOW,
        lpProcessInformation: *PROCESS_INFORMATION,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: DWORD) callconv(.winapi) DWORD;
    extern "kernel32" fn GetExitCodeProcess(h: HANDLE, code: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn TerminateProcess(h: HANDLE, code: u32) callconv(.winapi) BOOL;
    extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn CreatePipe(read: *HANDLE, write: *HANDLE, sa: ?*SECURITY_ATTRIBUTES, size: DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn SetHandleInformation(h: HANDLE, mask: DWORD, flags: DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn CreateJobObjectW(sa: ?*SECURITY_ATTRIBUTES, name: ?LPCWSTR) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn AssignProcessToJobObject(job: HANDLE, process: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn TerminateJobObject(job: HANDLE, code: u32) callconv(.winapi) BOOL;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
};

fn spawnWindows(options: Options) anyerror!Process {
    const alloc = options.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 命令行：Windows 只有一根字符串，按 MSVCRT 规则给每个参数加引号。
    const cmdline_u8 = try buildCmdline(arena, options.argv);
    const cmdline = try toWideZ(arena, cmdline_u8);
    const cwd_z: ?[:0]const u16 = if (options.cwd) |d| try toWideZ(arena, d) else null;

    var sa = win.SECURITY_ATTRIBUTES{ .bInheritHandle = win.BOOL.TRUE };
    var si = win.STARTUPINFOW{};

    var close_list: [6]?win.HANDLE = .{ null, null, null, null, null, null };
    var n_close: usize = 0;
    defer {
        var i: usize = 0;
        while (i < n_close) : (i += 1) {
            if (close_list[i]) |h| _ = win.CloseHandle(h);
        }
    }

    const in_pair = try makeStdioWindows(options.stdin, true, &sa, &si, &close_list, &n_close);
    const out_pair = try makeStdioWindows(options.stdout, false, &sa, &si, &close_list, &n_close);
    const err_pair = try makeStdioWindows(options.stderr, false, &sa, &si, &close_list, &n_close);

    // 只有真的提供了句柄时才设 STARTF_USESTDHANDLES；否则 CreateProcessW 会因为
    // 三个 std 句柄为空而失败。
    if (si.hStdInput != null or si.hStdOutput != null or si.hStdError != null) {
        si.dwFlags |= win.STARTF_USESTDHANDLES;
    }

    var flags: win.DWORD = 0;
    if (options.new_group) flags |= win.CREATE_NEW_PROCESS_GROUP;
    if (options.start_suspended) flags |= win.CREATE_SUSPENDED;
    if (options.create_no_window) flags |= win.CREATE_NO_WINDOW;

    var pi = win.PROCESS_INFORMATION{};
    if (!win.CreateProcessW(
        // lpApplicationName 必须是完整路径；传 null 让系统按命令行的首 token
        // 走 PATH 查找（与 POSIX 的 execvpe 语义对齐）。
        null,
        @constCast(cmdline.ptr),
        &sa,
        &sa,
        win.BOOL.TRUE,
        flags,
        null,
        if (cwd_z) |c| c.ptr else null,
        &si,
        &pi,
    ).toBool()) {
        return error.SpawnFailed;
    }
    // 父进程不再需要线程句柄。
    if (pi.hThread) |th| _ = win.CloseHandle(th);

    var job: ?win.HANDLE = null;
    if (options.windows_job) {
        job = win.CreateJobObjectW(null, null);
        if (job) |j| {
            if (!win.AssignProcessToJobObject(j, pi.hProcess.?).toBool()) {
                _ = win.CloseHandle(j);
                job = null;
            }
        }
    }

    // 子进程侧的管道端由我们关掉（子进程已继承副本）。
    closeChildPipeEnds(&close_list, &n_close);

    return .{
        .id = @intCast(pi.dwProcessId),
        .stdin = in_pair,
        .stdout = out_pair,
        .stderr = err_pair,
        .handle = if (pi.hProcess) |h| @ptrCast(h) else null,
        .job = if (job) |j| @ptrCast(j) else null,
    };
}

/// 配置一路 stdio，返回父进程侧应持有的句柄（`inherit`/`ignore` 返回 null）。
fn makeStdioWindows(
    spec: Stdio,
    is_input: bool,
    sa: *win.SECURITY_ATTRIBUTES,
    si: *win.STARTUPINFOW,
    close_list: *[6]?win.HANDLE,
    n_close: *usize,
) anyerror!?fd_t {
    switch (spec) {
        .inherit => return null,
        .ignore => return null,
        .fd => |f| {
            const h: win.HANDLE = @ptrFromInt(f);
            if (is_input) si.hStdInput = h else si.hStdOutput = h;
            return f;
        },
        .pipe => {
            var r: win.HANDLE = undefined;
            var w: win.HANDLE = undefined;
            if (!win.CreatePipe(&r, &w, sa, 0).toBool()) return error.PipeFailed;
            if (is_input) {
                // 父写子读。
                _ = win.SetHandleInformation(w, win.HANDLE_FLAG_INHERIT, 0);
                si.hStdInput = r;
                if (n_close.* < close_list.len) {
                    close_list[n_close.*] = r;
                    n_close.* += 1;
                }
                return @intFromPtr(w);
            }
            // 父读子写。
            _ = win.SetHandleInformation(r, win.HANDLE_FLAG_INHERIT, 0);
            si.hStdOutput = w;
            if (n_close.* < close_list.len) {
                close_list[n_close.*] = w;
                n_close.* += 1;
            }
            return @intFromPtr(r);
        },
    }
}

fn closeChildPipeEnds(close_list: *[6]?win.HANDLE, n_close: *usize) void {
    var i: usize = 0;
    while (i < n_close.*) : (i += 1) {
        if (close_list[i]) |h| {
            _ = win.CloseHandle(h);
            close_list[i] = null;
        }
    }
    n_close.* = 0;
}

fn waitWindows(self: *Process) anyerror!Exit {
    const h: win.HANDLE = @ptrCast(self.handle orelse return error.NotSpawned);
    _ = win.WaitForSingleObject(h, win.INFINITE);
    var code: win.DWORD = 0;
    if (!win.GetExitCodeProcess(h, &code).toBool()) return error.WaitFailed;
    _ = win.CloseHandle(h);
    self.handle = null;
    return .{ .exited = @truncate(code) };
}

fn killWindows(self: *Process) void {
    const h: win.HANDLE = @ptrCast(self.handle orelse return);
    _ = win.TerminateProcess(h, 1);
    _ = win.WaitForSingleObject(h, win.INFINITE);
    _ = win.CloseHandle(h);
    self.handle = null;
}

fn killGroupWindows(self: *Process) anyerror!void {
    if (self.job) |j| {
        const jh: win.HANDLE = @ptrCast(j);
        if (!win.TerminateJobObject(jh, 1).toBool()) return error.KillFailed;
        _ = win.CloseHandle(jh);
        self.job = null;
        if (self.handle) |ph| {
            const h: win.HANDLE = @ptrCast(ph);
            _ = win.WaitForSingleObject(h, win.INFINITE);
            _ = win.CloseHandle(h);
            self.handle = null;
        }
        return;
    }
    // 没有作业对象时退化为单进程终止。
    killWindows(self);
}

/// 按 MSVCRT 规则拼命令行：含空白/引号的参数用双引号包起来并转义内部引号。
fn buildCmdline(arena: std.mem.Allocator, argv: []const []const u8) ![:0]u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (argv, 0..) |arg, i| {
        if (i != 0) try buf.append(arena, ' ');
        try appendQuoted(arena, &buf, arg);
    }
    return buf.toOwnedSliceSentinel(arena, 0);
}

fn appendQuoted(arena: std.mem.Allocator, buf: *std.ArrayList(u8), arg: []const u8) !void {
    const needs = arg.len == 0 or std.mem.indexOfAny(u8, arg, " \t\n\"") != null;
    if (!needs) {
        try buf.appendSlice(arena, arg);
        return;
    }
    try buf.append(arena, '"');
    var backslashes: usize = 0;
    for (arg) |ch| {
        if (ch == '\\') {
            backslashes += 1;
        } else if (ch == '"') {
            try buf.appendNTimes(arena, '\\', backslashes * 2 + 1);
            try buf.append(arena, '"');
            backslashes = 0;
        } else {
            try buf.appendNTimes(arena, '\\', backslashes);
            try buf.append(arena, ch);
            backslashes = 0;
        }
    }
    try buf.appendNTimes(arena, '\\', backslashes * 2);
    try buf.append(arena, '"');
}

/// UTF-8 → UTF-16（以 null 结尾）。
fn toWideZ(arena: std.mem.Allocator, s: []const u8) ![:0]const u16 {
    const len = std.unicode.utf8CountCodepoints(s) catch return error.InvalidUtf8;
    const out = try arena.allocSentinel(u16, len, 0);
    _ = std.unicode.utf8ToUtf16Le(out, s) catch return error.InvalidUtf8;
    return out;
}

test {
    _ = Exit;
}
