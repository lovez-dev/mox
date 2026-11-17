//! Native io_uring submissions, batched completions and retirement-safe cancellation.

const eventfd = @import("../os/linux/eventfd.zig");
const t = @import("../types.zig");
const c = @import("common.zig");
const s = @import("../os/abi/linux.zig");
const u = @import("../os/linux/uring.zig");
const net = @import("native/linux_net.zig");
const files = @import("../os/linux/file.zig");
const Arena = @import("../mem/arena.zig");
const Layout = @import("../mem/layout.zig").Layout;
const Error = @import("../error.zig").Error;
const Blocking = @import("blocking.zig");
const Queue = @import("../core/queue.zig").Queue;

const Driver = @This();

const Iovec = s.Iovec;
const Message = s.Message;

const Context = struct {
    // Primary and cancel CQEs share this pinned address until both have retired.
    request: *c.Request = undefined,
    active: bool = false,
    // Staged receives have not reached the kernel and need no cancel SQE.
    staged: bool = false,
    primary_done: bool = false,
    cancel_pending: bool = false,
    result: c.Event = undefined,
    address: [128]u8 align(8) = undefined,
    address_length: u32 = 128,
    vector: Iovec = undefined,
    message: Message = undefined,
};

// Pinned request storage and kernel ring state.
ring: u.Ring,
contexts: []Context,
requests: []c.Request,
close_requests: []c.Request,
// Resource indices map to fixed slots; ordinary fds remain available to fast paths.
fixed_files: []i32,
immediate: Queue(u32),
// Each staged receive gets one attempt at most; the ring handles backpressure.
staged: Queue(u32),
native_pending: usize = 0,
immediate_turn: bool = false,
path: []u8,
workers: Blocking = undefined,

wake_fd: i32,
wake_armed: bool = false,
poll_woken: bool = false,
batch: u32,

last_error: i32 = 0,
counters: c.NativeStats = .{},

// Backend contract consumed by Loop.
pub const capabilities: c.Capabilities = .{ .native_files = true, .file_workers = true };

pub const localAddress = net.localAddress;
pub const closeNative = @import("native/linux_file.zig").closeNative;
pub const noDelay = net.noDelay;

/// Resource failures remain errors; only missing kernel support reports false.
pub fn probe() Error!bool {
    var ring: u.Ring = .{};
    ring.init(2) catch |err| {
        if (err == error.BackendUnavailable) return false;
        return err;
    };
    ring.deinit();
    return true;
}

pub fn available() bool {
    return probe() catch false;
}

pub fn layout(sizer: *Layout, options: t.Options) Error!void {
    const capacity = try c.workerCapacity(options);
    _ = try u.capacity(capacity);
    try sizer.add(Context, capacity);
    try sizer.add(u32, capacity);
    try sizer.add(u32, capacity);
    try sizer.add(u8, options.path_capacity);
    try sizer.add(c.Request, options.resources);
    if (options.uring_fixed_files) try sizer.add(i32, options.resources);
    try Blocking.layout(sizer, options);
}

pub fn init(self: *Driver, arena: *Arena, options: t.Options, requests: []c.Request) Error!void {
    self.* = .{
        .ring = .{},
        .contexts = try arena.allocate(Context, try c.workerCapacity(options)),
        .immediate = .{ .storage = try arena.allocate(u32, try c.workerCapacity(options)) },
        .staged = .{ .storage = try arena.allocate(u32, try c.workerCapacity(options)) },
        .requests = requests,
        .path = try arena.allocate(u8, options.path_capacity),
        .close_requests = try arena.allocate(c.Request, options.resources),
        .fixed_files = if (options.uring_fixed_files) try arena.allocate(i32, options.resources) else &.{},
        .wake_fd = -1,
        .batch = options.events,
    };
    for (self.contexts) |*context| context.* = .{};
    try self.ring.init(try u.capacity(try c.workerCapacity(options)));
    errdefer self.ring.deinit();
    if (self.fixed_files.len != 0) {
        for (self.fixed_files) |*descriptor| descriptor.* = -1;
        if (try self.ring.registerFiles(self.fixed_files)) {
            self.counters.fixed_file_capacity = @intCast(self.fixed_files.len);
        } else self.fixed_files = &.{};
    }
    const descriptor = s.eventfd();
    if (s.errno(descriptor) != 0) return error.NativeFailure;
    self.wake_fd = @intCast(descriptor);
    errdefer _ = s.close(self.wake_fd);
    self.armWake();
    try self.ring.flush();
    try self.workers.init(arena, options, @import("native/linux_file.zig").work, self, wakeThunk);
    self.counters.workers = self.workers.workerCount();
    self.counters.shared_executor = self.workers.isShared();
    self.counters.kernel_mapped_bytes = self.ring.mapped_bytes;
}

pub fn deinit(self: *Driver) void {
    self.workers.deinit();
    self.ring.deinit();
    _ = s.close(self.wake_fd);
}

pub fn socket(kind: t.ResourceKind, family: t.Address.Family, address: ?t.Address, backlog: u32) Error!usize {
    return net.socketWithFlags(kind, family, address, backlog, false);
}

pub fn attach(self: *Driver, handle: t.Handle, native: usize, _: t.ResourceKind) Error!void {
    if (native > 0x7fffffff) return error.InvalidResource;
    if (self.fixed_files.len == 0) return;
    if (self.fixed_files[handle.index] != -1) @panic("fixed file slot reused before retirement");
    self.ring.updateFile(handle.index, @intCast(native)) catch |err| {
        self.last_error = self.ring.last_error;
        return err;
    };
    self.fixed_files[handle.index] = @intCast(native);
    self.counters.registered_files += 1;
}

pub fn detach(self: *Driver, handle: t.Handle, native: usize, kind: t.ResourceKind) c.CloseResult {
    if (self.fixed_files.len != 0 and self.fixed_files[handle.index] != -1) {
        // Loop has retired every borrower, including cancellation CQEs. Drop the
        // extra kernel reference before close so sockets really produce peer EOF.
        self.ring.updateFile(handle.index, -1) catch {
            self.last_error = self.ring.last_error;
            return .{ .closed = false, .native_error = self.last_error };
        };
        self.fixed_files[handle.index] = -1;
        self.counters.registered_files -= 1;
    }
    if (kind == .file) {
        const request = &self.close_requests[handle.index];
        request.* = .{ .id = .{ .index = @intCast(self.requests.len + handle.index), .generation = handle.generation }, .handle = handle, .native = native, .kind = .close, .options = .{} };
        self.submit(request) catch @panic("reserved io_uring close was rejected");
        return .{ .pending = true };
    }
    return closeNative(native, kind);
}

pub fn openFile(self: *Driver, path: []const u8, create: bool, writable: bool) Error!usize {
    return files.openFile(path, t.FileOpenOptions.legacy(create, writable), self.path);
}

fn reserve(self: *Driver) *u.Sqe {
    // One primary and one cancellation SQE per operation, plus the wake request.
    return self.ring.reserve() orelse @panic("io_uring admission reservation lost");
}

pub fn submit(self: *Driver, request: *c.Request) Error!void {
    self.last_error = 0;
    self.counters.submissions +|= 1;
    if (request.kind == .work or request.kind == .open or request.kind == .stat) {
        try self.workers.submit(request);
        self.counters.worker_jobs +|= 1;
        return;
    }
    const context = &self.contexts[request.id.index];
    if (context.active) @panic("io_uring context reused before retirement");
    context.request = request;
    if (request.kind == .send) {
        // MSG_DONTWAIT keeps this fast path nonblocking even on ordinary uring sockets.
        const result = while (true) {
            const value = s.send_to(@intCast(request.native), request.write_buffer, s.msg_nosignal | s.msg_dontwait, null, 0);
            if (s.errno(value) != 4) break value;
        };
        const code = s.errno(result);
        if (code != 11) {
            context.result = .{ .id = request.id, .status = if (code == 0) .ok else .failed, .bytes = if (code == 0) @intCast(result) else 0, .native_error = code };
            if (!self.immediate.push(request.id.index)) @panic("immediate completion reservation lost");
            return;
        }
    }
    context.active = true;
    context.primary_done = false;
    context.cancel_pending = false;
    context.address_length = 128;
    if (request.kind == .recv) {
        // Keep admission ordered; poll can first observe sibling send progress.
        context.staged = true;
        if (!self.staged.push(request.id.index)) @panic("staged receive reservation lost");
        return;
    }
    self.submitNative(context);
}

fn submitNative(self: *Driver, context: *Context) void {
    self.native_pending += 1;
    const request = context.request;
    const entry = self.reserve();
    entry.* = .{ .fd = @intCast(request.native), .user_data = @intFromPtr(context) };
    // CLOSE must release the ordinary fd; it never addresses the fixed table.
    if (request.kind != .close and self.fixed_files.len != 0) {
        if (self.fixed_files[request.handle.index] != @as(i32, @intCast(request.native)))
            @panic("native request lost its registered file");
        entry.fd = @intCast(request.handle.index);
        entry.flags = u.sqe_fixed_file;
        self.counters.fixed_file_submissions +|= 1;
    }
    switch (request.kind) {
        .accept => {
            entry.opcode = 13;
            entry.address = @intFromPtr(&context.address);
            entry.offset = @intFromPtr(&context.address_length);
            entry.operation_flags = 0x80000;
        },
        .connect => {
            entry.opcode = 16;
            entry.address = @intFromPtr(&context.address);
            entry.offset = net.encode(request.address, &context.address);
        },
        .recv, .read => {
            entry.opcode = if (request.kind == .recv) 27 else 22;
            entry.address = @intFromPtr(request.read_buffer.ptr);
            entry.length = @intCast(@min(request.read_buffer.len, 0x7ffff000));
            entry.offset = request.offset;
        },
        .send, .write => {
            entry.opcode = if (request.kind == .send) 26 else 23;
            entry.address = @intFromPtr(request.write_buffer.ptr);
            entry.length = @intCast(@min(request.write_buffer.len, 0x7ffff000));
            entry.offset = request.offset;
            if (request.kind == .send) entry.operation_flags = 0x4000;
        },
        .recv_from, .send_to => {
            const reading = request.kind == .recv_from;
            const bytes = if (reading) request.read_buffer else @constCast(request.write_buffer);
            context.vector = .{ .base = bytes.ptr, .length = bytes.len };
            context.message = .{ .name = &context.address, .name_length = if (reading) 128 else net.encode(request.address, &context.address), .vectors = &context.vector, .vector_count = 1 };
            entry.opcode = if (reading) 10 else 9;
            entry.address = @intFromPtr(&context.message);
            entry.length = 1;
            entry.operation_flags = if (reading) 0x20 else 0x4000;
        },
        .sync => entry.opcode = 3,
        .close => entry.opcode = 19,
        .open, .stat, .timer, .work => unreachable,
    }
}

pub fn cancel(self: *Driver, id: t.OpId) void {
    if (self.requests[id.index].kind == .work or self.requests[id.index].kind == .open or self.requests[id.index].kind == .stat) {
        self.workers.cancel(id);
        return;
    }
    const context = &self.contexts[id.index];
    if (!context.active or context.primary_done or context.cancel_pending) return;
    if (context.staged) {
        context.staged = false;
        context.active = false;
        context.result = .{ .id = id, .status = .canceled };
        if (!self.immediate.push(id.index)) @panic("canceled receive reservation lost");
        self.counters.cancellations +|= 1;
        return;
    }
    context.cancel_pending = true;
    // Low-bit tags distinguish cancellation from the original request's CQE.
    const entry = self.reserve();
    entry.* = .{ .opcode = 14, .address = @intFromPtr(context), .user_data = @intFromPtr(context) | 1 };
    self.counters.cancellations +|= 1;
}

fn armWake(self: *Driver) void {
    // Poll requests are one-shot; their CQE must be consumed before rearming.
    if (self.wake_armed) return;
    self.reserve().* = .{ .opcode = 6, .fd = self.wake_fd, .operation_flags = 1, .user_data = 2 };
    self.wake_armed = true;
}

pub fn wake(self: *Driver) void {
    eventfd.signal(self.wake_fd);
}

fn wakeThunk(context: *anyopaque) void {
    const self: *Driver = @ptrCast(@alignCast(context));
    self.wake();
}

fn drainWake(self: *Driver) void {
    eventfd.drain(self.wake_fd);
}

fn decode(context: *Context, raw: u.Cqe) c.Event {
    const request = context.request;
    var event: c.Event = .{ .id = request.id, .closed_handle = if (request.kind == .close) request.handle else null };
    if (raw.result < 0) {
        event.native_error = -raw.result;
        event.status = if (event.native_error == 125) .canceled else .failed;
        if (request.kind == .close) {
            // Admission errors leave the fd owned; syscall writeback errors release it.
            event.close_released = event.native_error != 11 and event.native_error != 12 and event.native_error != 22 and event.native_error != 38 and event.native_error != 95 and event.native_error != 125;
        }
        return event;
    }
    switch (request.kind) {
        .accept => {
            event.accepted_native = @intCast(raw.result);
            event.peer = net.decode(&context.address);
        },
        .connect, .sync, .close => {},
        .recv_from => {
            event.bytes = @min(@as(usize, @intCast(raw.result)), request.read_buffer.len);
            event.peer = net.decode(&context.address);
            event.truncated = context.message.flags & 0x20 != 0;
        },
        else => {
            event.bytes = @intCast(raw.result);
            if ((request.kind == .recv or request.kind == .read) and raw.result == 0) event.status = .eof;
        },
    }
    return event;
}

fn harvest(self: *Driver, output: []c.Event) usize {
    var count = self.workers.poll(output);
    self.counters.completions +|= count;
    var native_limit = output.len;
    if (self.native_pending != 0 and self.immediate.count != 0) {
        // Reserve one slot every other poll, including when output has just one slot.
        self.immediate_turn = !self.immediate_turn;
        if (self.immediate_turn and count < native_limit) native_limit -= 1;
    }
    var consumed: usize = 0;
    while (count < native_limit and consumed < @as(usize, self.batch) * 2 + 1) : (consumed += 1) {
        const raw = self.ring.pop() orelse break;
        self.counters.native_cqes +|= 1;
        if (raw.user_data == 2) {
            self.wake_armed = false;
            self.drainWake();
            self.poll_woken = true;
            self.counters.wakeups +|= 1;
            continue;
        }
        const context: *Context = @ptrFromInt(raw.user_data & ~@as(u64, 7));
        if (!context.active or raw.flags & 2 != 0) @panic("unexpected io_uring completion");
        if (raw.user_data & 1 != 0) {
            context.cancel_pending = false;
        } else {
            context.result = decode(context, raw);
            context.primary_done = true;
        }
        // A cancel SQE may otherwise match a new operation at the same address.
        if (context.primary_done and !context.cancel_pending) {
            output[count] = context.result;
            context.active = false;
            self.native_pending -= 1;
            count += 1;
            self.counters.completions +|= 1;
        }
    }
    // Native retirements precede new immediate results so fast sends cannot starve them.
    while (count < output.len) {
        const index = self.immediate.pop() orelse break;
        output[count] = self.contexts[index].result;
        count += 1;
        self.counters.completions +|= 1;
    }
    return count;
}

fn flushStaged(self: *Driver) void {
    while (self.staged.pop()) |index| {
        const context = &self.contexts[index];
        if (!context.staged) continue;
        context.staged = false;
        // Data can arrive from another owner before this poll, without a sibling send.
        // Try once without blocking; EAGAIN falls back to the native ring.
        const request = context.request;
        const result = while (true) {
            const value = s.recv_from(@intCast(request.native), request.read_buffer, s.msg_dontwait, null, null);
            if (s.errno(value) != 4) break value;
        };
        const code = s.errno(result);
        if (code != 11) {
            context.active = false;
            context.result = .{ .id = request.id, .status = if (code != 0) .failed else if (result == 0) .eof else .ok, .bytes = if (code == 0) @intCast(result) else 0, .native_error = code };
            if (!self.immediate.push(index)) @panic("receive completion reservation lost");
            continue;
        }
        self.submitNative(context);
    }
}

pub fn poll(self: *Driver, output: []c.Event, duration: ?u64) Error!usize {
    self.counters.polls +|= 1;
    self.flushStaged();
    self.poll_woken = false;
    self.armWake();
    // DEFER_TASKRUN needs GETEVENTS even while immediate sends keep the owner busy.
    if (self.immediate.count != 0 and self.native_pending != 0) {
        self.ring.flushAndWait(0) catch |err| {
            self.last_error = self.ring.last_error;
            return err;
        };
    }
    const present = self.harvest(output);
    // Return a harvested wake to the inbox owner before considering another wait.
    if (present != 0 or self.poll_woken) {
        self.ring.flush() catch |err| {
            self.last_error = self.ring.last_error;
            return err;
        };
        return present;
    }
    self.ring.flushAndWait(duration) catch |err| {
        self.last_error = self.ring.last_error;
        return err;
    };
    return self.harvest(output);
}

pub fn stats(self: *const Driver) c.NativeStats {
    return self.counters;
}

comptime {
    if (@alignOf(Context) < 8 or @sizeOf(Message) != 56) @compileError("invalid io_uring context ABI");
}
