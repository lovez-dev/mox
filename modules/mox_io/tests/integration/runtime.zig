//! Native multi-owner admission, startup rollback and retirement tests.

const std = @import("std");
const mox_io = @import("mox_io");

const t = mox_io.types;
const testing = std.testing;

pub fn Suite(comptime Backend: type) type {
    return struct {
        const Runtime = mox_io.Runtime(Backend);
        const Worker = Runtime.Worker;
        const Loop = Runtime.Loop;

        fn prepare() !void {
            if (@import("builtin").os.tag == .linux and Backend == mox_io.backends.Uring)
                if (!try Backend.probe()) return error.SkipZigTest;
        }

        fn options(threads: u32) Runtime.Options {
            return .{ .threads = threads, .queue_capacity = 8, .completion_batch = 4, .loop = .{ .operations = 8, .resources = 4, .events = 4, .inbox = 0, .file_threads = 0 } };
        }

        fn ignored(_: ?*anyopaque, _: *Worker, _: []const t.Completion) void {}

        fn retire(runtime: *Runtime) void {
            runtime.shutdown();
            runtime.join() catch {};
            runtime.deinit() catch @panic("runtime test cleanup failed");
        }

        fn wait(flag: *u32) !void {
            const deadline = mox_io.os.now() + 5_000_000_000;
            while (@atomicLoad(u32, flag, .acquire) == 0) {
                if (mox_io.os.now() >= deadline) return error.RuntimeTestTimeout;
                mox_io.sync.Thread.yield();
            }
        }

        const Owners = struct {
            ids: [3]u64 = @splat(0),
            calls: [3]usize = @splat(0),
            stopped: [3]usize = @splat(0),
            results: [3]usize = @splat(0),
            wrong: [3]bool = @splat(false),

            fn start(context: ?*anyopaque, worker: *Worker) mox_io.Error!void {
                const self: *Owners = @ptrCast(@alignCast(context.?));
                self.ids[worker.index] = mox_io.os.threadId();
                _ = try worker.loop().sleepFor(1_000_000, worker.index);
            }

            fn task(context: ?*anyopaque, worker: *Worker) void {
                const self: *Owners = @ptrCast(@alignCast(context.?));
                self.calls[worker.index] += 1;
                if (mox_io.os.threadId() != self.ids[worker.index]) self.wrong[worker.index] = true;
                // Management cannot accidentally join the calling owner thread.
                worker.runtime().join() catch |err| {
                    if (err != error.WrongThread) self.wrong[worker.index] = true;
                    return;
                };
                self.wrong[worker.index] = true;
            }

            fn complete(context: ?*anyopaque, worker: *Worker, results: []const t.Completion) void {
                const self: *Owners = @ptrCast(@alignCast(context.?));
                for (results) |result| {
                    if (result.kind != .timer or result.tag != worker.index or mox_io.os.threadId() != self.ids[worker.index]) self.wrong[worker.index] = true;
                    self.results[worker.index] += 1;
                }
            }

            fn stop(context: ?*anyopaque, worker: *Worker) void {
                const self: *Owners = @ptrCast(@alignCast(context.?));
                self.stopped[worker.index] += 1;
            }
        };

        test "Runtime owns independent threads dispatches affine tasks and drains timers" {
            try prepare();
            var runtime: Runtime = undefined;
            try runtime.init(mox_io.mem.PageAllocator.allocator(), options(3));
            defer retire(&runtime);
            var owners: Owners = .{};
            try testing.expectError(error.Closing, runtime.post(.{ .run = Owners.task, .context = &owners }));
            try runtime.start(.{ .context = &owners, .start = Owners.start, .complete = Owners.complete, .stop = Owners.stop });
            try testing.expectError(error.Busy, runtime.deinit());
            try testing.expectError(error.InvalidOptions, runtime.postTo(3, .{ .run = Owners.task, .context = &owners }));
            const allocations = runtime.stats().memory.allocations;
            for (0..3) |index| for (0..100) |_| {
                while (true) {
                    runtime.postTo(index, .{ .run = Owners.task, .context = &owners }) catch |err| {
                        if (err != error.QueueFull) return err;
                        mox_io.sync.Thread.yield();
                        continue;
                    };
                    break;
                }
            };
            runtime.shutdown();
            try testing.expectError(error.Closing, runtime.post(.{ .run = Owners.task, .context = &owners }));
            try runtime.join();
            try runtime.join();
            const snapshot = runtime.stats();
            try testing.expect(snapshot.tasks_posted == 300 and snapshot.tasks_executed == 300 and snapshot.completions == 3);
            try testing.expect(snapshot.threads_exited == 3 and snapshot.failures == 0 and snapshot.memory.allocations == allocations);
            try testing.expect(snapshot.memory.live_bytes == try Runtime.memoryRequired(options(3)));
            for (0..3) |index| {
                try testing.expect(owners.calls[index] == 100 and owners.stopped[index] == 1 and owners.results[index] == 1 and !owners.wrong[index]);
                try testing.expect(owners.ids[index] != mox_io.os.threadId());
                for (owners.ids[0..index]) |previous| try testing.expect(previous != owners.ids[index]);
            }
        }

        const VisibleCounters = struct {
            tasks: u64 = 0,
            completions: u64 = 0,
            invalid: bool = false,

            fn task(context: ?*anyopaque, worker: *Worker) void {
                const self: *VisibleCounters = @ptrCast(@alignCast(context.?));
                const snapshot = worker.runtime().stats();
                // The current callback is counted only after it returns.
                if (snapshot.tasks_executed != self.tasks or snapshot.completions != self.completions) self.invalid = true;
                self.tasks += 1;
                if (self.tasks % 8 != 0) {
                    worker.runtime().postTo(worker.index, .{ .context = self, .run = task }) catch |err| worker.fail(err);
                } else {
                    _ = worker.loop().sleepUntil(1, @intCast(self.tasks)) catch |err| {
                        worker.fail(err);
                        return;
                    };
                }
            }

            fn complete(context: ?*anyopaque, worker: *Worker, results: []const t.Completion) void {
                const self: *VisibleCounters = @ptrCast(@alignCast(context.?));
                const snapshot = worker.runtime().stats();
                if (snapshot.tasks_executed != self.tasks or snapshot.completions != self.completions) self.invalid = true;
                for (results) |result| {
                    if (result.kind != .timer or result.status != .ok or result.tag != self.tasks) self.invalid = true;
                }
                self.completions += results.len;
            }
        };

        test "Runtime publishes task and completion counters after each callback" {
            try prepare();
            var runtime: Runtime = undefined;
            var config = options(1);
            config.queue_capacity = 2;
            try runtime.init(mox_io.mem.PageAllocator.allocator(), config);
            defer retire(&runtime);
            var visible: VisibleCounters = .{};
            try runtime.start(.{ .context = &visible, .complete = VisibleCounters.complete });
            const allocations = runtime.stats().memory.allocations;
            var previous_tasks: u64 = 0;
            var previous_completions: u64 = 0;
            // Each burst spans multiple task batches, then returns through native polling.
            for (0..4) |round| {
                try runtime.postTo(0, .{ .context = &visible, .run = VisibleCounters.task });
                const deadline = mox_io.os.now() + 5_000_000_000;
                while (true) {
                    const snapshot = runtime.stats();
                    try testing.expect(snapshot.tasks_executed >= previous_tasks and snapshot.completions >= previous_completions);
                    try testing.expect(snapshot.tasks_executed <= (round + 1) * 8 and snapshot.completions <= round + 1);
                    previous_tasks = snapshot.tasks_executed;
                    previous_completions = snapshot.completions;
                    if (snapshot.tasks_executed == (round + 1) * 8 and snapshot.completions == round + 1) break;
                    if (runtime.failure() != null) return error.RuntimeFailed;
                    if (mox_io.os.now() >= deadline) return error.RuntimeTestTimeout;
                    mox_io.sync.Thread.yield();
                }
            }
            runtime.shutdown();
            try runtime.join();
            try testing.expect(!visible.invalid and visible.tasks == 32 and visible.completions == 4);
            const snapshot = runtime.stats();
            try testing.expect(snapshot.tasks_posted == 32 and snapshot.tasks_executed == 32 and snapshot.completions == 4);
            try testing.expect(snapshot.memory.allocations == allocations and snapshot.failures == 0);
        }

        test "Runtime automatic CPU sizing and invalid capacities are explicit" {
            const count = try Runtime.cpuCount();
            try testing.expect(count >= 1);
            var runtime: Runtime = undefined;
            try testing.expectError(error.InvalidOptions, Runtime.memoryRequired(.{ .threads = 1, .queue_capacity = 3 }));
            try testing.expectError(error.InvalidOptions, Runtime.memoryRequired(.{ .threads = 1025 }));
            try testing.expectError(error.InvalidOptions, Runtime.memoryRequired(.{ .threads = 1, .completion_batch = 0 }));
            if (count <= 1024) {
                try runtime.init(mox_io.mem.PageAllocator.allocator(), .{});
                defer runtime.deinit() catch unreachable;
                try testing.expect(runtime.stats().threads == count and runtime.stats().threads_started == 0);
            }
        }

        const Gate = struct {
            entered: u32 = 0,
            release: u32 = 0,
            calls: [2]usize = @splat(0),

            fn block(context: ?*anyopaque, _: *Worker) void {
                const self: *Gate = @ptrCast(@alignCast(context.?));
                @atomicStore(u32, &self.entered, 1, .release);
                while (@atomicLoad(u32, &self.release, .acquire) == 0) mox_io.sync.Thread.yield();
            }

            fn count(context: ?*anyopaque, worker: *Worker) void {
                const self: *Gate = @ptrCast(@alignCast(context.?));
                self.calls[worker.index] += 1;
            }
        };

        test "Runtime full queue rejects affinity and round robin uses another owner" {
            try prepare();
            var runtime: Runtime = undefined;
            var config = options(2);
            config.queue_capacity = 2;
            try runtime.init(mox_io.mem.PageAllocator.allocator(), config);
            defer retire(&runtime);
            var gate: Gate = .{};
            defer @atomicStore(u32, &gate.release, 1, .release);
            try runtime.start(.{ .complete = ignored });
            try runtime.postTo(0, .{ .context = &gate, .run = Gate.block });
            try wait(&gate.entered);
            try runtime.postTo(0, .{ .context = &gate, .run = Gate.count });
            try runtime.postTo(0, .{ .context = &gate, .run = Gate.count });
            try testing.expectError(error.QueueFull, runtime.postTo(0, .{ .context = &gate, .run = Gate.count }));
            try testing.expect(try runtime.post(.{ .context = &gate, .run = Gate.count }) == 1);
            runtime.shutdown();
            try testing.expectError(error.Busy, runtime.deinit());
            @atomicStore(u32, &gate.release, 1, .release);
            try runtime.join();
            try testing.expect(gate.calls[0] == 2 and gate.calls[1] == 1);
            try testing.expect(runtime.stats().tasks_posted == 4 and runtime.stats().tasks_executed == 4);
        }

        const Producer = struct {
            runtime: *Runtime,
            owners: *Owners,
            accepted: usize = 0,
            failed: bool = false,

            fn run(context: *anyopaque) void {
                const self: *Producer = @ptrCast(@alignCast(context));
                for (0..2000) |_| {
                    while (true) {
                        _ = self.runtime.post(.{ .context = self.owners, .run = Owners.task }) catch |err| {
                            if (err == error.Closing) return;
                            if (err != error.QueueFull) {
                                self.failed = true;
                                return;
                            }
                            mox_io.sync.Thread.yield();
                            continue;
                        };
                        self.accepted += 1;
                        break;
                    }
                }
            }
        };

        test "Runtime producer admission racing shutdown retires every accepted task" {
            try prepare();
            for (0..8) |_| {
                var runtime: Runtime = undefined;
                try runtime.init(mox_io.mem.PageAllocator.allocator(), options(3));
                defer retire(&runtime);
                var owners: Owners = .{};
                try runtime.start(.{ .context = &owners, .start = Owners.start, .complete = Owners.complete });
                var producers: [4]Producer = undefined;
                var threads: [4]mox_io.sync.Thread = undefined;
                var started: usize = 0;
                defer {
                    runtime.shutdown();
                    for (threads[0..started]) |*thread| thread.join();
                }
                for (&producers, &threads) |*producer, *thread| {
                    producer.* = .{ .runtime = &runtime, .owners = &owners };
                    try thread.start(Producer.run, producer);
                    started += 1;
                }
                const deadline = mox_io.os.now() + 5_000_000_000;
                while (runtime.stats().tasks_posted < 128) {
                    if (mox_io.os.now() >= deadline) return error.RuntimeTestTimeout;
                    mox_io.sync.Thread.yield();
                }
                runtime.shutdown();
                for (&threads) |*thread| thread.join();
                started = 0;
                try runtime.join();
                var accepted: usize = 0;
                for (producers) |producer| {
                    try testing.expect(!producer.failed);
                    accepted += producer.accepted;
                }
                const snapshot = runtime.stats();
                try testing.expect(snapshot.tasks_posted == accepted and snapshot.tasks_executed == accepted and snapshot.threads_exited == 3);
            }
        }

        const Failing = struct {
            calls: usize = 0,
            live: usize = 0,
            fail_at: usize,

            fn allocator(self: *Failing) mox_io.mem.Allocator {
                return .{ .context = self, .vtable = &.{ .allocate = allocate, .release = release } };
            }

            fn allocate(context: ?*anyopaque, size: usize, alignment: usize) error{OutOfMemory}!mox_io.mem.Allocation {
                const self: *Failing = @ptrCast(@alignCast(context.?));
                self.calls += 1;
                if (self.calls == self.fail_at) return error.OutOfMemory;
                const result = mox_io.mem.PageAllocator.allocator().allocate(size, alignment) catch return error.OutOfMemory;
                self.live += 1;
                return result;
            }

            fn release(context: ?*anyopaque, allocation: mox_io.mem.Allocation) void {
                const self: *Failing = @ptrCast(@alignCast(context.?));
                self.live -= 1;
                mox_io.mem.PageAllocator.allocator().release(allocation);
            }
        };

        test "Runtime failed native initialization joins owners and rolls back allocations" {
            try prepare();
            var provider: Failing = .{ .fail_at = 1 };
            var runtime: Runtime = undefined;
            try testing.expectError(error.OutOfMemory, runtime.init(provider.allocator(), options(3)));
            try testing.expect(provider.live == 0);
            provider = .{ .fail_at = 3 };
            try runtime.init(provider.allocator(), options(3));
            try testing.expectError(error.OutOfMemory, runtime.start(.{ .complete = ignored }));
            try testing.expect(runtime.failure().?.cause == error.OutOfMemory);
            try testing.expect(runtime.stats().threads_exited == 3 and runtime.stats().tasks_executed == 0);
            try runtime.deinit();
            try testing.expect(provider.live == 0);
        }

        fn startFailed(_: ?*anyopaque, worker: *Worker) mox_io.Error!void {
            if (worker.index == 0) return error.NativeFailure;
            _ = try worker.loop().sleepFor(60_000_000_000, 1);
        }

        fn stopTogether(_: ?*anyopaque, worker: *Worker) mox_io.Error!void {
            worker.runtime().shutdown();
        }

        test "Runtime concurrent shutdown requests safely race backend destruction" {
            try prepare();
            for (0..32) |_| {
                var runtime: Runtime = undefined;
                try runtime.init(mox_io.mem.PageAllocator.allocator(), options(3));
                defer retire(&runtime);
                try runtime.start(.{ .start = stopTogether, .complete = ignored });
                runtime.shutdown();
                try runtime.join();
                runtime.shutdown();
                try testing.expect(runtime.stats().threads_exited == 3 and runtime.stats().failures == 0);
            }
        }

        test "Runtime asynchronous start failure wakes idle owners and propagates through join" {
            try prepare();
            var runtime: Runtime = undefined;
            try runtime.init(mox_io.mem.PageAllocator.allocator(), options(3));
            defer retire(&runtime);
            try runtime.start(.{ .start = startFailed, .complete = ignored });
            try testing.expectError(error.NativeFailure, runtime.join());
            try testing.expect(runtime.failure().?.stage == .start and runtime.failure().?.worker == 0);
            try testing.expect(runtime.stats().threads_exited == 3);
        }

        const Server = struct {
            addresses: [3]t.Address = undefined,
            buffers: [3][7]u8 = undefined,
            ready: u32 = 0,
            replied: [3]usize = @splat(0),
            done: u32 = 0,
            rounds: usize,

            fn start(context: ?*anyopaque, worker: *Worker) mox_io.Error!void {
                const self: *Server = @ptrCast(@alignCast(context.?));
                const listener = try worker.loop().listen(t.Address.loopback(0), 8);
                self.addresses[worker.index] = try worker.loop().localAddress(listener);
                _ = try worker.loop().accept(listener, .{});
                _ = @atomicRmw(u32, &self.ready, .Or, @as(u32, 1) << @intCast(worker.index), .acq_rel);
            }

            fn complete(context: ?*anyopaque, worker: *Worker, results: []const t.Completion) void {
                const self: *Server = @ptrCast(@alignCast(context.?));
                for (results) |result| self.handle(worker, result) catch |err| worker.fail(err);
            }

            fn handle(self: *Server, worker: *Worker, result: t.Completion) mox_io.Error!void {
                if (result.status == .canceled or result.kind == .close) return;
                if (result.status != .ok) return error.NativeFailure;
                switch (result.kind) {
                    .accept => {
                        try worker.loop().noDelay(result.accepted.?, true);
                        _ = try worker.loop().recvExact(result.accepted.?, &self.buffers[worker.index], .{});
                    },
                    .recv => {
                        if (!mox_io.mem.bytes.equal(&self.buffers[worker.index], "runtime")) return error.InvalidState;
                        _ = try worker.loop().sendAll(result.handle, &self.buffers[worker.index], .{});
                    },
                    .send => {
                        self.replied[worker.index] += 1;
                        if (self.replied[worker.index] == self.rounds) {
                            try worker.loop().close(result.handle, .drain, 0);
                            _ = @atomicRmw(u32, &self.done, .Or, @as(u32, 1) << @intCast(worker.index), .acq_rel);
                        } else _ = try worker.loop().recvExact(result.handle, &self.buffers[worker.index], .{});
                    },
                    else => return error.InvalidState,
                }
            }
        };

        fn one(loop: *Loop) !t.Completion {
            const deadline = loop.now() + 5_000_000_000;
            var output: [1]t.Completion = undefined;
            while (try loop.poll(&output, .{ .until = deadline }) == 0) {
                if (loop.now() >= deadline) return error.RuntimeTestTimeout;
            }
            try testing.expect(output[0].status == .ok);
            return output[0];
        }

        test "Runtime independent owners serve real TCP sessions without handle migration" {
            try tcp();
        }

        pub fn tcp() !void {
            return tcpRounds(1);
        }

        pub fn tcpRounds(rounds: usize) !void {
            try prepare();
            var runtime: Runtime = undefined;
            try runtime.init(mox_io.mem.PageAllocator.allocator(), options(3));
            defer retire(&runtime);
            var server: Server = .{ .rounds = rounds };
            try runtime.start(.{ .context = &server, .start = Server.start, .complete = Server.complete });
            const deadline = mox_io.os.now() + 30_000_000_000;
            while (@atomicLoad(u32, &server.ready, .acquire) != 7) {
                if (mox_io.os.now() >= deadline) return error.RuntimeTestTimeout;
                mox_io.sync.Thread.yield();
            }
            var client: Loop = undefined;
            try client.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 8, .resources = 4, .file_threads = 0 });
            defer {
                client.shutdown() catch unreachable;
                var output: [8]t.Completion = undefined;
                while (client.stats().active_operations != 0 or client.stats().active_resources != 0 or client.stats().completions_queued != 0)
                    _ = client.poll(&output, .none) catch unreachable;
                client.deinit() catch unreachable;
            }
            var sockets: [3]t.Handle = undefined;
            for (server.addresses, &sockets) |address, *socket| {
                socket.* = try client.openTcp(.ipv4);
                _ = try client.connect(socket.*, address, .{});
                _ = try one(&client);
                try client.noDelay(socket.*, true);
            }
            for (0..rounds) |_| {
                for (sockets) |socket| _ = try client.sendAll(socket, "runtime", .{});
                for (sockets) |_| _ = try one(&client);
                var responses: [3][7]u8 = undefined;
                for (sockets, &responses) |socket, *response| _ = try client.recvExact(socket, response, .{});
                for (sockets) |_| _ = try one(&client);
                for (responses) |response| try testing.expectEqualSlices(u8, "runtime", &response);
            }
            while (@atomicLoad(u32, &server.done, .acquire) != 7) {
                if (mox_io.os.now() >= deadline) return error.RuntimeTestTimeout;
                mox_io.sync.Thread.yield();
            }
            runtime.shutdown();
            try runtime.join();
            for (server.replied) |replies| try testing.expect(replies == rounds);
        }
    };
}
