//! Independent owner Loops with bounded cross-thread task admission.

const t = @import("../types.zig");
const Error = @import("../error.zig").Error;
const mem = @import("../mem/allocator.zig");
const Shared = @import("../mem/shared_tracking.zig");
const MemoryStats = @import("../mem/tracking.zig").Stats;
const Layout = @import("../mem/layout.zig").Layout;
const Arena = @import("../mem/arena.zig");
const Thread = @import("../sync/thread.zig");
const Mutex = @import("../sync/mutex.zig");
const Condition = @import("../sync/condition.zig");
const cpu = @import("cpu.zig");
const os = @import("../os/root.zig");

// The high bit closes admission; low bits pin producers until their native wake returns.
const closed_bit = @as(usize, 1) << (@bitSizeOf(usize) - 1);

/// Keep the Runtime stable until owners and external producers have finished.
pub fn Runtime(comptime Backend: type) type {
    return struct {
        const Self = @This();
        pub const Loop = @import("../loop.zig").Loop(Backend);

        pub const Options = struct {
            /// Zero selects the detected logical CPU count; no CPU affinity is installed.
            threads: u32 = 0,
            queue_capacity: u32 = 256,
            completion_batch: u32 = 64,
            /// Blocking workers are opt-in to avoid multiplying them by the CPU count.
            loop: t.Options = .{ .file_threads = 0, .inbox = 0 },
        };

        /// The callback runs once on its selected owner; context stays borrowed until return.
        pub const Task = struct {
            context: ?*anyopaque = null,
            run: *const fn (?*anyopaque, *Worker) void,
        };

        /// Hooks are serial per owner and may run concurrently on different owners.
        pub const Hooks = struct {
            context: ?*anyopaque = null,
            start: ?*const fn (?*anyopaque, *Worker) Error!void = null,
            /// Dispatch these terminal results before returning; the slice is reused.
            complete: *const fn (?*anyopaque, *Worker, []const t.Completion) void,
            /// Runs after admitted tasks, before Loop shutdown. Release external blockers here.
            stop: ?*const fn (?*anyopaque, *Worker) void = null,
        };

        pub const Stage = enum { launch, initialize, start, application, poll, shutdown, deinit };

        pub const Failure = struct { worker: usize, stage: Stage, cause: Error };

        pub const Stats = struct {
            threads: usize,
            threads_started: usize,
            threads_exited: usize,
            tasks_posted: u64,
            tasks_executed: u64,
            completions: u64,
            failures: u64,
            memory: MemoryStats,
        };

        const Inbox = @import("../core/inbox.zig").Inbox(Task);

        pub const Worker = struct {
            index: usize,
            pool: *Self,
            owner_loop: Loop = undefined,
            queue: Inbox = .{},
            output: []t.Completion,

            thread: Thread = .{},
            wake_mutex: Mutex = .{},
            wake_live: bool = false,
            init_error: ?Error = null,

            executed: u64 align(64) = 0,
            delivered: u64 = 0,
            exited: u32 = 0,

            /// Owner-only access. Handles and operation IDs never move between Loops.
            pub fn loop(self: *Worker) *Loop {
                return &self.owner_loop;
            }

            pub fn runtime(self: *Worker) *Self {
                return self.pool;
            }

            /// Record an application failure and request shutdown of every owner.
            pub fn fail(self: *Worker, cause: Error) void {
                self.pool.recordFailure(.{ .worker = self.index, .stage = .application, .cause = cause });
                self.pool.shutdown();
            }

            fn wake(self: *Worker) void {
                // Runtime admission keeps the backend alive through this notification.
                self.owner_loop.backend.wake();
            }

            fn wakeLive(self: *Worker) void {
                self.wake_mutex.lock();
                defer self.wake_mutex.unlock();
                if (self.wake_live) self.wake();
            }

            fn entry(context: *anyopaque) void {
                const self: *Worker = @ptrCast(@alignCast(context));
                self.run();
                @atomicStore(u32, &self.exited, 1, .release);
            }

            fn run(self: *Worker) void {
                const pool = self.pool;
                self.owner_loop.init(pool.shared.allocator(), pool.options.loop) catch |err| {
                    self.init_error = err;
                };
                if (self.init_error == null) {
                    self.wake_mutex.lock();
                    self.wake_live = true;
                    self.wake_mutex.unlock();
                }
                // No application callback runs until every native Loop is initialized.
                pool.control.lock();
                pool.ready += 1;
                pool.condition.broadcast();
                while (!pool.released) pool.condition.wait(&pool.control);
                const abort = pool.abort_start;
                pool.control.unlock();
                if (self.init_error != null) return;
                defer {
                    // Shutdown requests cannot wake a backend concurrently with its destruction.
                    self.wake_mutex.lock();
                    self.wake_live = false;
                    self.owner_loop.deinit() catch |err|
                        pool.recordFailure(.{ .worker = self.index, .stage = .deinit, .cause = err });
                    self.wake_mutex.unlock();
                }
                if (abort) return;
                if (pool.hooks.start) |callback| callback(pool.hooks.context, self) catch |err| {
                    pool.recordFailure(.{ .worker = self.index, .stage = .start, .cause = err });
                    pool.shutdown();
                };

                var stopping = false;
                while (true) {
                    var progressed = false;
                    // Bound tasks as well as completions so neither starves native I/O.
                    for (0..pool.options.completion_batch) |_| {
                        const task = self.queue.pop() orelse break;
                        task.run(task.context, self);
                        // A single writer needs no RMW; concurrent snapshots still read atomically.
                        // Publish after each callback so callback-visible stats keep their meaning.
                        const executed = @atomicLoad(u64, &self.executed, .monotonic);
                        @atomicStore(u64, &self.executed, executed +% 1, .monotonic);
                        progressed = true;
                    }
                    const gate = @atomicLoad(usize, &pool.gate, .acquire);
                    const closing = gate & closed_bit != 0;
                    // Sealing admission does not discard accepted tasks or cancel producers mid-post.
                    if (closing and gate & ~closed_bit == 0 and self.queue.quiescent() and !stopping) {
                        self.queue.seal();
                        if (pool.hooks.stop) |callback| callback(pool.hooks.context, self);
                        self.owner_loop.shutdown() catch |err|
                            pool.recordFailure(.{ .worker = self.index, .stage = .shutdown, .cause = err });
                        stopping = true;
                    }
                    if (stopping) {
                        // Empty queues alone do not prove the OS has released borrowed buffers.
                        const snapshot = self.owner_loop.stats();
                        if (snapshot.active_operations == 0 and snapshot.active_resources == 0 and snapshot.completions_queued == 0 and self.owner_loop.inbox.quiescent()) break;
                    }
                    // Skip the notification RMW when this poll cannot block. Before sleeping,
                    // prepareWait clears and rechecks the queue so racing posts cannot lose a wakeup.
                    const wait: t.Wait = if (progressed or (closing and !stopping) or self.queue.prepareWait()) .none else .forever;
                    const count = self.owner_loop.poll(self.output, wait) catch |err| {
                        pool.recordFailure(.{ .worker = self.index, .stage = .poll, .cause = err });
                        pool.shutdown();
                        Thread.yield();
                        continue;
                    };
                    if (count != 0) {
                        pool.hooks.complete(pool.hooks.context, self, self.output[0..count]);
                        // The same single-writer rule applies; publish only after the callback returns.
                        const delivered = @atomicLoad(u64, &self.delivered, .monotonic);
                        @atomicStore(u64, &self.delivered, delivered +% count, .monotonic);
                    }
                }
            }
        };

        // Allocation is serialized only during lifecycle work; I/O pools stay owner-local.
        shared: Shared = undefined,
        allocation: ?mem.Allocation = null,
        workers: []Worker = &.{},
        options: Options = .{},
        hooks: Hooks = undefined,

        // Protects the startup barrier and failure records, not owner-local I/O.
        control: Mutex = .{},
        condition: Condition = .{},
        owner: u64 = 0,

        gate: usize align(64) = closed_bit,
        next: usize align(64) = 0,

        ready: usize = 0,
        started: usize = 0,
        released: bool = false,
        abort_start: bool = false,
        state: enum { empty, ready, running, joined } = .empty,

        first_failure: ?Failure = null,
        failure_count: u64 = 0,

        pub fn cpuCount() Error!u32 {
            return cpu.count();
        }

        fn resolve(options: Options) Error!Options {
            var result = options;
            if (result.threads == 0) result.threads = try cpuCount();
            if (result.threads > 1024 or result.completion_batch == 0 or result.queue_capacity == 0 or result.queue_capacity & (result.queue_capacity - 1) != 0)
                return error.InvalidOptions;
            _ = try Loop.memoryRequired(result.loop);
            return result;
        }

        fn layout(options: Options) Error!usize {
            var result: Layout = .{};
            try result.add(Worker, options.threads);
            try result.add(Inbox.Cell, @as(usize, options.threads) * options.queue_capacity);
            try result.add(t.Completion, @as(usize, options.threads) * options.completion_batch);
            return result.size;
        }

        /// Control backing only. Each owner separately allocates Loop.memoryRequired(options.loop).
        pub fn memoryRequired(options: Options) Error!usize {
            return layout(try resolve(options));
        }

        /// Initialize in place. Management methods stay on this thread; posts are thread-safe.
        pub fn init(self: *Self, allocator: mem.Allocator, options: Options) Error!void {
            self.* = .{ .options = try resolve(options), .owner = os.threadId() };
            try self.shared.init(allocator);
            errdefer self.shared.deinit() catch unreachable;
            try self.control.init();
            errdefer self.control.deinit();
            try self.condition.init();
            errdefer self.condition.deinit();
            const allocation = try self.shared.allocator().allocate(try layout(self.options), 64);
            self.allocation = allocation;
            errdefer self.shared.allocator().release(allocation);
            var arena: Arena = .{ .bytes = allocation.bytes };
            self.workers = try arena.allocate(Worker, self.options.threads);
            const cells = try arena.allocate(Inbox.Cell, @as(usize, self.options.threads) * self.options.queue_capacity);
            const output = try arena.allocate(t.Completion, @as(usize, self.options.threads) * self.options.completion_batch);
            var initialized: usize = 0;
            errdefer for (self.workers[0..initialized]) |*worker| worker.wake_mutex.deinit();
            for (self.workers, 0..) |*worker, index| {
                worker.* = .{ .pool = self, .index = index, .output = output[index * self.options.completion_batch ..][0..self.options.completion_batch] };
                worker.queue.init(cells[index * self.options.queue_capacity ..][0..self.options.queue_capacity]);
                try worker.wake_mutex.init();
                initialized += 1;
            }
            self.state = .ready;
        }

        fn checkOwner(self: *Self) Error!void {
            if (self.owner != os.threadId()) return error.WrongThread;
            if (self.state == .empty) return error.InvalidState;
        }

        /// Returns after native initialization. Start hooks run asynchronously on their owners.
        pub fn start(self: *Self, hooks: Hooks) Error!void {
            try self.checkOwner();
            if (self.state != .ready) return error.InvalidState;
            self.hooks = hooks;
            var start_error: ?Error = null;
            for (self.workers) |*worker| {
                worker.thread.start(Worker.entry, worker) catch |err| {
                    start_error = err;
                    break;
                };
                self.started += 1;
            }
            self.control.lock();
            while (self.ready < self.started) self.condition.wait(&self.control);
            if (start_error) |err| {
                self.first_failure = .{ .worker = self.started, .stage = .launch, .cause = err };
                self.failure_count += 1;
            }
            for (self.workers[0..self.started]) |*worker| if (worker.init_error) |err| {
                if (start_error == null) start_error = err;
                if (self.first_failure == null) self.first_failure = .{ .worker = worker.index, .stage = .initialize, .cause = err };
                self.failure_count += 1;
            };
            self.abort_start = start_error != null;
            self.released = true;
            if (start_error == null) {
                self.state = .running;
                // Publish fully initialized queues/backends before allowing external producers.
                @atomicStore(usize, &self.gate, 0, .release);
            }
            self.condition.broadcast();
            self.control.unlock();
            if (start_error) |err| {
                for (self.workers[0..self.started]) |*worker| worker.thread.join();
                self.state = .joined;
                return err;
            }
        }

        fn enter(self: *Self) Error!void {
            var value = @atomicLoad(usize, &self.gate, .acquire);
            while (true) {
                if (value & closed_bit != 0) return error.Closing;
                if (@cmpxchgWeak(usize, &self.gate, value, value + 1, .acq_rel, .acquire)) |observed| value = observed else return;
            }
        }

        /// Tries queues in round-robin order. Success returns the selected owner index.
        pub fn post(self: *Self, task: Task) Error!usize {
            try self.enter();
            // The pin covers queue publication and wake, including failed admission attempts.
            defer _ = @atomicRmw(usize, &self.gate, .Sub, 1, .release);
            const first = @atomicRmw(usize, &self.next, .Add, 1, .monotonic) % self.workers.len;
            for (0..self.workers.len) |offset| {
                const index = (first + offset) % self.workers.len;
                const worker = &self.workers[index];
                worker.queue.post(task, worker, Worker.wake) catch |err| {
                    if (err == error.QueueFull) continue;
                    return err;
                };
                return index;
            }
            return error.QueueFull;
        }

        /// Explicit affinity for connections, sessions and owner-local application state.
        pub fn postTo(self: *Self, index: usize, task: Task) Error!void {
            try self.enter();
            defer _ = @atomicRmw(usize, &self.gate, .Sub, 1, .release);
            if (index >= self.workers.len) return error.InvalidOptions;
            const worker = &self.workers[index];
            try worker.queue.post(task, worker, Worker.wake);
        }

        /// Thread-safe and idempotent. Accepted tasks run before cancellation/drain.
        pub fn shutdown(self: *Self) void {
            _ = @atomicRmw(usize, &self.gate, .Or, closed_bit, .acq_rel);
            for (self.workers) |*worker| worker.wakeLive();
        }

        /// Wait for shutdown requested by the application. Does not force blocked work to return.
        pub fn join(self: *Self) Error!void {
            try self.checkOwner();
            if (self.state != .running and self.state != .joined) return error.InvalidState;
            if (self.state == .running) {
                for (self.workers[0..self.started]) |*worker| worker.thread.join();
                self.state = .joined;
            }
            if (self.failure()) |value| return value.cause;
        }

        fn recordFailure(self: *Self, value: Failure) void {
            self.control.lock();
            defer self.control.unlock();
            if (self.first_failure == null) self.first_failure = value;
            self.failure_count +|= 1;
        }

        /// First failure wins; native operation errors still belong to completion dispatch.
        pub fn failure(self: *Self) ?Failure {
            self.control.lock();
            defer self.control.unlock();
            return self.first_failure;
        }

        /// Safe during execution. Callers must stop using the Runtime before deinit.
        pub fn stats(self: *Self) Stats {
            // Separate atomic reads form a concurrent snapshot, not a global transaction.
            var result: Stats = .{ .threads = self.workers.len, .threads_started = 0, .threads_exited = 0, .tasks_posted = 0, .tasks_executed = 0, .completions = 0, .failures = 0, .memory = self.shared.stats() };
            for (self.workers) |*worker| {
                result.tasks_posted +|= @atomicLoad(u64, &worker.queue.posted, .monotonic);
                result.tasks_executed +|= @atomicLoad(u64, &worker.executed, .monotonic);
                result.completions +|= @atomicLoad(u64, &worker.delivered, .monotonic);
                result.threads_exited += @atomicLoad(u32, &worker.exited, .acquire);
            }
            self.control.lock();
            result.threads_started = self.ready;
            result.failures = self.failure_count;
            self.control.unlock();
            return result;
        }

        /// Management-only. Join producers and end concurrent Runtime calls before release.
        pub fn deinit(self: *Self) Error!void {
            try self.checkOwner();
            if (self.state == .running) return error.Busy;
            // A failed native retirement must never release storage still borrowed by the OS.
            if (self.shared.stats().live_bytes != self.allocation.?.requested) return error.Busy;
            for (self.workers) |*worker| worker.wake_mutex.deinit();
            self.shared.allocator().release(self.allocation.?);
            self.allocation = null;
            self.workers = &.{};
            self.condition.deinit();
            self.control.deinit();
            try self.shared.deinit();
            self.state = .empty;
        }
    };
}
