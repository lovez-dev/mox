//! Public I/O, runtime, filesystem and allocator interfaces.

pub const mem = struct {
    pub const Allocator = @import("mem/allocator.zig").Allocator;
    pub const Allocation = @import("mem/allocator.zig").Allocation;
    pub const TrackingAllocator = @import("mem/tracking.zig");
    pub const SharedTrackingAllocator = @import("mem/shared_tracking.zig");
    pub const PageAllocator = @import("mem/page_allocator.zig");
    pub const Arena = @import("mem/arena.zig");
    pub const bytes = @import("mem/bytes.zig");
};

pub const runtime = struct {
    pub const panic = @import("bootstrap/panic.zig");
    pub const Boot = @import("bootstrap/entry.zig").Boot;
    pub const memory = @import("bootstrap/builtins.zig");
};

pub const os = @import("os/root.zig");
pub const types = @import("types.zig");
pub const Error = @import("error.zig").Error;
pub const Stats = @import("stats.zig").Stats;

pub const Loop = @import("loop.zig").Loop;
pub const backend_common = @import("backend/common.zig");
pub const Layout = @import("mem/layout.zig").Layout;
pub const Queue = @import("core/queue.zig").Queue;

pub const backends = struct {
    pub const Iocp = @import("backend/iocp.zig");
    pub const Epoll = @import("backend/epoll.zig").Driver;
    pub const Kqueue = @import("backend/kqueue.zig").Driver;
    pub const Uring = @import("backend/uring.zig");
};

/// Portable baseline; Linux callers can select Uring explicitly after probing.
pub const DefaultBackend = switch (@import("builtin").os.tag) {
    .windows => backends.Iocp,
    .linux => backends.Epoll,
    .macos, .freebsd => backends.Kqueue,
    else => @compileError("unsupported operating system"),
};

pub const DefaultLoop = Loop(DefaultBackend);
pub const Runtime = @import("runtime/pool.zig").Runtime;
pub const DefaultRuntime = Runtime(DefaultBackend);

pub const Clock = @import("time/clock.zig");

pub const sync = struct {
    pub const Thread = @import("sync/thread.zig");
    pub const Mutex = @import("sync/mutex.zig");
    pub const Condition = @import("sync/condition.zig");
};

pub const fs = @import("fs/root.zig");

pub const Stream = @import("io/stream.zig").Stream;
pub const Group = @import("io/group.zig").Group;
pub const GroupEntry = @import("io/group.zig").Entry;
pub const GroupMode = @import("io/group.zig").Mode;
pub const Pipe = @import("io/pipe.zig");
pub const process = @import("process.zig");

pub const net = struct {
    pub const Resolve = @import("net/resolve.zig");
    pub const Dial = @import("net/dial.zig").Dial;
    pub const SocketOption = @import("net/options.zig").Option;
    pub const Shutdown = @import("net/options.zig").Shutdown;

    pub const Address = types.Address;
    pub const Tcp = @import("net/tcp.zig").Tcp;
    pub const Udp = @import("net/udp.zig").Udp;
};

pub const fmt = @import("fmt/number.zig");
