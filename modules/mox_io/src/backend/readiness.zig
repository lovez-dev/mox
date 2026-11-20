//! Shared completion semantics for readiness-based native backends.

const t = @import("../types.zig");
const c = @import("common.zig");
const Error = @import("../error.zig").Error;
const Arena = @import("../mem/arena.zig");
const Layout = @import("../mem/layout.zig").Layout;
const Queue = @import("../core/queue.zig").Queue;
const Blocking = @import("blocking.zig");

pub const ReadyEvent = struct { cookie: usize, read: bool = false, write: bool = false };

/// Native bindings are selected at compile time; the I/O path has no dispatch vtable.
pub fn Driver(comptime Native: type) type {
    return struct {
        const Self = @This();

        const Resource = struct {
            handle: t.Handle = .{ .index = t.none, .generation = 0 },
            native: usize = t.invalid_native,
            kind: t.ResourceKind = .tcp,
            active: bool = false,
            retired: bool = false,

            // Each direction has at most one borrowed native request.
            read: ?*c.Request = null,
            write: ?*c.Request = null,
            watched_write: bool = false,
            connect_started: bool = false,
            ready_read: bool = false,
            ready_write: bool = false,

            queued: bool = false,
            previous: u32 = t.none,
            next: u32 = t.none,
        };

        native: Native,
        resources: []Resource,
        requests: []c.Request,
        close_requests: []c.Request,
        // At most one speculative read retry per later successful send in this batch.
        batch_read: ?*c.Request = null,
        completed: Queue(c.Event),
        path: []u8,
        workers: Blocking = undefined,

        // Intrusive ready queue; each resource is linked at most once.
        ready_head: u32 = t.none,
        ready_tail: u32 = t.none,
        ready_count: usize = 0,
        batch: u32,
        native_check: u3 = 0,

        last_error: i32 = 0,
        counters: c.NativeStats = .{},

        pub const capabilities: c.Capabilities = .{ .file_workers = true };

        pub const socket = Native.socket;
        pub const localAddress = Native.localAddress;
        pub const closeNative = Native.closeNative;
        pub const noDelay = Native.noDelay;

        pub fn layout(sizer: *Layout, options: t.Options) Error!void {
            try sizer.add(Resource, options.resources);
            try sizer.add(c.Event, options.operations);
            try sizer.add(u8, options.path_capacity);
            try sizer.add(c.Request, options.resources);
            try Native.layout(sizer, options);
            try Blocking.layout(sizer, options);
        }

        pub fn init(self: *Self, arena: *Arena, options: t.Options, requests: []c.Request) Error!void {
            self.* = .{
                .native = undefined,
                .resources = try arena.allocate(Resource, options.resources),
                .requests = requests,
                .completed = .{ .storage = try arena.allocate(c.Event, options.operations) },
                .path = try arena.allocate(u8, options.path_capacity),
                .close_requests = try arena.allocate(c.Request, options.resources),
                .batch = options.events,
            };
            for (self.resources) |*resource| resource.* = .{};
            try self.native.init(arena, options);
            errdefer self.native.deinit();
            try self.workers.init(arena, options, Native.fileWork, self, wakeThunk);
            self.counters.workers = self.workers.workerCount();
            self.counters.shared_executor = self.workers.isShared();
        }

        pub fn deinit(self: *Self) void {
            self.workers.deinit();
            self.native.deinit();
        }

        pub fn openFile(self: *Self, path: []const u8, create: bool, writable: bool) Error!usize {
            return Native.openFile(path, create, writable, self.path);
        }

        pub fn attach(self: *Self, handle: t.Handle, descriptor: usize, kind: t.ResourceKind) Error!void {
            const resource = &self.resources[handle.index];
            if (resource.queued) @panic("ready record reused before removal");
            resource.* = .{ .handle = handle, .native = descriptor, .kind = kind };
            if (kind != .file) {
                self.native.add(descriptor, @intFromPtr(resource)) catch |err| {
                    self.last_error = self.native.last_error;
                    return err;
                };
            }
            resource.active = true;
        }

        pub fn detach(self: *Self, handle: t.Handle, descriptor: usize, kind: t.ResourceKind) c.CloseResult {
            const resource = &self.resources[handle.index];
            if (kind == .file and self.workers.workerCount() != 0) {
                const request = &self.close_requests[handle.index];
                request.* = .{ .id = .{ .index = @intCast(self.requests.len + handle.index), .generation = handle.generation }, .handle = handle, .native = descriptor, .kind = .close, .options = .{} };
                self.workers.submit(request) catch @panic("reserved file close was rejected");
                resource.active = false;
                self.counters.worker_jobs +|= 1;
                return .{ .pending = true };
            }
            if (!resource.retired and kind != .file) {
                self.native.remove(descriptor, resource.watched_write) catch {
                    return .{ .closed = false, .native_error = self.native.last_error };
                };
            }
            // Remove queued cookies before the resource slot can identify a new socket.
            self.removeReady(handle.index);
            resource.active = false;
            return if (resource.retired) .{} else Native.closeNative(descriptor, kind);
        }

        fn watch(self: *Self, resource: *Resource) Error!void {
            // Read interest persists; write interest is needed only while that direction waits.
            const needed = resource.write != null;
            if (needed == resource.watched_write or resource.retired) return;
            self.native.setWrite(resource.native, @intFromPtr(resource), needed) catch |err| {
                self.last_error = self.native.last_error;
                return err;
            };
            resource.watched_write = needed;
        }

        fn queue(self: *Self, event: c.Event) void {
            if (!self.completed.push(event)) @panic("readiness completion reservation lost");
            self.counters.completions +|= 1;
        }

        pub fn submit(self: *Self, request: *c.Request) Error!void {
            self.last_error = 0;
            self.counters.submissions +|= 1;
            if (request.kind == .work or request.kind == .read or request.kind == .write or request.kind == .sync or request.kind == .open or request.kind == .stat) {
                try self.workers.submit(request);
                self.counters.worker_jobs +|= 1;
                return;
            }
            const resource = &self.resources[request.handle.index];
            // Try first: an edge may have arrived before this operation was submitted.
            const attempt = Native.attempt(request, false);
            if (!attempt.pending) {
                self.queue(attempt.event);
                if ((request.kind == .send or request.kind == .send_to) and attempt.event.bytes != 0) self.retryBatchRead();
                return;
            }
            if (request.kind == .recv or request.kind == .recv_from or request.kind == .accept)
                resource.read = request
            else
                resource.write = request;
            if (request.kind == .recv or request.kind == .recv_from) self.batch_read = request;
            if (request.kind == .connect) resource.connect_started = true;
            self.watch(resource) catch |err| {
                if (resource.read == request) resource.read = null;
                if (resource.write == request) resource.write = null;
                self.failPending(resource);
                return err;
            };
        }

        fn retryBatchRead(self: *Self) void {
            const request = self.batch_read orelse return;
            self.batch_read = null;
            const resource = &self.resources[request.handle.index];
            if (resource.read != request) return;
            // A sibling send may make this read ready without an epoll/kevent roundtrip.
            // EAGAIN leaves the normal edge-triggered wait intact.
            const attempt = Native.attempt(request, false);
            if (!attempt.pending) {
                resource.read = null;
                self.queue(attempt.event);
            }
        }

        fn failPending(self: *Self, resource: *Resource) void {
            // A broken watch must not leave the opposite direction waiting forever.
            if (resource.read) |request| {
                self.queue(.{ .id = request.id, .status = .failed, .native_error = self.last_error });
                resource.read = null;
            }
            if (resource.write) |request| {
                self.queue(.{ .id = request.id, .status = .failed, .native_error = self.last_error });
                resource.write = null;
            }
        }

        pub fn cancel(self: *Self, id: t.OpId) void {
            self.counters.cancellations +|= 1;
            const request = &self.requests[id.index];
            if (self.batch_read == request) self.batch_read = null;
            if (request.kind == .work or request.kind == .read or request.kind == .write or request.kind == .sync or request.kind == .open or request.kind == .stat) {
                self.workers.cancel(id);
                return;
            }
            const resource = &self.resources[request.handle.index];
            if (resource.read == request) {
                resource.read = null;
                self.queue(.{ .id = id, .status = .canceled });
            } else if (resource.write == request) {
                resource.write = null;
                if (request.kind == .connect) {
                    // Closing is the portable way to retire an in-progress connect.
                    self.native.remove(resource.native, resource.watched_write) catch {};
                    _ = Native.closeNative(resource.native, .tcp);
                    resource.retired = true;
                    self.removeReady(request.handle.index);
                }
                self.queue(.{ .id = id, .status = .canceled });
                self.watch(resource) catch {
                    self.failPending(resource);
                };
            }
        }

        pub fn wake(self: *Self) void {
            self.native.wake();
        }

        fn wakeThunk(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.wake();
        }

        fn pushReady(self: *Self, index: u32) void {
            // One node per resource coalesces readiness without growing the queue.
            const resource = &self.resources[index];
            if (resource.queued) return;
            resource.queued = true;
            resource.previous = self.ready_tail;
            resource.next = t.none;
            if (self.ready_tail != t.none) self.resources[self.ready_tail].next = index else self.ready_head = index;
            self.ready_tail = index;
            self.ready_count += 1;
        }

        fn removeReady(self: *Self, index: u32) void {
            const resource = &self.resources[index];
            if (!resource.queued) return;
            if (resource.previous != t.none) self.resources[resource.previous].next = resource.next else self.ready_head = resource.next;
            if (resource.next != t.none) self.resources[resource.next].previous = resource.previous else self.ready_tail = resource.previous;
            resource.queued = false;
            resource.next = t.none;
            resource.previous = t.none;
            self.ready_count -= 1;
        }

        fn processReady(self: *Self) void {
            // Bound retries so a busy descriptor set cannot monopolize an owner pump.
            const count = @min(self.ready_count, self.batch);
            for (0..count) |_| {
                const index = self.ready_head;
                const resource = &self.resources[index];
                self.removeReady(index);
                const readable = resource.ready_read;
                const writable = resource.ready_write;
                resource.ready_read = false;
                resource.ready_write = false;
                if (!resource.active or resource.retired) continue;
                if (readable) {
                    if (resource.read) |request| {
                        const attempt = Native.attempt(request, false);
                        if (!attempt.pending) {
                            resource.read = null;
                            self.queue(attempt.event);
                        }
                    }
                }
                if (writable) {
                    if (resource.write) |request| {
                        const attempt = Native.attempt(request, resource.connect_started);
                        if (!attempt.pending) {
                            resource.write = null;
                            self.queue(attempt.event);
                            self.watch(resource) catch {
                                self.failPending(resource);
                            };
                        }
                    }
                }
            }
        }

        fn harvest(self: *Self, output: []c.Event) usize {
            var count = self.workers.poll(output);
            self.counters.completions +|= count;
            while (count < output.len) {
                output[count] = self.completed.pop() orelse break;
                count += 1;
            }
            return count;
        }

        pub fn poll(self: *Self, output: []c.Event, duration: ?u64) Error!usize {
            self.counters.polls +|= 1;
            self.batch_read = null;
            self.processReady();
            // Inline completions can stay nonempty indefinitely under load.
            // Refresh kernel readiness at least every eight pumps so another
            // socket's read, accept, or wake event cannot starve behind them.
            // Check before harvesting so a native error never loses results.
            self.native_check +%= 1;
            if (self.native_check == 0) {
                try self.collectNative(0);
                self.processReady();
            }
            const present = self.harvest(output);
            if (present != 0 or self.ready_count != 0) return present;
            try self.collectNative(duration);
            self.processReady();
            return self.harvest(output);
        }

        fn collectNative(self: *Self, duration: ?u64) Error!void {
            const events = self.native.poll(duration) catch |err| {
                self.last_error = self.native.last_error;
                return err;
            };
            // Consume the entire native batch before resource slots can be recycled.
            for (events) |raw| {
                const event = Native.decode(raw);
                if (event.cookie == 0) {
                    self.native.drainWake();
                    self.counters.wakeups +|= 1;
                    continue;
                }
                const resource: *Resource = @ptrFromInt(event.cookie);
                if (!resource.active or resource.retired) continue;
                resource.ready_read = resource.ready_read or event.read;
                resource.ready_write = resource.ready_write or event.write;
                self.pushReady(resource.handle.index);
            }
        }

        pub fn stats(self: *const Self) c.NativeStats {
            return self.counters;
        }
    };
}
