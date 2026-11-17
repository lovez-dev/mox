//! Owner-thread admission and retirement over fixed operation and resource pools.

const t = @import("types.zig");
const Error = @import("error.zig").Error;
const op = @import("core/operation.zig");
const res = @import("core/resource.zig");
const timers = @import("core/timer.zig");
const Queue = @import("core/queue.zig").Queue;
const common = @import("backend/common.zig");
const mem = @import("mem/allocator.zig");
const Tracking = @import("mem/tracking.zig");
const Arena = @import("mem/arena.zig");
const Layout = @import("mem/layout.zig").Layout;
const os = @import("os/root.zig");
const Stats = @import("stats.zig").Stats;
const Clock = @import("time/clock.zig");

// Completion nodes encode either an operation index or a reserved resource-close index.
const close_bit: u64 = @as(u64, 1) << 63;

/// A Loop and its allocator tracker must remain at their initialized address.
pub fn Loop(comptime Backend: type) type {
    return struct {
        const Self = @This();

        pub const Command = union(enum) {
            cancel: t.OpId,
            close: struct { handle: t.Handle, mode: t.CloseMode = .cancel, tag: usize = 0 },
            stop,
            shutdown,
            task: struct { context: ?*anyopaque = null, run: *const fn (?*anyopaque, *Self) void },
        };

        const Inbox = @import("core/inbox.zig").Inbox(Command);

        tracking: Tracking,
        allocation: ?mem.Allocation = null,

        operations: op.Store,
        resources: res.Store,
        deadlines: timers.Heap,
        submitted: Queue(u32),
        // One terminal result per operation, plus one close result per resource.
        completed: Queue(u64),
        events: []common.Event,

        inbox: Inbox = .{},
        clock: Clock,
        backend: Backend,
        path_capacity: usize,

        owner: u64 = 0,
        running: bool = false,
        initialized: bool = false,

        completion_high_water: usize = 0,
        counters: Counters = .{},
        native_final: common.NativeStats = .{},

        // Close retries retain resource ownership until the native descriptor retires.
        retry_head: u32 = t.none,
        retry_tail: u32 = t.none,
        retry_count: u32 = 0,

        pub const Counters = struct {
            submissions: u64 = 0,
            completed: u64 = 0,
            canceled: u64 = 0,
            timed_out: u64 = 0,
            failed: u64 = 0,
            capacity_rejections: u64 = 0,

            bytes_read: u64 = 0,
            bytes_written: u64 = 0,

            close_failures: u64 = 0,
            close_retries: u64 = 0,
            last_close_error: i32 = 0,
        };

        /// Library backing only; caller buffers, native mappings and stacks are excluded.
        pub fn memoryRequired(options: t.Options) Error!usize {
            if (options.operations == 0 or options.resources == 0 or options.events == 0) return error.InvalidOptions;
            if (options.path_capacity == 0) return error.InvalidOptions;
            _ = try common.workerCapacity(options);
            if (options.inbox != 0 and options.inbox & (options.inbox - 1) != 0) return error.InvalidOptions;
            var layout: Layout = .{};
            try layout.add(op.Slot, options.operations);
            try layout.add(op.Request, options.operations);
            try layout.add(t.Completion, options.operations);
            try layout.add(res.Slot, options.resources);
            try layout.add(timers.Entry, options.operations);
            try layout.add(u32, options.operations);
            try layout.add(u64, @as(usize, options.operations) + options.resources);
            try layout.add(common.Event, options.events);
            try layout.add(Inbox.Cell, options.inbox);
            try Backend.layout(&layout, options);
            return layout.size;
        }

        pub fn init(self: *Self, allocator: mem.Allocator, options: t.Options) Error!void {
            // All pools share one backing allocation; the hot path never grows them.
            self.* = .{
                .tracking = .{ .parent = allocator },
                .operations = .{ .slots = &.{}, .requests = &.{}, .results = &.{}, .free_head = t.none },
                .resources = .{ .slots = &.{}, .free_head = t.none },
                .deadlines = .{ .storage = &.{}, .slots = &.{} },
                .submitted = .{ .storage = &.{} },
                .completed = .{ .storage = &.{} },
                .events = &.{},
                .backend = undefined,
                .owner = os.threadId(),
                .clock = Clock.init(),
                .path_capacity = options.path_capacity,
            };

            const allocation = try self.tracking.allocator().allocate(try memoryRequired(options), 64);
            self.allocation = allocation;
            errdefer {
                self.inbox.seal();
                self.tracking.allocator().release(allocation);
                self.allocation = null;
            }
            var arena: Arena = .{ .bytes = allocation.bytes };
            self.operations = .{
                .slots = try arena.allocate(op.Slot, options.operations),
                .requests = try arena.allocate(op.Request, options.operations),
                .results = try arena.allocate(t.Completion, options.operations),
                .free_head = 0,
            };
            self.operations.initialize();
            self.resources = .{ .slots = try arena.allocate(res.Slot, options.resources), .free_head = 0 };
            self.resources.initialize();
            self.deadlines = .{ .storage = try arena.allocate(timers.Entry, options.operations), .slots = self.operations.slots };
            self.submitted = .{ .storage = try arena.allocate(u32, options.operations) };
            self.completed = .{ .storage = try arena.allocate(u64, @as(usize, options.operations) + options.resources) };
            self.events = try arena.allocate(common.Event, options.events);
            self.inbox.init(try arena.allocate(Inbox.Cell, options.inbox));
            try self.backend.init(&arena, options, self.operations.requests);
            self.initialized = true;
            self.running = true;
        }

        fn checkOwner(self: *const Self) Error!void {
            if (!self.initialized) return error.InvalidState;
            if (self.owner != os.threadId()) return error.WrongThread;
        }

        /// Drain results and join external producers before releasing the stable backing.
        pub fn deinit(self: *Self) Error!void {
            try self.checkOwner();
            if (self.operations.active != 0 or self.resources.active != 0 or self.completed.count != 0) return error.Busy;
            self.inbox.seal();
            if (!self.inbox.quiescent()) return error.Busy;
            self.native_final = self.backend.stats();
            self.backend.deinit();
            self.native_final.workers = 0;
            self.native_final.kernel_mapped_bytes = 0;
            self.native_final.fixed_file_capacity = 0;
            self.native_final.registered_files = 0;
            self.tracking.allocator().release(self.allocation.?);
            self.allocation = null;
            self.initialized = false;
            self.running = false;
        }

        /// Owner-side snapshot. Cumulative counters remain readable after deinit().
        pub fn stats(self: *const Self) Stats {
            // Caller buffers and kernel-owned allocations are outside this snapshot.
            return .{
                .memory = self.tracking.stats(),
                .native = if (self.initialized) self.backend.stats() else self.native_final,
                .inbox = self.inbox.stats(),
                .active_operations = self.operations.active,
                .operation_high_water = self.operations.high_water,
                .active_resources = self.resources.active,
                .resource_high_water = self.resources.high_water,
                .completions_queued = self.completed.count,
                .completion_high_water = self.completion_high_water,
                .timers_active = self.deadlines.count,
                .submissions = self.counters.submissions,
                .completed = self.counters.completed,
                .canceled = self.counters.canceled,
                .timed_out = self.counters.timed_out,
                .failed = self.counters.failed,
                .capacity_rejections = self.counters.capacity_rejections,
                .bytes_read = self.counters.bytes_read,
                .bytes_written = self.counters.bytes_written,
                .close_failures = self.counters.close_failures,
                .close_retries = self.counters.close_retries,
                .closes_pending_retry = self.retry_count,
                .last_close_error = self.counters.last_close_error,
            };
        }

        fn reserveResource(self: *Self) Error!t.Handle {
            return self.resources.reserve() catch |err| {
                if (err == error.Capacity) self.counters.capacity_rejections +|= 1;
                return err;
            };
        }

        fn retainResource(self: *Self, resource_index: u32, operation_index: u32) void {
            // Intrusive links make close visit only operations borrowing this resource.
            const resource = &self.resources.slots[resource_index];
            const slot = &self.operations.slots[operation_index];
            slot.resource_next = resource.operation_head;
            if (resource.operation_head != t.none) self.operations.slots[resource.operation_head].resource_previous = operation_index;
            resource.operation_head = operation_index;
            resource.references += 1;
        }

        fn releaseResource(self: *Self, resource_index: u32, operation_index: u32) void {
            const resource = &self.resources.slots[resource_index];
            const slot = &self.operations.slots[operation_index];
            if (slot.resource_previous != t.none) self.operations.slots[slot.resource_previous].resource_next = slot.resource_next else resource.operation_head = slot.resource_next;
            if (slot.resource_next != t.none) self.operations.slots[slot.resource_next].resource_previous = slot.resource_previous;
            slot.resource_previous = t.none;
            slot.resource_next = t.none;
            resource.references -= 1;
        }

        /// Thread-safe admission. Task contexts must live until the owner executes them.
        pub fn post(self: *Self, command: Command) Error!void {
            try self.inbox.post(command, &self.backend, Backend.wake);
        }

        /// Reject further posts before joining producer threads.
        pub fn closeInbox(self: *Self) Error!void {
            try self.checkOwner();
            self.inbox.seal();
        }

        fn drainInbox(self: *Self) bool {
            var progress = false;
            for (0..self.events.len) |_| {
                const command = self.inbox.pop() orelse break;
                progress = true;
                switch (command) {
                    .cancel => |id| {
                        _ = self.cancel(id) catch {
                            self.inbox.errors +|= 1;
                            continue;
                        };
                    },
                    .close => |value| self.close(value.handle, value.mode, value.tag) catch {
                        self.inbox.errors +|= 1;
                    },
                    .stop => self.stop() catch unreachable,
                    .shutdown => self.shutdown() catch {
                        self.inbox.errors +|= 1;
                    },
                    .task => |task| task.run(task.context, self),
                }
            }
            return progress;
        }

        /// Fresh monotonic time; cachedNow() returns the last owner-side sample.
        pub fn now(self: *const Self) u64 {
            return self.clock.now();
        }

        pub fn cachedNow(self: *const Self) u64 {
            return self.clock.cached;
        }

        /// Timers use operation slots and produce .ok results with invalid_handle.
        pub fn sleepUntil(self: *Self, deadline: u64, tag: usize) Error!t.OpId {
            try self.checkOwner();
            if (!self.running) return error.Closing;
            const id = self.operations.reserve() catch |err| {
                if (err == error.Capacity) self.counters.capacity_rejections +|= 1;
                return err;
            };
            self.operations.slots[id.index].state = .submitted;
            self.operations.requests[id.index] = .{ .id = id, .handle = t.invalid_handle, .native = t.invalid_native, .kind = .timer, .options = .{ .tag = tag, .deadline = deadline } };
            self.deadlines.add(id.index, deadline);
            self.counters.submissions +|= 1;
            return id;
        }

        pub fn sleepFor(self: *Self, duration: u64, tag: usize) Error!t.OpId {
            const deadline = @addWithOverflow(self.now(), duration);
            if (deadline[1] != 0) return error.SizeOverflow;
            return self.sleepUntil(deadline[0], tag);
        }

        /// Ownership transfers only after the backend attachment succeeds.
        pub fn adopt(self: *Self, native: usize, kind: t.ResourceKind, connected: bool) Error!t.Handle {
            try self.checkOwner();
            if (!self.running) return error.Closing;
            const handle = try self.reserveResource();
            errdefer self.resources.release(handle.index);
            try self.backend.attach(handle, native, kind);
            const slot = &self.resources.slots[handle.index];
            slot.state = .open;
            slot.native = native;
            slot.kind = kind;
            slot.connection = if (connected) .connected else .unconnected;
            return handle;
        }

        /// Create an unconnected TCP endpoint and transfer ownership to this Loop.
        pub fn openTcp(self: *Self, family: t.Address.Family) Error!t.Handle {
            return self.createSocket(.tcp, family, null, 0);
        }

        /// Bind a listener; port zero requests an ephemeral port.
        pub fn listen(self: *Self, address: t.Address, backlog: u32) Error!t.Handle {
            return self.createSocket(.listener, address.family, address, backlog);
        }

        /// Create a bound UDP endpoint.
        pub fn bindUdp(self: *Self, address: t.Address) Error!t.Handle {
            return self.createSocket(.udp, address.family, address, 0);
        }

        fn createSocket(self: *Self, kind: t.ResourceKind, family: t.Address.Family, address: ?t.Address, backlog: u32) Error!t.Handle {
            try self.checkOwner();
            if (!self.running) return error.Closing;
            const handle = try self.reserveResource();
            errdefer self.resources.release(handle.index);
            const native = try Backend.socket(kind, family, address, backlog);
            errdefer _ = Backend.closeNative(native, kind);
            try self.backend.attach(handle, native, kind);
            const slot = &self.resources.slots[handle.index];
            slot.state = .open;
            slot.native = native;
            slot.kind = kind;
            return handle;
        }

        /// File opening is a setup operation; payload reads/writes are asynchronous.
        pub fn openFile(self: *Self, path: []const u8, create: bool, writable: bool) Error!t.Handle {
            try self.checkOwner();
            if (!self.running) return error.Closing;
            const handle = try self.reserveResource();
            errdefer self.resources.release(handle.index);
            const native = try self.backend.openFile(path, create, writable);
            errdefer _ = Backend.closeNative(native, .file);
            try self.backend.attach(handle, native, .file);
            self.resources.slots[handle.index].state = .open;
            self.resources.slots[handle.index].kind = .file;
            self.resources.slots[handle.index].native = native;
            return handle;
        }

        /// Borrow the path until completion; the backend uses native I/O or a worker.
        pub fn openFileAsync(self: *Self, path: []const u8, file_options: t.FileOpenOptions, options: t.SubmitOptions) Error!t.OpId {
            try self.checkOwner();
            if (!self.running) return error.Closing;
            if (path.len == 0 or file_options.permissions > 0o7777) return error.InvalidOptions;
            if (path.len >= self.path_capacity) return error.Capacity;
            for (path) |byte| if (byte == 0) return error.InvalidOptions;
            if (file_options.access == .read and (file_options.creation == .create_always or file_options.creation == .truncate_existing)) return error.InvalidOptions;
            const handle = try self.reserveResource();
            errdefer self.resources.release(handle.index);
            const id = self.operations.reserve() catch |err| {
                if (err == error.Capacity) self.counters.capacity_rejections +|= 1;
                return err;
            };

            const resource = &self.resources.slots[handle.index];
            resource.state = .opening;
            resource.kind = .file;
            self.operations.requests[id.index] = .{ .id = id, .handle = handle, .native = t.invalid_native, .kind = .open, .options = options, .path = path, .file_options = file_options };
            self.retainResource(handle.index, id.index);
            if (options.deadline) |deadline| self.deadlines.add(id.index, deadline);
            if (!self.submitted.push(id.index)) @panic("open submission reservation lost");
            self.counters.submissions +|= 1;
            return id;
        }

        pub fn localAddress(self: *Self, handle: t.Handle) Error!t.Address {
            try self.checkOwner();
            const resource = try self.resources.get(handle);
            if (resource.state != .open) return error.Closing;
            if (resource.kind == .file) return error.InvalidResource;
            return Backend.localAddress(resource.native);
        }

        /// Disable or enable Nagle's algorithm on a TCP endpoint.
        pub fn noDelay(self: *Self, handle: t.Handle, enabled: bool) Error!void {
            try self.checkOwner();
            const resource = try self.resources.get(handle);
            if (resource.state != .open) return error.Closing;
            if (resource.kind != .tcp) return error.InvalidResource;
            try Backend.noDelay(resource.native, enabled);
        }

        pub fn socketOption(self: *Self, handle: t.Handle, option: @import("net/options.zig").Option, value: i32) Error!void {
            try self.checkOwner();
            const resource = try self.resources.get(handle);
            if (resource.state != .open) return error.Closing;
            if (resource.kind == .file) return error.InvalidResource;
            try @import("net/options.zig").set(resource.native, option, value);
        }

        pub fn getSocketOption(self: *Self, handle: t.Handle, option: @import("net/options.zig").Option) Error!i32 {
            try self.checkOwner();
            const resource = try self.resources.get(handle);
            if (resource.state != .open) return error.Closing;
            if (resource.kind == .file) return error.InvalidResource;
            return @import("net/options.zig").get(resource.native, option);
        }

        pub fn shutdownSocket(self: *Self, handle: t.Handle, how: @import("net/options.zig").Shutdown) Error!void {
            try self.checkOwner();
            const resource = try self.resources.get(handle);
            if (resource.state != .open) return error.Closing;
            if (resource.kind != .tcp or resource.connection != .connected) return error.InvalidResource;
            try @import("net/options.zig").shutdown(resource.native, how);
        }

        /// Configure options on openTcp() before binding and listening.
        pub fn listenOn(self: *Self, handle: t.Handle, address: t.Address, backlog: u32) Error!void {
            try self.checkOwner();
            const resource = try self.resources.get(handle);
            if (resource.state != .open) return error.Closing;
            if (resource.kind != .tcp or resource.connection != .unconnected or resource.references != 0) return error.InvalidResource;
            if (backlog > 0x7fffffff) return error.InvalidOptions;
            try @import("net/options.zig").listen(resource.native, address, backlog);
            resource.kind = .listener;
        }

        /// Reserve the child resource before submitting the accept.
        pub fn accept(self: *Self, handle: t.Handle, options: t.SubmitOptions) Error!t.OpId {
            return self.submit(handle, .accept, &.{}, &.{}, 0, .{}, false, options);
        }

        /// Connect once; failed or canceled endpoints must be closed.
        pub fn connect(self: *Self, handle: t.Handle, address: t.Address, options: t.SubmitOptions) Error!t.OpId {
            return self.submit(handle, .connect, &.{}, &.{}, 0, address, false, options);
        }

        /// Receive once; the buffer stays borrowed until completion delivery.
        pub fn recv(self: *Self, handle: t.Handle, buffer: []u8, options: t.SubmitOptions) Error!t.OpId {
            return self.submit(handle, .recv, buffer, &.{}, 0, .{}, false, options);
        }

        /// Fill the buffer or report terminal status with partial progress.
        pub fn recvExact(self: *Self, handle: t.Handle, buffer: []u8, options: t.SubmitOptions) Error!t.OpId {
            return self.submit(handle, .recv, buffer, &.{}, 0, .{}, true, options);
        }

        /// Send once; a short successful send is reported as-is.
        pub fn send(self: *Self, handle: t.Handle, bytes: []const u8, options: t.SubmitOptions) Error!t.OpId {
            return self.submit(handle, .send, &.{}, bytes, 0, .{}, false, options);
        }

        /// Resubmit retired partial sends until the whole slice is transferred.
        pub fn sendAll(self: *Self, handle: t.Handle, bytes: []const u8, options: t.SubmitOptions) Error!t.OpId {
            return self.submit(handle, .send, &.{}, bytes, 0, .{}, true, options);
        }

        /// Receive one datagram, preserving empty payloads and truncation.
        pub fn recvFrom(self: *Self, handle: t.Handle, buffer: []u8, options: t.SubmitOptions) Error!t.OpId {
            return self.submit(handle, .recv_from, buffer, &.{}, 0, .{}, false, options);
        }

        pub fn sendTo(self: *Self, handle: t.Handle, bytes: []const u8, address: t.Address, options: t.SubmitOptions) Error!t.OpId {
            return self.submit(handle, .send_to, &.{}, bytes, 0, address, false, options);
        }

        /// Read once at an explicit offset; concurrent file operations do not share a cursor.
        pub fn readAt(self: *Self, handle: t.Handle, buffer: []u8, offset: u64, options: t.SubmitOptions) Error!t.OpId {
            return self.submit(handle, .read, buffer, &.{}, offset, .{}, false, options);
        }

        pub fn readExactAt(self: *Self, handle: t.Handle, buffer: []u8, offset: u64, options: t.SubmitOptions) Error!t.OpId {
            return self.submit(handle, .read, buffer, &.{}, offset, .{}, true, options);
        }

        /// Write once at an explicit offset.
        pub fn writeAt(self: *Self, handle: t.Handle, bytes: []const u8, offset: u64, options: t.SubmitOptions) Error!t.OpId {
            return self.submit(handle, .write, &.{}, bytes, offset, .{}, false, options);
        }

        pub fn writeAllAt(self: *Self, handle: t.Handle, bytes: []const u8, offset: u64, options: t.SubmitOptions) Error!t.OpId {
            return self.submit(handle, .write, &.{}, bytes, offset, .{}, true, options);
        }

        /// Flush file data; await earlier writes before submitting the durability barrier.
        pub fn sync(self: *Self, handle: t.Handle, options: t.SubmitOptions) Error!t.OpId {
            return self.submit(handle, .sync, &.{}, &.{}, 0, .{}, false, options);
        }

        /// Query metadata without blocking the owner thread.
        pub fn stat(self: *Self, handle: t.Handle, options: t.SubmitOptions) Error!t.OpId {
            return self.submit(handle, .stat, &.{}, &.{}, 0, .{}, false, options);
        }

        /// Submit blocking work without occupying the owner thread.
        pub fn work(self: *Self, task: t.Work, options: t.SubmitOptions) Error!t.OpId {
            return self.submitWork(null, task, options);
        }

        /// Pin a file until the callback has retired, including during cancellation.
        pub fn workOn(self: *Self, handle: t.Handle, task: t.Work, options: t.SubmitOptions) Error!t.OpId {
            return self.submitWork(handle, task, options);
        }

        fn submitWork(self: *Self, handle: ?t.Handle, task: t.Work, options: t.SubmitOptions) Error!t.OpId {
            try self.checkOwner();
            if (!self.running) return error.Closing;
            var native = t.invalid_native;
            if (handle) |key| {
                const resource = try self.resources.get(key);
                if (resource.state != .open) return error.Closing;
                if (resource.kind != .file) return error.InvalidResource;
                native = resource.native;
            }
            const id = self.operations.reserve() catch |err| {
                if (err == error.Capacity) self.counters.capacity_rejections +|= 1;
                return err;
            };
            self.operations.requests[id.index] = .{ .id = id, .handle = handle orelse t.invalid_handle, .native = native, .kind = .work, .options = options, .work = task };
            if (handle) |key| self.retainResource(key.index, id.index);
            if (options.deadline) |deadline| self.deadlines.add(id.index, deadline);
            if (!self.submitted.push(id.index)) @panic("work submission reservation lost");
            self.counters.submissions +|= 1;
            return id;
        }

        // Public entry points fix the kind, so validation branches specialize at compile time.
        fn submit(self: *Self, handle: t.Handle, comptime kind: t.Kind, read_buffer: []u8, write_buffer: []const u8, offset: u64, address: t.Address, full: bool, options: t.SubmitOptions) Error!t.OpId {
            try self.checkOwner();
            if (!self.running) return error.Closing;
            const resource = try self.resources.get(handle);
            if (resource.state != .open) return error.Closing;
            const reading = switch (kind) {
                .accept, .recv, .recv_from, .read => true,
                else => false,
            };
            switch (kind) {
                .accept => if (resource.kind != .listener) return error.InvalidResource,
                .connect => {
                    if (resource.kind != .tcp) return error.InvalidResource;
                    if (resource.connection != .unconnected) return error.InvalidState;
                },
                .recv, .send => {
                    if (resource.kind != .tcp) return error.InvalidResource;
                    if (resource.connection != .connected) return error.InvalidState;
                },
                .recv_from, .send_to => if (resource.kind != .udp) return error.InvalidResource,
                .read, .write, .sync, .stat => {
                    if (resource.kind != .file) return error.InvalidResource;
                    const length = @max(read_buffer.len, write_buffer.len);
                    if (offset > 0x7fffffffffffffff or (length != 0 and length - 1 > 0x7fffffffffffffff - offset)) return error.InvalidOptions;
                },
                .open, .timer, .close, .work => unreachable,
            }
            if (resource.kind != .file) {
                if (reading and resource.read_op != t.none) return error.DirectionBusy;
                if (!reading and resource.write_op != t.none) return error.DirectionBusy;
                if (kind == .connect and resource.read_op != t.none) return error.DirectionBusy;
            }
            const id = self.operations.reserve() catch |err| {
                if (err == error.Capacity) self.counters.capacity_rejections +|= 1;
                return err;
            };
            errdefer self.operations.release(id.index);
            if (kind == .accept) {
                // Reserve the accepted handle before admitting any native work.
                const child = try self.reserveResource();
                self.operations.slots[id.index].child = child.index;
            }
            self.operations.requests[id.index] = .{
                .id = id,
                .handle = handle,
                .native = resource.native,
                .kind = kind,
                .options = options,
                .read_buffer = read_buffer,
                .write_buffer = write_buffer,
                .offset = offset,
                .address = address,
                .full = full,
            };
            if (resource.kind != .file) {
                if (reading) resource.read_op = id.index else resource.write_op = id.index;
            }
            self.retainResource(handle.index, id.index);
            if (kind == .connect) resource.connection = .connecting;
            if (options.deadline) |deadline| self.deadlines.add(id.index, deadline);
            if (!self.submitted.push(id.index)) @panic("submission reservation lost");
            self.counters.submissions +|= 1;
            return id;
        }

        /// Request cancellation; an already queued terminal result remains unchanged.
        pub fn cancel(self: *Self, id: t.OpId) Error!t.CancelResult {
            try self.checkOwner();
            return self.requestCancel(id, .canceled);
        }

        fn requestCancel(self: *Self, id: t.OpId, reason: t.Status) Error!t.CancelResult {
            const slot = try self.operations.get(id);
            if (slot.state == .completed) return .already_completed;
            // The first cancel/deadline reason wins over a later native outcome.
            if (slot.reason != null) return .requested;
            slot.reason = reason;
            self.deadlines.remove(id.index);
            if (slot.state == .queued or self.operations.requests[id.index].kind == .timer) {
                self.finish(.{ .id = id, .status = reason });
            } else if (slot.state != .retiring) {
                // Cancellation is terminal only after the backend retires buffer access.
                self.backend.cancel(id);
            }
            return .requested;
        }

        fn tick(self: *Self, current_time: u64) void {
            while (self.deadlines.peek()) |entry| {
                if (entry.deadline > current_time) break;
                const id = self.operations.requests[entry.index].id;
                if (self.operations.requests[entry.index].kind == .timer)
                    self.finish(.{ .id = id })
                else
                    _ = self.requestCancel(id, .timed_out) catch unreachable;
            }
        }

        /// stop() rejects new work while keeping control and completion paths live.
        pub fn stop(self: *Self) Error!void {
            try self.checkOwner();
            self.running = false;
        }

        /// Seal posts, reject new I/O and cancel resources, pending opens and timers.
        pub fn shutdown(self: *Self) Error!void {
            try self.stop();
            self.inbox.seal();
            var close_error: ?Error = null;
            // Attempt every resource even when a close must be retried by later pumps.
            for (self.resources.slots, 0..) |*resource, index| {
                if (resource.state == .open or resource.state == .closing) {
                    self.close(self.resources.handle(@intCast(index)), .cancel, 0) catch |err| {
                        close_error = err;
                    };
                }
            }
            for (self.operations.slots, 0..) |slot, index| {
                if ((slot.state == .queued or slot.state == .submitted) and (self.operations.requests[index].kind == .timer or self.operations.requests[index].kind == .open or self.operations.requests[index].kind == .work))
                    _ = try self.requestCancel(self.operations.requests[index].id, .canceled);
            }
            if (close_error) |err| return err;
        }

        /// Close after dependent I/O retires; capacity is reserved with the resource.
        pub fn close(self: *Self, handle: t.Handle, mode: t.CloseMode, tag: usize) Error!void {
            try self.checkOwner();
            const resource = try self.resources.get(handle);
            if (resource.state == .closed) return;
            if (resource.state == .reserved or resource.state == .opening) return error.InvalidState;
            if (resource.state == .open) {
                resource.state = .closing;
                resource.close_tag = tag;
            }
            if (mode == .cancel) {
                // Walk only this resource's active operations, saving the next link first.
                var index = resource.operation_head;
                while (index != t.none) {
                    const next = self.operations.slots[index].resource_next;
                    _ = try self.requestCancel(self.operations.requests[index].id, .canceled);
                    index = next;
                }
            }
            if (resource.references == 0) try self.finishClose(handle.index);
        }

        fn finishClose(self: *Self, index: u32) Error!void {
            const resource = &self.resources.slots[index];
            if (resource.state != .closing) return;
            if (resource.close_submitted) return;
            if (resource.retry_queued) return error.NativeFailure;
            const result = self.backend.detach(self.resources.handle(index), resource.native, resource.kind);
            if (result.pending) {
                resource.close_submitted = true;
                return;
            }
            if (!result.closed) {
                self.retryClose(index, result.native_error);
                return error.NativeFailure;
            }
            self.completeClose(index, result.native_error);
        }

        fn completeClose(self: *Self, index: u32, native_error: i32) void {
            const resource = &self.resources.slots[index];
            if (native_error != 0) {
                self.counters.close_failures +|= 1;
                self.counters.last_close_error = native_error;
            }
            resource.close_error = native_error;
            resource.native = t.invalid_native;
            resource.state = .closed;
            if (resource.opening_operation != t.none) {
                // A canceled or failed open still owns its hidden handle until close retires.
                const operation_index = resource.opening_operation;
                const slot = &self.operations.slots[operation_index];
                const result = &self.operations.results[operation_index];
                result.status = slot.reason orelse result.status;
                if (result.native_error == 0) result.native_error = native_error;
                slot.state = .completed;
                self.resources.release(index);
                self.accountOutcome(result.status);
                self.enqueue(operation_index);
                return;
            }
            // The resource's reserved completion slot makes close independent of capacity.
            self.enqueue(close_bit | index);
        }

        fn retryClose(self: *Self, index: u32, native_error: i32) void {
            const resource = &self.resources.slots[index];
            self.counters.close_failures +|= 1;
            self.counters.last_close_error = native_error;
            if (resource.retry_queued) return;
            resource.retry_queued = true;
            resource.retry_at = self.now() +| 1_000_000;
            resource.next = t.none;
            if (self.retry_tail != t.none) self.resources.slots[self.retry_tail].next = index else self.retry_head = index;
            self.retry_tail = index;
            self.retry_count += 1;
        }

        fn retryCloses(self: *Self, current_time: u64) void {
            // A retry may append itself again; bound this pass to the original queue size.
            const count = self.retry_count;
            for (0..count) |_| {
                if (self.retry_head == t.none) break;
                const index = self.retry_head;
                const resource = &self.resources.slots[index];
                if (resource.retry_at > current_time) break;
                self.retry_head = resource.next;
                if (self.retry_head == t.none) self.retry_tail = t.none;
                self.retry_count -= 1;
                resource.retry_queued = false;
                resource.next = t.none;
                self.counters.close_retries +|= 1;
                self.finishClose(index) catch {};
            }
        }

        fn enqueue(self: *Self, index: u64) void {
            if (!self.completed.push(index)) @panic("completion reservation lost");
            self.completion_high_water = @max(self.completion_high_water, self.completed.count);
        }

        // Native events retire buffer access; public result consumption releases the slot.
        fn finish(self: *Self, event: common.Event) void {
            if (event.closed_handle) |handle| {
                const resource = self.resources.get(handle) catch return;
                if (resource.state != .closing or !resource.close_submitted) return;
                resource.close_submitted = false;
                if (event.close_released) self.completeClose(handle.index, event.native_error) else self.retryClose(handle.index, event.native_error);
                return;
            }
            const slot = self.operations.get(event.id) catch return;
            if (slot.state == .completed) return;
            const request = &self.operations.requests[event.id.index];
            self.deadlines.remove(event.id.index);
            slot.progress += event.bytes;
            const status = slot.reason orelse event.status;
            // A full transfer reuses its slot only after the native request has retired.
            const remaining = @max(request.read_buffer.len, request.write_buffer.len);
            if (request.kind != .work and event.bytes > remaining) @panic("backend returned an invalid transfer length");
            if (slot.reason == null and event.status == .ok and request.full and event.bytes != 0 and event.bytes < remaining) {
                if (request.read_buffer.len != 0) request.read_buffer = request.read_buffer[event.bytes..];
                if (request.write_buffer.len != 0) request.write_buffer = request.write_buffer[event.bytes..];
                if (request.kind == .read or request.kind == .write) request.offset += event.bytes;
                slot.state = .queued;
                if (request.options.deadline) |deadline| self.deadlines.add(event.id.index, deadline);
                if (!self.submitted.push(event.id.index)) @panic("compound submission reservation lost");
                self.accountBytes(request.kind, event.bytes);
                return;
            }
            var result: t.Completion = .{
                .id = event.id,
                .handle = request.handle,
                .kind = request.kind,
                .status = status,
                .tag = request.options.tag,
                .bytes = slot.progress,
                .native_error = event.native_error,
                .library_error = event.library_error,
                .file_info = event.file_info,
                .truncated = event.truncated,
                .peer = event.peer,
            };
            if (slot.child != t.none) {
                const child = slot.child;
                if (status == .ok and event.accepted_native != t.invalid_native) {
                    const handle = self.resources.handle(child);
                    if (self.backend.attach(handle, event.accepted_native, .tcp)) |_| {
                        const resource = &self.resources.slots[child];
                        resource.state = .open;
                        resource.kind = .tcp;
                        resource.native = event.accepted_native;
                        resource.connection = .connected;
                        result.accepted = handle;
                    } else |err| {
                        _ = Backend.closeNative(event.accepted_native, .tcp);
                        self.resources.release(child);
                        result.status = .failed;
                        result.library_error = err;
                    }
                } else {
                    if (event.accepted_native != t.invalid_native) _ = Backend.closeNative(event.accepted_native, .tcp);
                    self.resources.release(child);
                }
                slot.child = t.none;
            }
            if (request.kind == .open) {
                if (status == .ok and event.accepted_native != t.invalid_native) {
                    if (self.backend.attach(request.handle, event.accepted_native, .file)) |_| {
                        const resource = &self.resources.slots[request.handle.index];
                        resource.state = .open;
                        resource.native = event.accepted_native;
                        result.opened = request.handle;
                    } else |err| {
                        result.status = .failed;
                        result.library_error = err;
                    }
                }
                if (result.opened == null and event.accepted_native != t.invalid_native) {
                    // Hide an unwanted descriptor until its asynchronous close also retires.
                    const resource = &self.resources.slots[request.handle.index];
                    resource.native = event.accepted_native;
                    resource.state = .closing;
                    resource.opening_operation = event.id.index;
                    self.operations.results[event.id.index] = result;
                    slot.state = .retiring;
                    self.releaseResource(request.handle.index, event.id.index);
                    self.finishClose(request.handle.index) catch {};
                    return;
                }
            }
            if (request.full and status == .ok and remaining != 0 and event.bytes == 0) {
                result.status = .failed;
                result.library_error = error.NoProgress;
            }
            self.operations.results[event.id.index] = result;
            slot.state = .completed;
            if (request.handle.index != t.none) {
                const resource = &self.resources.slots[request.handle.index];
                self.releaseResource(request.handle.index, event.id.index);
                if (resource.read_op == event.id.index) resource.read_op = t.none;
                if (resource.write_op == event.id.index) resource.write_op = t.none;
                if (request.kind == .connect) resource.connection = if (result.status == .ok) .connected else .failed;
            }
            self.accountOutcome(result.status);
            self.accountBytes(request.kind, event.bytes);
            self.enqueue(event.id.index);
            // Queue dependent results before the close result for this resource.
            if (request.handle.index != t.none) {
                const resource = &self.resources.slots[request.handle.index];
                if (request.kind == .open and result.opened == null)
                    self.resources.release(request.handle.index)
                else if (resource.state == .closing and resource.references == 0)
                    self.finishClose(request.handle.index) catch {};
            }
        }

        fn accountOutcome(self: *Self, status: t.Status) void {
            self.counters.completed +|= 1;
            switch (status) {
                .canceled => self.counters.canceled +|= 1,
                .timed_out => self.counters.timed_out +|= 1,
                .failed => self.counters.failed +|= 1,
                else => {},
            }
        }

        fn accountBytes(self: *Self, kind: t.Kind, count: usize) void {
            switch (kind) {
                .recv, .recv_from, .read => self.counters.bytes_read +|= count,
                .send, .send_to, .write => self.counters.bytes_written +|= count,
                else => {},
            }
        }

        /// Advance a bounded submission batch, completions, deadlines and close retries.
        pub fn pump(self: *Self, wait: t.Wait) Error!void {
            try self.checkOwner();
            const inbox_progress = self.drainInbox();
            // Only scheduled work needs a fresh timestamp before submissions.
            if (self.deadlines.peek() != null or self.retry_head != t.none) {
                self.tick(self.clock.sample());
                self.retryCloses(self.cachedNow());
            }
            const batch_count = self.submitted.count;
            // Bound each submission batch so completions and timers remain responsive.
            for (0..batch_count) |_| {
                const index = self.submitted.pop().?;
                const slot = &self.operations.slots[index];
                // Canceling queued work may leave its index in this submission batch.
                if (slot.state != .queued) continue;
                const request = &self.operations.requests[index];
                const empty = switch (request.kind) {
                    .read, .recv => request.read_buffer.len == 0,
                    .write, .send => request.write_buffer.len == 0,
                    else => false,
                };
                if (empty) {
                    self.finish(.{ .id = request.id });
                    continue;
                }
                slot.state = .submitted;
                self.backend.submit(request) catch |err| {
                    self.finish(.{ .id = request.id, .status = .failed, .native_error = self.backend.last_error, .library_error = err });
                };
            }
            const timed_wait = switch (wait) {
                .until => true,
                else => false,
            };
            const immediate = self.completed.count != 0 or self.submitted.count != 0 or inbox_progress;

            // Only a potentially blocking absolute wait needs a pre-wait timestamp.
            // Scheduled work still needs fresh time even when completions are queued.
            const current_time = if ((timed_wait and !immediate) or self.deadlines.peek() != null or self.retry_head != t.none)
                self.clock.sample()
            else
                self.cachedNow();
            self.tick(current_time);
            var duration: ?u64 = switch (wait) {
                .none => 0,
                .forever => null,
                .until => |deadline| deadline -| current_time,
            };
            if (self.deadlines.peek()) |entry| {
                const delay = entry.deadline -| current_time;
                duration = if (duration) |current| @min(current, delay) else delay;
            }
            if (self.retry_head != t.none) {
                const delay = self.resources.slots[self.retry_head].retry_at -| current_time;
                duration = if (duration) |current| @min(current, delay) else delay;
            }
            if (immediate or self.completed.count != 0 or self.submitted.count != 0) duration = 0;
            // Rearm notifications only before a potentially blocking wait.
            if ((duration == null or duration.? != 0) and self.inbox.prepareWait()) duration = 0;
            const count = try self.backend.poll(self.events, duration);
            for (self.events[0..count]) |event| {
                if (!event.wake) self.finish(event);
            }
            // Refresh cachedNow even when there were no timers or no blocking wait.
            self.tick(self.clock.sample());
        }

        /// Consuming a completion recycles its already-retired operation record.
        pub fn poll(self: *Self, output: []t.Completion, wait: t.Wait) Error!usize {
            try self.pump(wait);
            var count: usize = 0;
            while (count < output.len) {
                const node = self.completed.pop() orelse break;
                if (node & close_bit != 0) {
                    const index: u32 = @intCast(node & ~close_bit);
                    const resource = &self.resources.slots[index];
                    output[count] = .{
                        .id = null,
                        .handle = self.resources.handle(index),
                        .kind = .close,
                        .status = if (resource.close_error == 0) .ok else .failed,
                        .tag = resource.close_tag,
                        .native_error = resource.close_error,
                    };
                    // Keep the generation alive until the close result reaches its caller.
                    self.resources.release(index);
                } else {
                    const index: u32 = @intCast(node);
                    output[count] = self.operations.results[index];
                    self.operations.release(index);
                }
                count += 1;
            }
            return count;
        }
    };
}
