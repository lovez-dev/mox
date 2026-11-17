//! Authoritative C and POSIX ABI types and declarations.

const builtin = @import("builtin");

const darwin = builtin.os.tag == .macos;

pub const Timespec = extern struct { sec: isize, nsec: isize };

pub const Iovec = extern struct { base: [*]u8, length: usize };

/// BSD msghdr layout; Linux uses the raw syscall ABI in linux.zig.
pub const Message = extern struct { name: ?*anyopaque, name_length: u32, vectors: *Iovec, vector_count: i32, control: ?*anyopaque = null, control_length: u32 = 0, flags: i32 = 0 };

// stat layouts are deliberately separate across Darwin and FreeBSD.
pub const DarwinStat = extern struct {
    device: i32,
    mode: u16,
    links: u16,
    inode: u64,
    uid: u32,
    gid: u32,
    rdevice: i32,
    accessed: Timespec,
    modified: Timespec,
    changed: Timespec,
    created: Timespec,
    size: i64,
    blocks: i64,
    block_size: i32,
    flags: u32,
    generation: u32,
    spare: i32,
    spare2: [2]i64,
};

pub const BsdStat = extern struct {
    device: u64,
    inode: u64,
    links: u64,
    mode: u16,
    bsd_flags: i16,
    uid: u32,
    gid: u32,
    padding: i32,
    rdevice: u64,
    accessed: Timespec,
    modified: Timespec,
    changed: Timespec,
    created: Timespec,
    size: i64,
    blocks: i64,
    block_size: i32,
    flags: u32,
    generation: u64,
    revision: u64,
    spare: [9]u64,
};

pub const Stat = if (darwin) DarwinStat else BsdStat;

pub const AddrInfo = if (builtin.os.tag != .linux) extern struct {
    flags: i32,
    family: i32,
    socket_type: i32,
    protocol: i32,
    length: u32,
    name: ?[*:0]u8,
    address: ?[*]const u8,
    next: ?*AddrInfo,
} else extern struct {
    flags: c_int,
    family: c_int,
    socket_type: c_int,
    protocol: c_int,
    length: u32,
    address: ?[*]const u8,
    name: ?[*:0]u8,
    next: ?*AddrInfo,
};

// Virtual memory and clocks.
pub extern "c" fn getpagesize() c_int;
pub extern "c" fn mmap(?*anyopaque, usize, c_int, c_int, c_int, i64) ?*anyopaque;
pub extern "c" fn munmap(*anyopaque, usize) c_int;
pub extern "c" fn write(c_int, [*]const u8, usize) isize;
pub extern "c" fn _exit(c_int) noreturn;
pub extern "c" fn clock_gettime(c_int, *Timespec) c_int;
pub extern "c" fn pthread_self() usize;

// Descriptors and BSD socket operations.
pub extern "c" fn __error() *c_int;
pub extern "c" fn close(c_int) c_int;
pub extern "c" fn fcntl(c_int, c_int, ...) c_int;
pub extern "c" fn socket(c_int, c_int, c_int) c_int;
pub extern "c" fn bind(c_int, *const anyopaque, u32) c_int;
pub extern "c" fn listen(c_int, c_int) c_int;
pub extern "c" fn getsockname(c_int, *anyopaque, *u32) c_int;
pub extern "c" fn getsockopt(c_int, c_int, c_int, *anyopaque, *u32) c_int;
pub extern "c" fn setsockopt(c_int, c_int, c_int, *const anyopaque, u32) c_int;
pub extern "c" fn accept(c_int, *anyopaque, *u32) c_int;
pub extern "c" fn connect(c_int, *const anyopaque, u32) c_int;
pub extern "c" fn recv(c_int, [*]u8, usize, c_int) isize;
pub extern "c" fn send(c_int, [*]const u8, usize, c_int) isize;
pub extern "c" fn recvmsg(c_int, *Message, c_int) isize;
pub extern "c" fn sendto(c_int, [*]const u8, usize, c_int, *const anyopaque, u32) isize;
pub extern "c" fn open([*:0]const u8, c_int, ...) c_int;
pub extern "c" fn pread(c_int, [*]u8, usize, i64) isize;
pub extern "c" fn pwrite(c_int, [*]const u8, usize, i64) isize;
pub extern "c" fn fsync(c_int) c_int;
pub extern "c" fn fstat(c_int, *Stat) c_int;
pub extern "c" fn @"fstat$INODE64"(c_int, *Stat) c_int;

// Pipes and signal masking.
pub extern "c" fn read(c_int, [*]u8, usize) isize;
pub extern "c" fn pipe(*[2]c_int) c_int;
pub extern "c" fn pipe2(*[2]c_int, c_int) c_int;
pub extern "c" fn __errno_location() *c_int;
pub extern "c" fn sigemptyset(*anyopaque) c_int;
pub extern "c" fn sigaddset(*anyopaque, c_int) c_int;
pub extern "c" fn sigismember(*const anyopaque, c_int) c_int;
pub extern "c" fn sigpending(*anyopaque) c_int;
pub extern "c" fn pthread_sigmask(c_int, *const anyopaque, ?*anyopaque) c_int;
pub extern "c" fn sigwait(*const anyopaque, *c_int) c_int;
pub extern "c" var environ: [*:null]?[*:0]u8;
pub extern "c" fn _NSGetEnviron() *[*:null]?[*:0]u8;

// Child process creation and waits.
pub extern "c" fn posix_spawnp(*c_int, [*:0]const u8, ?*const anyopaque, ?*const anyopaque, [*:null]const ?[*:0]const u8, [*:null]const ?[*:0]u8) c_int;
pub extern "c" fn posix_spawn_file_actions_init(*anyopaque) c_int;
pub extern "c" fn posix_spawn_file_actions_destroy(*anyopaque) c_int;
pub extern "c" fn posix_spawn_file_actions_adddup2(*anyopaque, c_int, c_int) c_int;
pub extern "c" fn posix_spawn_file_actions_addchdir_np(*anyopaque, [*:0]const u8) c_int;
pub extern "c" fn waitpid(c_int, *c_int, c_int) c_int;
pub extern "c" fn kill(c_int, c_int) c_int;
pub extern "c" fn nanosleep(*const Timespec, ?*anyopaque) c_int;

// Filesystem commands and directory traversal.
pub extern "c" fn mkdir([*:0]const u8, c_uint) c_int;
pub extern "c" fn unlink([*:0]const u8) c_int;
pub extern "c" fn rmdir([*:0]const u8) c_int;
pub extern "c" fn rename([*:0]const u8, [*:0]const u8) c_int;
pub extern "c" fn ftruncate(c_int, i64) c_int;
pub extern "c" fn fchmod(c_int, c_uint) c_int;
pub extern "c" fn opendir([*:0]const u8) ?*anyopaque;
pub extern "c" fn readdir(*anyopaque) ?[*]const u8;
pub extern "c" fn @"readdir$INODE64"(*anyopaque) ?[*]const u8;
pub extern "c" fn closedir(*anyopaque) c_int;
pub extern "c" fn shutdown(c_int, c_int) c_int;
pub extern "c" fn getaddrinfo([*:0]const u8, ?[*:0]const u8, *const AddrInfo, *?*AddrInfo) c_int;
pub extern "c" fn freeaddrinfo(*AddrInfo) void;

// Threads, synchronization, and CPU discovery.
pub extern "c" fn pthread_create(*usize, ?*const anyopaque, *const fn (?*anyopaque) callconv(.c) ?*anyopaque, ?*anyopaque) c_int;
pub extern "c" fn pthread_join(usize, ?*?*anyopaque) c_int;
pub extern "c" fn pthread_attr_init(*anyopaque) c_int;
pub extern "c" fn pthread_attr_setstacksize(*anyopaque, usize) c_int;
pub extern "c" fn pthread_attr_destroy(*anyopaque) c_int;
pub extern "c" fn sched_yield() c_int;
pub extern "c" fn pthread_mutex_init(*anyopaque, ?*const anyopaque) c_int;
pub extern "c" fn pthread_mutex_destroy(*anyopaque) c_int;
pub extern "c" fn pthread_mutex_lock(*anyopaque) c_int;
pub extern "c" fn pthread_mutex_unlock(*anyopaque) c_int;
pub extern "c" fn pthread_cond_init(*anyopaque, ?*const anyopaque) c_int;
pub extern "c" fn pthread_cond_destroy(*anyopaque) c_int;
pub extern "c" fn pthread_cond_wait(*anyopaque, *anyopaque) c_int;
pub extern "c" fn pthread_cond_signal(*anyopaque) c_int;
pub extern "c" fn pthread_cond_broadcast(*anyopaque) c_int;
pub extern "c" fn sched_getaffinity(c_int, usize, *anyopaque) c_int;
pub extern "c" fn sysctlbyname([*:0]const u8, *anyopaque, *usize, ?*anyopaque, usize) c_int;

// These file/socket layouts describe the supported 64-bit BSD system ABIs.
comptime {
    if (@sizeOf(usize) == 8 and (builtin.os.tag == .macos or builtin.os.tag == .freebsd)) {
        if (@sizeOf(Timespec) != 16 or @sizeOf(Iovec) != 16 or
            @sizeOf(Message) != 48 or @offsetOf(Message, "control") != 32 or
            @sizeOf(DarwinStat) != 144 or @offsetOf(DarwinStat, "size") != 96 or
            @sizeOf(BsdStat) != 224 or @offsetOf(BsdStat, "size") != 112 or
            @sizeOf(AddrInfo) != 48)
        {
            @compileError("BSD ABI layout mismatch");
        }
    }
}

// Darwin and FreeBSD retain distinct kevent record sizes.
pub const Kevent = extern struct {
    ident: usize = 0,
    filter: i16 = 0,
    flags: u16 = 0,
    fflags: u32 = 0,
    data: i64 = 0,
    cookie: usize = 0,
    // FreeBSD extends kevent; Darwin's legacy ABI ends after udata.
    extension: [if (darwin) 0 else 4]u64 = @splat(0),
};
pub extern "c" fn kqueue() c_int;
pub extern "c" fn kevent(c_int, ?[*]const Kevent, c_int, ?[*]Kevent, c_int, ?*const Timespec) c_int;

comptime {
    if (@sizeOf(usize) == 8 and (builtin.os.tag == .macos or builtin.os.tag == .freebsd)) {
        if (@sizeOf(Kevent) != (if (darwin) @as(usize, 32) else 64) or
            @offsetOf(Kevent, "data") != 16 or @offsetOf(Kevent, "cookie") != 24)
        {
            @compileError("kqueue ABI layout mismatch");
        }
    }
}
