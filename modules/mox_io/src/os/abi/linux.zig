//! Minimal Linux syscall bindings for x86_64 and aarch64.

const builtin = @import("builtin");

pub fn number(x86: usize, arm: usize) usize {
    return switch (builtin.cpu.arch) {
        .x86_64 => x86,
        .aarch64 => arm,
        else => @compileError("unsupported Linux architecture"),
    };
}

pub fn syscall(n: usize, a: usize, b: usize, c: usize, d: usize, e: usize, f: usize) isize {
    // Raw syscalls return negative errno values; libc's thread-local errno is unused.
    if (builtin.cpu.arch == .x86_64) {
        return asm volatile ("syscall"
            : [ret] "={rax}" (-> isize),
            : [n] "{rax}" (n),
              [a] "{rdi}" (a),
              [b] "{rsi}" (b),
              [c] "{rdx}" (c),
              [d] "{r10}" (d),
              [e] "{r8}" (e),
              [f] "{r9}" (f),
            : .{ .rcx = true, .r11 = true, .memory = true });
    } else if (builtin.cpu.arch == .aarch64) {
        return asm volatile ("svc #0"
            : [ret] "={x0}" (-> isize),
            : [n] "{x8}" (n),
              [a] "{x0}" (a),
              [b] "{x1}" (b),
              [c] "{x2}" (c),
              [d] "{x3}" (d),
              [e] "{x4}" (e),
              [f] "{x5}" (f),
            : .{ .memory = true });
    } else @compileError("unsupported Linux architecture");
}

pub fn fd(value: i32) usize {
    return @bitCast(@as(isize, value));
}

pub fn errno(result: isize) i32 {
    return if (result < 0 and result >= -4095) @intCast(-result) else 0;
}

pub fn close(value: i32) isize {
    return syscall(number(3, 57), fd(value), 0, 0, 0, 0, 0);
}

pub fn fcntl(value: i32, command: usize, argument: usize) isize {
    return syscall(number(72, 25), fd(value), command, argument, 0, 0, 0);
}

pub fn read(value: i32, buffer: []u8) isize {
    return syscall(number(0, 63), fd(value), @intFromPtr(buffer.ptr), buffer.len, 0, 0, 0);
}

pub fn write(value: i32, bytes: []const u8) isize {
    return syscall(number(1, 64), fd(value), @intFromPtr(bytes.ptr), bytes.len, 0, 0, 0);
}

pub fn pread(value: i32, buffer: []u8, offset: u64) isize {
    return syscall(number(17, 67), fd(value), @intFromPtr(buffer.ptr), buffer.len, @intCast(offset), 0, 0);
}

pub fn pwrite(value: i32, bytes: []const u8, offset: u64) isize {
    return syscall(number(18, 68), fd(value), @intFromPtr(bytes.ptr), bytes.len, @intCast(offset), 0, 0);
}

pub fn fsync(value: i32) isize {
    return syscall(number(74, 82), fd(value), 0, 0, 0, 0, 0);
}
// Only x86_64 packs epoll_event; aarch64 keeps natural u64 alignment.
pub const EpollEvent = if (builtin.cpu.arch == .x86_64)
    extern struct { events: u32 align(1), data: u64 align(1) }
else
    extern struct { events: u32, data: u64 };

comptime {
    if (builtin.cpu.arch == .x86_64) {
        if (@sizeOf(EpollEvent) != 12 or @offsetOf(EpollEvent, "data") != 4)
            @compileError("x86_64 epoll_event ABI layout mismatch");
    } else if (builtin.cpu.arch == .aarch64) {
        if (@sizeOf(EpollEvent) != 16 or @offsetOf(EpollEvent, "data") != 8)
            @compileError("aarch64 epoll_event ABI layout mismatch");
    }
}

pub fn epollCreate() isize {
    return syscall(number(291, 20), 0x80000, 0, 0, 0, 0, 0);
}

pub fn epollControl(epoll: i32, command: u32, value: i32, event: ?*const EpollEvent) isize {
    return syscall(number(233, 21), fd(epoll), command, fd(value), if (event) |pointer| @intFromPtr(pointer) else 0, 0, 0);
}

pub fn epollWait(epoll: i32, events: []EpollEvent, milliseconds: i32) isize {
    return syscall(number(281, 22), fd(epoll), @intFromPtr(events.ptr), events.len, @bitCast(@as(isize, milliseconds)), 0, 0);
}

pub fn eventfd() isize {
    return syscall(number(290, 19), 0, 0x80000 | 0x800, 0, 0, 0, 0);
}

// Thin wrappers keep syscall numbers and native argument packing in this module.
pub const sock_stream: u32 = 1;
pub const sock_dgram: u32 = 2;
pub const sock_nonblock: u32 = 0x800;
pub const sock_cloexec: u32 = 0x80000;
pub const msg_nosignal: u32 = 0x4000;
pub const msg_dontwait: u32 = 0x40;
pub const msg_trunc: u32 = 0x20;
pub const sol_socket: u32 = 1;
pub const so_error: u32 = 4;
pub const ipproto_tcp: u32 = 6;
pub const ipproto_udp: u32 = 17;
pub const tcp_nodelay: u32 = 1;
pub const at_fdcwd: i32 = -100;
pub const at_empty_path: u32 = 0x1000;
pub const statx_basic_stats: u32 = 0x7ff;
pub const o_cloexec: usize = 0x80000;
pub const o_creat: usize = 0x40;
pub const o_excl: usize = 0x80;
pub const o_trunc: usize = 0x200;

pub inline fn socket(domain: u32, kind: u32, protocol: u32) isize {
    return syscall(number(41, 198), domain, kind, protocol, 0, 0, 0);
}

pub inline fn bind(descriptor: i32, address: *const anyopaque, length: u32) isize {
    return syscall(number(49, 200), fd(descriptor), @intFromPtr(address), length, 0, 0, 0);
}

pub inline fn listen(descriptor: i32, backlog: u32) isize {
    return syscall(number(50, 201), fd(descriptor), backlog, 0, 0, 0, 0);
}

pub inline fn getsockname(descriptor: i32, address: *anyopaque, length: *u32) isize {
    return syscall(number(51, 204), fd(descriptor), @intFromPtr(address), @intFromPtr(length), 0, 0, 0);
}

pub inline fn setsockopt(descriptor: i32, level: u32, option: u32, value: *const anyopaque, length: u32) isize {
    return syscall(number(54, 208), fd(descriptor), level, option, @intFromPtr(value), length, 0);
}

pub inline fn getsockopt(descriptor: i32, level: u32, option: u32, value: *anyopaque, length: *u32) isize {
    return syscall(number(55, 209), fd(descriptor), level, option, @intFromPtr(value), @intFromPtr(length), 0);
}

pub inline fn accept4(descriptor: i32, address: *anyopaque, length: *u32, flags: u32) isize {
    return syscall(number(288, 242), fd(descriptor), @intFromPtr(address), @intFromPtr(length), flags, 0, 0);
}

pub inline fn connect(descriptor: i32, address: *const anyopaque, length: u32) isize {
    return syscall(number(42, 203), fd(descriptor), @intFromPtr(address), length, 0, 0, 0);
}

pub inline fn recv_from(descriptor: i32, buffer: []u8, flags: u32, address: ?*anyopaque, length: ?*u32) isize {
    return syscall(number(45, 207), fd(descriptor), @intFromPtr(buffer.ptr), buffer.len, flags, if (address) |value| @intFromPtr(value) else 0, if (length) |value| @intFromPtr(value) else 0);
}

pub inline fn send_to(descriptor: i32, bytes: []const u8, flags: u32, address: ?*const anyopaque, length: u32) isize {
    return syscall(number(44, 206), fd(descriptor), @intFromPtr(bytes.ptr), bytes.len, flags, if (address) |value| @intFromPtr(value) else 0, length);
}

pub inline fn openat(directory: i32, path: [*:0]const u8, flags: usize, mode: u16) isize {
    return syscall(number(257, 56), fd(directory), @intFromPtr(path), flags, mode, 0, 0);
}

pub inline fn statx(descriptor: i32, path: [*:0]const u8, flags: u32, mask: u32, metadata: *Statx) isize {
    return syscall(number(332, 291), fd(descriptor), @intFromPtr(path), flags, mask, @intFromPtr(metadata), 0);
}

pub inline fn mmap(address: ?*anyopaque, length: usize, protection: u32, flags: u32, descriptor: i32, offset: usize) isize {
    return syscall(number(9, 222), if (address) |value| @intFromPtr(value) else 0, length, protection, flags, fd(descriptor), offset);
}

pub inline fn munmap(bytes: []u8) isize {
    return syscall(number(11, 215), @intFromPtr(bytes.ptr), bytes.len, 0, 0, 0, 0);
}

const uring = @import("uring.zig");

pub inline fn uring_setup(entries: u32, parameters: *uring.Parameters) isize {
    return syscall(425, entries, @intFromPtr(parameters), 0, 0, 0, 0);
}

pub inline fn uring_register(descriptor: i32, opcode: u32, argument: *anyopaque, count: u32) isize {
    return syscall(427, fd(descriptor), opcode, @intFromPtr(argument), count, 0, 0);
}

pub inline fn uring_enter(descriptor: i32, submit: u32, minimum: u32, flags: u32, arguments: ?*const uring.WaitArguments) isize {
    return syscall(426, fd(descriptor), submit, minimum, flags, if (arguments) |value| @intFromPtr(value) else 0, if (arguments != null) @sizeOf(uring.WaitArguments) else 0);
}

// File metadata and message headers passed directly to the kernel.
pub const Timestamp = extern struct { seconds: i64, nanoseconds: u32, reserved: i32 };

pub const Statx = extern struct {
    mask: u32,
    block_size: u32,
    attributes: u64,
    links: u32,
    uid: u32,
    gid: u32,
    mode: u16,
    reserved: u16,
    inode: u64,
    size: u64,
    blocks: u64,
    attributes_mask: u64,
    accessed: Timestamp,
    created: Timestamp,
    changed: Timestamp,
    modified: Timestamp,
    rdev_major: u32,
    rdev_minor: u32,
    dev_major: u32,
    dev_minor: u32,
    mount_id: u64,
    memory_alignment: u32,
    offset_alignment: u32,
    spare: [12]u64,
};

pub const Iovec = extern struct { base: [*]u8, length: usize };

pub const Message = extern struct { name: ?*anyopaque, name_length: u32, vectors: *Iovec, vector_count: usize, control: ?*anyopaque = null, control_length: usize = 0, flags: i32 = 0 };

comptime {
    if (@sizeOf(usize) == 8) {
        if (@sizeOf(Timestamp) != 16 or @sizeOf(Statx) != 256 or
            @offsetOf(Statx, "size") != 40 or @offsetOf(Statx, "modified") != 112 or
            @sizeOf(Iovec) != 16 or @sizeOf(Message) != 56 or
            @offsetOf(Message, "control") != 32)
        {
            @compileError("Linux file/socket ABI layout mismatch");
        }
    }
}
