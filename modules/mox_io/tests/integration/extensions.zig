//! Native filesystem, resolver, pipe and process integration contracts.

const std = @import("std");

const testing = std.testing;
const mox_io = @import("mox_io");

const t = mox_io.types;
const builtin = @import("builtin");

pub fn Suite(comptime Backend: type) type {
    return struct {
        const Loop = mox_io.Loop(Backend);

        fn init(loop: *Loop) !void {
            loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 16, .resources = 8, .file_threads = 3 }) catch |err| {
                if (Backend == mox_io.backends.Uring and err == error.BackendUnavailable) return error.SkipZigTest;
                return err;
            };
        }

        fn gather(loop: *Loop, output: []t.Completion) !void {
            const deadline = loop.now() + 10_000_000_000;
            var count: usize = 0;
            while (count < output.len) {
                if (loop.now() >= deadline) return error.TestTimeout;
                count += try loop.poll(output[count..], .{ .until = deadline });
            }
        }

        fn cleanup(loop: *Loop) !void {
            try loop.shutdown();
            var results: [16]t.Completion = undefined;
            while (loop.stats().active_resources != 0 or loop.stats().active_operations != 0 or loop.stats().completions_queued != 0)
                _ = try loop.poll(&results, .{ .until = loop.now() + 1_000_000_000 });
            try loop.deinit();
        }

        const Job = struct {
            calls: usize = 0,

            fn run(context: ?*anyopaque, _: usize) mox_io.Error!usize {
                const self: *@This() = @ptrCast(@alignCast(context.?));
                self.calls += 1;
                return 37;
            }
        };

        test "io_uring preharvested wake returns before waiting again" {
            if (Backend != mox_io.backends.Uring) return error.SkipZigTest;
            var loop: Loop = undefined;
            try init(&loop);
            defer cleanup(&loop) catch unreachable;
            loop.backend.wake();
            // Force the wake CQE to exist before entering the pre-wait harvest.
            try loop.backend.ring.wait(1_000_000_000);
            const before = loop.now();
            _ = try loop.backend.poll(loop.events, 250_000_000);
            try testing.expect(loop.backend.poll_woken);
            try testing.expect(loop.now() - before < 125_000_000);
        }

        test "io_uring combined submission and wait flushes errors and wraps the SQ" {
            if (Backend != mox_io.backends.Uring) return error.SkipZigTest;
            var loop: Loop = undefined;
            try init(&loop);
            defer cleanup(&loop) catch unreachable;
            const ring = &loop.backend.ring;
            const allocations = loop.stats().memory.allocations;
            // The invalid opcode can stop a submission batch before its trailing NOP.
            // Repeated batches also wrap both rings and exercise every wait mode.
            for (0..128) |round| {
                const invalid = ring.reserve() orelse return error.TestCapacity;
                invalid.* = .{ .opcode = 255, .user_data = 101 };
                const nop = ring.reserve() orelse return error.TestCapacity;
                nop.* = .{ .opcode = 0, .user_data = 102 };
                const duration: ?u64 = switch (round % 3) {
                    0 => 0,
                    1 => 1_000_000_000,
                    else => null,
                };
                try ring.flushAndWait(duration);
                var seen: u8 = 0;
                const deadline = loop.now() + 5_000_000_000;
                while (seen != 3) {
                    if (loop.now() >= deadline) return error.TestTimeout;
                    if (ring.pop()) |event| {
                        switch (event.user_data) {
                            101 => {
                                try testing.expect(seen & 1 == 0 and event.result == -22);
                                seen |= 1;
                            },
                            102 => {
                                try testing.expect(seen & 2 == 0 and event.result == 0);
                                seen |= 2;
                            },
                            else => return error.UnexpectedCompletion,
                        }
                    } else try ring.wait(1_000_000);
                }
            }
            try testing.expect(loop.stats().memory.allocations == allocations);
        }

        test "io_uring staged receive cancellation retires before native submission" {
            if (Backend != mox_io.backends.Uring) return error.SkipZigTest;
            var loop: Loop = undefined;
            try init(&loop);
            defer cleanup(&loop) catch unreachable;
            const listener = try loop.listen(t.Address.loopback(0), 8);
            const client = try loop.openTcp(.ipv4);
            _ = try loop.accept(listener, .{});
            _ = try loop.connect(client, try loop.localAddress(listener), .{});
            var pair: [2]t.Completion = undefined;
            try gather(&loop, &pair);
            var peer: t.Handle = undefined;
            for (pair) |result| {
                try testing.expect(result.status == .ok);
                if (result.accepted) |handle| peer = handle;
            }
            var bytes: [8]u8 = @splat(0xa5);
            // Exercise the interval between backend admission and poll directly.
            for (0..64) |generation| {
                const id: t.OpId = .{ .index = 0, .generation = generation + 1000 };
                const request = &loop.operations.requests[0];
                request.* = .{ .id = id, .handle = peer, .native = loop.resources.slots[peer.index].native, .kind = .recv, .options = .{}, .read_buffer = &bytes };
                try loop.backend.submit(request);
                const cqes = loop.backend.stats().native_cqes;
                loop.backend.cancel(id);
                const count = try loop.backend.poll(loop.events, 0);
                try testing.expect(count == 1 and loop.events[0].id.generation == id.generation);
                try testing.expect(loop.events[0].status == .canceled);
                try testing.expect(loop.backend.stats().native_cqes == cqes);
                for (bytes) |byte| try testing.expect(byte == 0xa5);
            }
            // Reusing the operation storage must not replay a canceled staged index.
            _ = try loop.recvExact(peer, bytes[0..4], .{});
            _ = try loop.sendAll(client, "live", .{});
            try gather(&loop, &pair);
            for (pair) |result| try testing.expect(result.status == .ok and result.bytes == 4);
            try testing.expectEqualStrings("live", bytes[0..4]);
        }

        test "io_uring ready receive avoids native submission without sibling sends" {
            if (Backend != mox_io.backends.Uring) return error.SkipZigTest;
            var loop: Loop = undefined;
            try init(&loop);
            defer cleanup(&loop) catch unreachable;
            const listener = try loop.listen(t.Address.loopback(0), 8);
            const client = try loop.openTcp(.ipv4);
            _ = try loop.accept(listener, .{});
            _ = try loop.connect(client, try loop.localAddress(listener), .{});
            var pair: [2]t.Completion = undefined;
            try gather(&loop, &pair);
            var peer: t.Handle = undefined;
            for (pair) |result| {
                try testing.expect(result.status == .ok);
                if (result.accepted) |handle| peer = handle;
            }
            _ = try loop.sendAll(client, "read-data", .{});
            var sent: [1]t.Completion = undefined;
            try gather(&loop, &sent);
            try testing.expect(sent[0].status == .ok and sent[0].bytes == 9);
            // Finish the send batch before submitting any receive.
            try testing.expect(try loop.backend.poll(loop.events, 0) == 0);
            try loop.close(client, .cancel, 77);
            try gather(&loop, &sent);
            try testing.expect(sent[0].kind == .close and sent[0].tag == 77);
            const allocations = loop.stats().memory.allocations;
            var bytes: [9]u8 = undefined;
            const native = loop.resources.slots[peer.index].native;
            const request = &loop.operations.requests[0];
            // Short reads, remaining data and EOF all use the same bounded fast path.
            for (0..3) |iteration| {
                const before = loop.backend.stats().native_cqes;
                request.* = .{ .id = .{ .index = 0, .generation = iteration + 3000 }, .handle = peer, .native = native, .kind = .recv, .options = .{}, .read_buffer = if (iteration == 0) bytes[0..4] else bytes[4..] };
                try loop.backend.submit(request);
                try testing.expect(try loop.backend.poll(loop.events, 0) == 1);
                const result = loop.events[0];
                try testing.expect(result.id.generation == iteration + 3000);
                try testing.expect(result.status == (if (iteration == 2) t.Status.eof else t.Status.ok));
                try testing.expect(result.bytes == @as(usize, switch (iteration) {
                    0 => 4,
                    1 => 5,
                    else => 0,
                }));
                try testing.expect(loop.backend.native_pending == 0);
                try testing.expect(loop.backend.stats().native_cqes == before);
            }
            try testing.expectEqualStrings("read-data", &bytes);
            try testing.expect(loop.stats().memory.allocations == allocations);
        }

        test "readiness receives progress while immediate sends keep completions queued" {
            if (Backend != mox_io.backends.Epoll and Backend != mox_io.backends.Kqueue) return error.SkipZigTest;
            var loop: Loop = undefined;
            try init(&loop);
            defer cleanup(&loop) catch unreachable;
            const listener = try loop.listen(t.Address.loopback(0), 8);
            const client = try loop.openTcp(.ipv4);
            _ = try loop.accept(listener, .{});
            _ = try loop.connect(client, try loop.localAddress(listener), .{});
            var pair: [2]t.Completion = undefined;
            try gather(&loop, &pair);
            var peer: t.Handle = undefined;
            for (pair) |result| {
                try testing.expect(result.status == .ok);
                if (result.accepted) |handle| peer = handle;
            }
            var byte: [1]u8 = undefined;
            const receiving = &loop.operations.requests[0];
            receiving.* = .{ .id = .{ .index = 0, .generation = 9000 }, .handle = peer, .native = loop.resources.slots[peer.index].native, .kind = .recv, .options = .{}, .read_buffer = &byte };
            try loop.backend.submit(receiving);
            try testing.expect(try loop.backend.poll(loop.events, 0) == 0);
            var saw_receive = false;
            // Direct backend requests do not enter the Loop's operation table.
            // Retire their results here even if the progress assertion fails.
            defer {
                if (!saw_receive) loop.backend.cancel(receiving.id);
                _ = loop.backend.poll(loop.events, 0) catch 0;
            }
            const sending = &loop.operations.requests[1];
            for (0..64) |iteration| {
                sending.* = .{ .id = .{ .index = 1, .generation = iteration + 10000 }, .handle = client, .native = loop.resources.slots[client.index].native, .kind = .send, .options = .{}, .write_buffer = "x" };
                try loop.backend.submit(sending);
                const count = try loop.backend.poll(loop.events, 0);
                var saw_send = false;
                for (loop.events[0..count]) |result| {
                    try testing.expect(result.status == .ok and result.bytes == 1);
                    if (result.id.generation == receiving.id.generation) saw_receive = true;
                    if (result.id.generation == sending.id.generation) saw_send = true;
                }
                try testing.expect(saw_send);
                if (saw_receive) break;
            }
            try testing.expect(saw_receive);
            try testing.expectEqual(@as(u8, 'x'), byte[0]);
        }

        test "io_uring native receive progresses under immediate send pressure" {
            if (Backend != mox_io.backends.Uring) return error.SkipZigTest;
            var loop: Loop = undefined;
            try init(&loop);
            defer cleanup(&loop) catch unreachable;
            const listener = try loop.listen(t.Address.loopback(0), 8);
            const client = try loop.openTcp(.ipv4);
            _ = try loop.accept(listener, .{});
            _ = try loop.connect(client, try loop.localAddress(listener), .{});
            var pair: [2]t.Completion = undefined;
            try gather(&loop, &pair);
            var peer: t.Handle = undefined;
            for (pair) |result| {
                try testing.expect(result.status == .ok);
                if (result.accepted) |handle| peer = handle;
            }
            var byte: [1]u8 = undefined;
            const receiving = &loop.operations.requests[0];
            receiving.* = .{ .id = .{ .index = 0, .generation = 1000 }, .handle = peer, .native = loop.resources.slots[peer.index].native, .kind = .recv, .options = .{}, .read_buffer = &byte };
            try loop.backend.submit(receiving);
            // Submit the empty receive before any send can take the inline path.
            try testing.expect(try loop.backend.poll(loop.events[0..1], 0) == 0);
            try testing.expect(loop.backend.native_pending == 1);
            var received = false;
            for (0..128) |generation| {
                const sending = &loop.operations.requests[1];
                sending.* = .{ .id = .{ .index = 1, .generation = generation + 1000 }, .handle = client, .native = loop.resources.slots[client.index].native, .kind = .send, .options = .{}, .write_buffer = if (generation == 0) "x" else "" };
                try loop.backend.submit(sending);
                try testing.expect(loop.backend.immediate.count == 1);
                // A one-event output and a fresh immediate result used to hide native CQEs.
                try testing.expect(try loop.backend.poll(loop.events[0..1], 0) == 1);
                try testing.expect(loop.events[0].status == .ok);
                if (loop.events[0].id.index == 0) {
                    try testing.expect(loop.events[0].bytes == 1);
                    received = true;
                    try testing.expect(try loop.backend.poll(loop.events[0..1], 0) == 1);
                    try testing.expect(loop.events[0].id.index == 1 and loop.events[0].status == .ok);
                    break;
                }
            }
            try testing.expect(received and byte[0] == 'x');
            try testing.expect(loop.backend.native_pending == 0);
            // Conversely, a full native CQ must leave bounded room for immediate results.
            var bytes: [4]u8 = undefined;
            for (0..bytes.len) |index| {
                const request = &loop.operations.requests[index];
                request.* = .{ .id = .{ .index = @intCast(index), .generation = 2000 }, .handle = peer, .native = loop.resources.slots[peer.index].native, .kind = .recv, .options = .{}, .read_buffer = bytes[index..][0..1] };
                try loop.backend.submit(request);
            }
            try testing.expect(try loop.backend.poll(loop.events[0..1], 0) == 0);
            const sending = &loop.operations.requests[4];
            sending.* = .{ .id = .{ .index = 4, .generation = 2000 }, .handle = client, .native = loop.resources.slots[client.index].native, .kind = .send, .options = .{}, .write_buffer = "abcd" };
            try loop.backend.submit(sending);
            const ring = &loop.backend.ring;
            const deadline = loop.now() + 5_000_000_000;
            while (@atomicLoad(u32, ring.cq_tail, .acquire) -% @atomicLoad(u32, ring.cq_head, .monotonic) < 4) {
                if (loop.now() >= deadline) return error.TestTimeout;
                try ring.wait(0);
            }
            var sent = false;
            for (0..5) |index| {
                try testing.expect(try loop.backend.poll(loop.events[0..1], 0) == 1);
                try testing.expect(loop.events[0].status == .ok);
                if (loop.events[0].id.index == 4) sent = true;
                if (index == 1) try testing.expect(sent);
            }
            try testing.expect(loop.backend.native_pending == 0 and loop.backend.immediate.count == 0);
            // Parallel raw receives may finish out of order; every byte must arrive once.
            var seen: u8 = 0;
            for (bytes) |value| {
                try testing.expect(value >= 'a' and value <= 'd');
                seen |= @as(u8, 1) << @intCast(value - 'a');
            }
            try testing.expect(seen == 15);
        }

        test "native send backpressure preserves partial progress and cancellation" {
            var loop: Loop = undefined;
            try init(&loop);
            defer cleanup(&loop) catch unreachable;
            const listener = try loop.listen(t.Address.loopback(0), 8);
            const client = try loop.openTcp(.ipv4);
            try loop.socketOption(client, .send_buffer, 4096);
            _ = try loop.accept(listener, .{});
            _ = try loop.connect(client, try loop.localAddress(listener), .{});
            var pair: [2]t.Completion = undefined;
            try gather(&loop, &pair);
            var peer: t.Handle = undefined;
            for (pair) |result| {
                try testing.expect(result.status == .ok);
                if (result.accepted) |handle| peer = handle;
            }
            const source = try testing.allocator.alloc(u8, 2 * 1024 * 1024);
            defer testing.allocator.free(source);
            const target = try testing.allocator.alloc(u8, source.len);
            defer testing.allocator.free(target);
            for (source, 0..) |*byte, index| byte.* = @truncate(index *% 37 +% 11);
            const allocations = loop.stats().memory.allocations;
            const deadline = loop.now() + 10_000_000_000;
            _ = try loop.sendAll(client, source, .{ .deadline = deadline });
            // No reader yet: the owner must remain responsive under real socket pressure.
            for (0..8) |_| try loop.pump(.none);
            _ = try loop.recvExact(peer, target, .{ .deadline = deadline });
            try gather(&loop, &pair);
            for (pair) |result| try testing.expect(result.status == .ok and result.bytes == source.len);
            try testing.expectEqualSlices(u8, source, target);
            const sending = try loop.sendAll(client, source, .{});
            for (0..8) |_| try loop.pump(.none);
            const canceled = try loop.cancel(sending);
            var result: [1]t.Completion = undefined;
            try gather(&loop, &result);
            try testing.expect(result[0].id.?.index == sending.index);
            if (canceled == .already_completed) {
                // Some kernels can buffer the full write before cancellation is requested.
                try testing.expect(result[0].status == .ok and result[0].bytes == source.len);
            } else try testing.expect(result[0].status == .canceled and result[0].bytes <= source.len);
            try testing.expect(loop.stats().memory.allocations == allocations);
        }

        test "Linux wake counters coalesce bursts and notify again after drain" {
            if (builtin.os.tag != .linux) return error.SkipZigTest;
            var loop: Loop = undefined;
            loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 1, .resources = 1, .events = 4, .inbox = 0, .file_threads = 0 }) catch |err| {
                if (Backend == mox_io.backends.Uring and err == error.BackendUnavailable) return error.SkipZigTest;
                return err;
            };
            defer cleanup(&loop) catch unreachable;
            const deadline = loop.now() + 5_000_000_000;
            for (0..32) |_| {
                const before = loop.backend.stats().wakeups;
                // A non-semaphore eventfd read must consume the entire accumulated burst.
                for (0..8) |_| loop.backend.wake();
                while (loop.backend.stats().wakeups == before) {
                    if (loop.now() >= deadline) return error.TestTimeout;
                    try testing.expect(try loop.backend.poll(loop.events, 0) == 0);
                    mox_io.sync.Thread.yield();
                }
                try testing.expect(loop.backend.stats().wakeups == before + 1);
                // An empty poll rearms one-shot waits without replaying the drained counter.
                try testing.expect(try loop.backend.poll(loop.events, 0) == 0);
                try testing.expect(loop.backend.stats().wakeups == before + 1);
            }
        }

        test "single worker saturation preserves timers capacity and bounded shutdown" {
            var loop: Loop = undefined;
            loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 3, .resources = 1, .file_threads = 1 }) catch |err| {
                if (Backend == mox_io.backends.Uring and err == error.BackendUnavailable) return error.SkipZigTest;
                return err;
            };
            defer cleanup(&loop) catch unreachable;
            var gate: Gate = .{};
            defer gate.release.store(true, .release);
            const running = try loop.work(.{ .context = &gate, .run = Gate.run }, .{});
            try loop.pump(.none);
            const stop = loop.now() + 5_000_000_000;
            while (!gate.entered.load(.acquire)) {
                if (loop.now() >= stop) return error.TestTimeout;
                mox_io.sync.Thread.yield();
            }
            var job: Job = .{};
            _ = try loop.work(.{ .context = &job, .run = Job.run }, .{ .deadline = loop.now() + 1_000_000 });
            _ = try loop.sleepFor(1_000_000, 99);
            try testing.expectError(error.Capacity, loop.work(.{ .context = &job, .run = Job.run }, .{}));
            var result: [1]t.Completion = undefined;
            try gather(&loop, &result);
            try testing.expect(result[0].kind == .timer and job.calls == 0);
            try testing.expectError(error.Busy, loop.deinit());
            try loop.shutdown();
            try testing.expectError(error.Closing, loop.work(.{ .context = &job, .run = Job.run }, .{}));
            try testing.expect(try loop.poll(&result, .none) == 0);
            gate.release.store(true, .release);
            var results: [2]t.Completion = undefined;
            try gather(&loop, &results);
            for (results) |item| {
                try testing.expect(item.kind == .work);
                if (item.id.?.index == running.index) try testing.expect(item.status == .canceled and item.bytes == 7) else try testing.expect(item.status == .timed_out and item.bytes == 0);
            }
            try testing.expect(job.calls == 0 and loop.stats().active_operations == 0);
        }

        test "blocked pipe with one worker can be canceled and released by peer close" {
            var loop: Loop = undefined;
            loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 3, .resources = 1, .file_threads = 1 }) catch |err| {
                if (Backend == mox_io.backends.Uring and err == error.BackendUnavailable) return error.SkipZigTest;
                return err;
            };
            defer cleanup(&loop) catch unreachable;
            var pipe: mox_io.Pipe = .{};
            try pipe.init();
            defer pipe.deinit() catch unreachable;
            var bytes: [8]u8 = undefined;
            var read: mox_io.Pipe.Transfer = .{ .end = &pipe.reader, .read_buffer = &bytes };
            const id = try read.submit(&loop, .{});
            try loop.pump(.none);
            _ = try loop.sleepFor(1_000_000, 1);
            var result: [1]t.Completion = undefined;
            try gather(&loop, &result);
            try testing.expect(result[0].kind == .timer);
            _ = try loop.cancel(id);
            try loop.shutdown();
            try pipe.writer.close();
            try gather(&loop, &result);
            try testing.expect(read.complete(result[0]) and result[0].status == .canceled);
            try testing.expect(loop.stats().active_operations == 0);
        }

        test "saturated shared executor keeps both Loop owners responsive and prevents early destruction" {
            var executor: mox_io.fs.Executor = undefined;
            try executor.init(mox_io.mem.PageAllocator.allocator(), .{ .jobs = 6, .clients = 2, .threads = 1 });
            defer executor.deinit() catch unreachable;
            var first: Loop = undefined;
            first.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 2, .resources = 1, .file_executor = &executor }) catch |err| {
                if (Backend == mox_io.backends.Uring and err == error.BackendUnavailable) return error.SkipZigTest;
                return err;
            };
            defer cleanup(&first) catch unreachable;
            var second: Loop = undefined;
            try second.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 2, .resources = 1, .file_executor = &executor });
            defer cleanup(&second) catch unreachable;
            try testing.expectError(error.Busy, executor.deinit());
            var gate: Gate = .{};
            defer gate.release.store(true, .release);
            _ = try first.work(.{ .context = &gate, .run = Gate.run }, .{});
            try first.pump(.none);
            const deadline = first.now() + 5_000_000_000;
            while (!gate.entered.load(.acquire)) {
                if (first.now() >= deadline) return error.TestTimeout;
                mox_io.sync.Thread.yield();
            }
            var job: Job = .{};
            _ = try second.work(.{ .context = &job, .run = Job.run }, .{});
            _ = try second.sleepFor(1_000_000, 5);
            var result: [1]t.Completion = undefined;
            try gather(&second, &result);
            try testing.expect(result[0].kind == .timer);
            try first.shutdown();
            try second.shutdown();
            try testing.expectError(error.Busy, first.deinit());
            try testing.expectError(error.Busy, second.deinit());
            gate.release.store(true, .release);
            try gather(&first, &result);
            try testing.expect(result[0].status == .canceled);
            try gather(&second, &result);
            try testing.expect(result[0].status == .canceled);
            try testing.expect(job.calls == 0 and executor.stats().jobs_active == 0);
        }

        test "portable work reports counts and queued cancellation skips callbacks" {
            var loop: Loop = undefined;
            try init(&loop);
            defer cleanup(&loop) catch unreachable;
            var job: Job = .{};
            _ = try loop.work(.{ .context = &job, .run = Job.run }, .{});
            var result: [1]t.Completion = undefined;
            try gather(&loop, &result);
            try testing.expect(result[0].status == .ok and result[0].bytes == 37 and job.calls == 1);
            const id = try loop.work(.{ .context = &job, .run = Job.run }, .{});
            _ = try loop.cancel(id);
            try gather(&loop, &result);
            try testing.expect(result[0].status == .canceled and job.calls == 1);
        }

        const Gate = struct {
            entered: std.atomic.Value(bool) = .init(false),
            release: std.atomic.Value(bool) = .init(false),

            fn run(context: ?*anyopaque, _: usize) mox_io.Error!usize {
                const self: *@This() = @ptrCast(@alignCast(context.?));
                self.entered.store(true, .release);
                while (!self.release.load(.acquire)) mox_io.sync.Thread.yield();
                return 7;
            }
        };

        fn workerRetirement(shared: bool) !void {
            var executor: mox_io.fs.Executor = undefined;
            if (shared) try executor.init(mox_io.mem.PageAllocator.allocator(), .{ .jobs = 3, .clients = 1, .threads = 1 });
            defer if (shared) executor.deinit() catch unreachable;
            var loop: Loop = undefined;
            loop.init(mox_io.mem.PageAllocator.allocator(), .{
                .operations = 2,
                .resources = 1,
                .file_threads = 1,
                .file_executor = if (shared) &executor else null,
            }) catch |err| {
                if (Backend == mox_io.backends.Uring and err == error.BackendUnavailable) return error.SkipZigTest;
                return err;
            };
            defer cleanup(&loop) catch unreachable;
            const workers = &loop.backend.workers;
            const allocations = loop.stats().memory.allocations;
            var output: [1]mox_io.backend_common.Event = undefined;
            var empty: [0]mox_io.backend_common.Event = .{};
            try testing.expect(workers.pending == 0 and workers.poll(&output) == 0);
            if (shared) {
                var rejected: mox_io.backend_common.Request = .{ .id = .{ .index = 3, .generation = 1 }, .handle = t.invalid_handle, .native = 0, .kind = .work, .options = .{} };
                try testing.expectError(error.Capacity, workers.submit(&rejected));
                try testing.expect(workers.pending == 0);
            }
            var gate: Gate = .{};
            var job: Job = .{};
            var requests = [_]mox_io.backend_common.Request{
                .{ .id = .{ .index = 0, .generation = 1 }, .handle = t.invalid_handle, .native = 0, .kind = .work, .options = .{}, .work = .{ .context = &gate, .run = Gate.run } },
                .{ .id = .{ .index = 1, .generation = 1 }, .handle = t.invalid_handle, .native = 0, .kind = .work, .options = .{}, .work = .{ .context = &job, .run = Job.run } },
            };
            var submitted: usize = 0;
            var consumed: usize = 0;
            defer {
                // Raw worker requests must retire before the Loop releases its backing.
                for (requests[0..submitted]) |request| workers.cancel(request.id);
                gate.release.store(true, .release);
                const stop = loop.now() + 5_000_000_000;
                while (consumed < submitted) {
                    if (loop.now() >= stop) @panic("worker retirement cleanup timed out");
                    consumed += workers.poll(&output);
                    mox_io.sync.Thread.yield();
                }
            }
            try workers.submit(&requests[0]);
            submitted = 1;
            const deadline = loop.now() + 5_000_000_000;
            while (!gate.entered.load(.acquire)) {
                if (loop.now() >= deadline) return error.TestTimeout;
                mox_io.sync.Thread.yield();
            }
            try workers.submit(&requests[1]);
            submitted = 2;
            workers.cancel(requests[1].id);
            // Cancellation and empty reads cannot release a native reservation.
            try testing.expect(workers.pending == 2 and workers.poll(&empty) == 0);
            try testing.expect(workers.pending == 2 and workers.poll(&output) == 0);
            gate.release.store(true, .release);
            while (true) {
                const ready = if (shared) executor.stats().completed == 2 else ready: {
                    workers.mutex.lock();
                    defer workers.mutex.unlock();
                    break :ready workers.completed.count == 2;
                };
                if (ready) break;
                if (loop.now() >= deadline) return error.TestTimeout;
                mox_io.sync.Thread.yield();
            }
            try testing.expect(workers.poll(&empty) == 0 and workers.pending == 2);
            while (consumed < submitted) {
                if (loop.now() >= deadline) return error.TestTimeout;
                const count = workers.poll(&output);
                if (count == 0) {
                    mox_io.sync.Thread.yield();
                    continue;
                }
                consumed += count;
                try testing.expect(count == 1 and workers.pending == submitted - consumed);
                try testing.expect(output[0].id.index == consumed - 1 and output[0].id.generation == 1);
                if (consumed == 1)
                    try testing.expect(output[0].status == .ok and output[0].bytes == 7)
                else
                    try testing.expect(output[0].status == .canceled and output[0].bytes == 0);
            }
            try testing.expect(job.calls == 0 and workers.pending == 0 and workers.poll(&output) == 0);

            // Reusing an idle pool must publish and consume the next generation normally.
            requests[0].id.generation = 2;
            requests[0].work = .{ .context = &job, .run = Job.run };
            submitted = 0;
            consumed = 0;
            try workers.submit(&requests[0]);
            submitted = 1;
            try testing.expect(workers.pending == 1);
            while (consumed == 0) {
                if (loop.now() >= deadline) return error.TestTimeout;
                consumed += workers.poll(&output);
                mox_io.sync.Thread.yield();
            }
            try testing.expect(output[0].id.generation == 2 and output[0].status == .ok and output[0].bytes == 37);
            try testing.expect(job.calls == 1 and workers.pending == 0 and workers.poll(&empty) == 0);
            try testing.expect(loop.stats().memory.allocations == allocations);
            if (shared) try testing.expect(executor.stats().jobs_active == 0);
        }

        test "local worker reservations survive cancellation empty polls and partial harvest" {
            try workerRetirement(false);
        }

        test "shared worker reservations survive cancellation empty polls and partial harvest" {
            try workerRetirement(true);
        }

        test "canceling running work waits for callback retirement" {
            var loop: Loop = undefined;
            try init(&loop);
            defer cleanup(&loop) catch unreachable;
            var gate: Gate = .{};
            defer gate.release.store(true, .release);
            const id = try loop.work(.{ .context = &gate, .run = Gate.run }, .{});
            try loop.pump(.none);
            const deadline = loop.now() + 5_000_000_000;
            while (!gate.entered.load(.acquire)) {
                if (loop.now() > deadline) return error.TestTimeout;
                mox_io.sync.Thread.yield();
            }
            _ = try loop.cancel(id);
            var result: [1]t.Completion = undefined;
            try testing.expect(try loop.poll(&result, .none) == 0);
            gate.release.store(true, .release);
            try gather(&loop, &result);
            try testing.expect(result[0].status == .canceled and result[0].bytes == 7);
        }

        test "operation groups preserve unrelated results and retire race losers" {
            var loop: Loop = undefined;
            try init(&loop);
            defer cleanup(&loop) catch unreachable;
            var storage: [2]mox_io.GroupEntry = undefined;
            var group = mox_io.Group(Loop).init(&loop, &storage, .any);
            const first = try loop.sleepUntil(1, 1);
            const loser = try loop.sleepUntil(~@as(u64, 0), 2);
            _ = try loop.sleepUntil(1, 3);
            try group.add(first);
            try group.add(loser);
            try testing.expectError(error.InvalidOptions, group.add(first));
            group.seal();
            var output: [4]t.Completion = undefined;
            const count = try group.poll(&output, .none);
            try testing.expect(count == 2 and group.ready() and group.completed == 1);
            try testing.expectError(error.Busy, group.reset(.all));
            try group.cancelRemaining();
            try testing.expect(try group.poll(&output, .none) == 1);
            try testing.expect(storage[1].result.?.status == .canceled);
            try group.reset(.all);
            try group.add(try loop.sleepUntil(1, 4));
            try group.add(try loop.sleepUntil(1, 5));
            group.seal();
            try testing.expect(!group.ready());
            try testing.expect(try group.poll(&output, .none) == 2);
            try testing.expect(group.ready());
        }

        test "system DNS resolver returns caller-owned loopback addresses" {
            var loop: Loop = undefined;
            try init(&loop);
            defer cleanup(&loop) catch unreachable;
            var addresses: [8]t.Address = undefined;
            var resolve: mox_io.net.Resolve = .{ .hostname = "localhost", .port = 4321, .output = &addresses, .family = .ipv4 };
            _ = try resolve.submit(&loop, .{});
            try testing.expectError(error.Busy, resolve.submit(&loop, .{}));
            var result: [1]t.Completion = undefined;
            try gather(&loop, &result);
            try testing.expect(resolve.complete(result[0]));
            try testing.expect(result[0].status == .ok and resolve.count != 0);
            for (addresses[0..resolve.count]) |address|
                try testing.expect(address.family == .ipv4 and address.bytes[0] == 127 and address.port == 4321);
        }

        test "socket options before listen and TCP half-close preserve reverse traffic" {
            var loop: Loop = undefined;
            try init(&loop);
            defer cleanup(&loop) catch unreachable;
            const listener = try loop.openTcp(.ipv4);
            try loop.socketOption(listener, .reuse_address, 1);
            try loop.listenOn(listener, t.Address.loopback(0), 8);
            const client = try loop.openTcp(.ipv4);
            try loop.socketOption(client, .keep_alive, 1);
            try testing.expect(try loop.getSocketOption(client, .keep_alive) != 0);
            try loop.socketOption(client, .send_buffer, 32768);
            try testing.expect(try loop.getSocketOption(client, .send_buffer) >= 32768);
            _ = try loop.accept(listener, .{});
            _ = try loop.connect(client, try loop.localAddress(listener), .{});
            var pair: [2]t.Completion = undefined;
            try gather(&loop, &pair);
            var peer: t.Handle = undefined;
            for (pair) |result| {
                try testing.expect(result.status == .ok);
                if (result.accepted) |value| peer = value;
            }
            try loop.shutdownSocket(client, .write);
            var bytes: [8]u8 = undefined;
            _ = try loop.recv(peer, &bytes, .{});
            var result: [1]t.Completion = undefined;
            try gather(&loop, &result);
            try testing.expect(result[0].status == .eof);
            _ = try loop.sendAll(peer, "reply", .{});
            _ = try loop.recvExact(client, bytes[0..5], .{});
            try gather(&loop, &pair);
            for (pair) |item| try testing.expect(item.status == .ok and item.bytes == 5);
            try testing.expectEqualStrings("reply", bytes[0..5]);
        }

        test "hostname dial advances through DNS and address fallback" {
            var loop: Loop = undefined;
            try init(&loop);
            defer cleanup(&loop) catch unreachable;
            const listener = try loop.listen(t.Address.loopback(0), 8);
            var addresses: [8]t.Address = undefined;
            var dial = mox_io.net.Dial(Loop).init(&loop, "localhost", (try loop.localAddress(listener)).port, &addresses);
            try dial.start(.{ .deadline = loop.now() + 5_000_000_000 });
            _ = try loop.accept(listener, .{});
            var accepted: ?t.Handle = null;
            var results: [8]t.Completion = undefined;
            const deadline = loop.now() + 10_000_000_000;
            while (!dial.ready() or accepted == null) {
                if (loop.now() >= deadline) return error.TestTimeout;
                const count = try loop.poll(&results, .{ .until = deadline });
                for (results[0..count]) |result| {
                    _ = try dial.complete(result);
                    if (result.kind == .accept) accepted = result.accepted;
                }
            }
            try testing.expect(dial.result.?.status == .ok);
            const client = try dial.takeHandle();
            try testing.expectError(error.InvalidState, dial.takeHandle());
            _ = try loop.sendAll(client, "x", .{});
            var byte: [1]u8 = undefined;
            _ = try loop.recvExact(accepted.?, &byte, .{});
            try gather(&loop, results[0..2]);
            try testing.expect(byte[0] == 'x');
            try dial.start(.{});
            try dial.cancel();
            try gather(&loop, results[0..1]);
            _ = try dial.complete(results[0]);
            try testing.expect(dial.ready() and dial.result.?.status == .canceled);
        }

        fn command(loop: *Loop, request: *mox_io.fs.Native.Request) !void {
            _ = try request.submit(loop, .{});
            var result: [1]t.Completion = undefined;
            try gather(loop, &result);
            try testing.expect(request.complete(result[0]));
            try testing.expect(result[0].status == .ok);
        }

        test "native directory commands and retained file resize cover the filesystem lifecycle" {
            var loop: Loop = undefined;
            try init(&loop);
            defer cleanup(&loop) catch unreachable;
            var request: mox_io.fs.Native.Request = .{ .action = .{ .make_dir = .{ .path = "out/native-extension-dir" } } };
            try command(&loop, &request);
            _ = try loop.openFileAsync("out/native-extension-dir/file", .{ .access = .read_write, .creation = .create_new }, .{});
            var result: [1]t.Completion = undefined;
            try gather(&loop, &result);
            try testing.expect(result[0].status == .ok);
            const file = result[0].opened.?;
            request = .{ .handle = file, .action = .{ .set_size = 32 } };
            try command(&loop, &request);
            _ = try loop.stat(file, .{});
            try gather(&loop, &result);
            try testing.expect(result[0].file_info.size == 32);
            if (builtin.os.tag != .windows) {
                request = .{ .handle = file, .action = .{ .set_permissions = 0o600 } };
                try command(&loop, &request);
            }
            var directory: mox_io.fs.Native.Directory = .{};
            request = .{ .action = .{ .open_dir = .{ .directory = &directory, .path = "out/native-extension-dir" } } };
            try command(&loop, &request);
            var name: [512]u8 = undefined;
            request = .{ .action = .{ .read_dir = .{ .directory = &directory, .name = &name } } };
            var tiny: [1]u8 = undefined;
            request.action.read_dir.name = &tiny;
            _ = try request.submit(&loop, .{});
            try gather(&loop, &result);
            _ = request.complete(result[0]);
            try testing.expect(result[0].status == .failed and result[0].library_error.? == error.Capacity);
            request.action.read_dir.name = &name;
            try command(&loop, &request);
            try testing.expectEqualStrings("file", request.entry.?.name);
            try command(&loop, &request);
            try testing.expect(request.entry == null);
            request = .{ .action = .{ .close_dir = &directory } };
            try command(&loop, &request);
            try loop.close(file, .drain, 0);
            try gather(&loop, &result);
            request = .{ .action = .{ .rename = .{ .from = "out/native-extension-dir/file", .to = "out/native-extension-dir/renamed" } } };
            try command(&loop, &request);
            request = .{ .action = .{ .delete_file = "out/native-extension-dir/renamed" } };
            try command(&loop, &request);
            request = .{ .action = .{ .remove_dir = "out/native-extension-dir" } };
            try command(&loop, &request);
        }

        test "worker pipes report EOF and reject closing borrowed endpoints" {
            var loop: Loop = undefined;
            try init(&loop);
            defer cleanup(&loop) catch unreachable;
            var pipe: mox_io.Pipe = .{};
            try pipe.init();
            defer pipe.deinit() catch unreachable;
            var buffer: [16]u8 = undefined;
            var read: mox_io.Pipe.Transfer = .{ .end = &pipe.reader, .read_buffer = &buffer };
            var write: mox_io.Pipe.Transfer = .{ .end = &pipe.writer, .write_buffer = "pipe-data" };
            _ = try read.submit(&loop, .{});
            _ = try write.submit(&loop, .{});
            try testing.expectError(error.Busy, pipe.reader.close());
            var results: [2]t.Completion = undefined;
            try gather(&loop, &results);
            for (results) |result| {
                try testing.expect(result.status == .ok and result.bytes == 9);
                _ = read.complete(result);
                _ = write.complete(result);
            }
            try testing.expectEqualStrings("pipe-data", buffer[0..9]);
            try pipe.writer.close();
            _ = try read.submit(&loop, .{});
            var result: [1]t.Completion = undefined;
            try gather(&loop, &result);
            _ = read.complete(result[0]);
            try testing.expect(result[0].status == .ok and read.eof);
        }

        test "broken pipe writes fail without terminating the process" {
            var loop: Loop = undefined;
            try init(&loop);
            defer cleanup(&loop) catch unreachable;
            var pipe: mox_io.Pipe = .{};
            try pipe.init();
            defer pipe.deinit() catch unreachable;
            try pipe.reader.close();
            var write: mox_io.Pipe.Transfer = .{ .end = &pipe.writer, .write_buffer = "x" };
            _ = try write.submit(&loop, .{});
            var result: [1]t.Completion = undefined;
            try gather(&loop, &result);
            _ = write.complete(result[0]);
            try testing.expect(result[0].status == .failed and write.native_error != 0);
        }

        test "child stdout redirection and asynchronous wait preserve exit status" {
            var loop: Loop = undefined;
            try init(&loop);
            defer cleanup(&loop) catch unreachable;
            var pipe: mox_io.Pipe = .{};
            try pipe.init();
            defer pipe.deinit() catch unreachable;
            var child: mox_io.process.Child = .{};
            const args: []const [:0]const u8 = if (builtin.os.tag == .windows) &.{ "cmd.exe", "/d", "/c", "echo child-marker" } else &.{ "/bin/sh", "-c", "printf child-marker" };
            try child.spawn(.{ .argv = args, .stdout = &pipe.writer, .windows_command_line = if (builtin.os.tag == .windows) "cmd.exe /d /s /c \"echo child-marker\"" else null });
            try pipe.writer.close();
            var bytes: [256]u8 = undefined;
            var read: mox_io.Pipe.Transfer = .{ .end = &pipe.reader, .read_buffer = &bytes };
            _ = try read.submit(&loop, .{});
            _ = try child.wait(&loop, .{});
            try testing.expectError(error.Busy, child.deinit());
            var results: [2]t.Completion = undefined;
            try gather(&loop, &results);
            var count: usize = 0;
            for (results) |result| {
                try testing.expect(result.status == .ok);
                if (read.complete(result)) count = result.bytes;
                _ = child.complete(result);
            }
            try testing.expect(std.mem.indexOf(u8, bytes[0..count], "child-marker") != null);
            try testing.expect(child.termination.?.exited == 0);
            try child.deinit();
        }

        test "worker spawn reports child exit codes" {
            var loop: Loop = undefined;
            try init(&loop);
            defer cleanup(&loop) catch unreachable;
            var child: mox_io.process.Child = .{};
            const args: []const [:0]const u8 = if (builtin.os.tag == .windows) &.{ "cmd.exe", "/d", "/c", "exit 7" } else &.{ "/bin/sh", "-c", "exit 7" };
            var spawn: mox_io.process.Spawn = .{ .child = &child, .options = .{ .argv = args, .windows_command_line = if (builtin.os.tag == .windows) "cmd.exe /d /s /c \"exit /b 7\"" else null } };
            _ = try spawn.submit(&loop, .{});
            var result: [1]t.Completion = undefined;
            try gather(&loop, &result);
            _ = spawn.complete(result[0]);
            try testing.expect(result[0].status == .ok);
            _ = try child.wait(&loop, .{});
            try gather(&loop, &result);
            _ = child.complete(result[0]);
            try testing.expect(result[0].status == .ok and child.termination.?.exited == 7);
            try child.deinit();
        }

        test "failed spawn leaves child reusable and reports native failure" {
            var loop: Loop = undefined;
            try init(&loop);
            defer cleanup(&loop) catch unreachable;
            var child: mox_io.process.Child = .{};
            var spawn: mox_io.process.Spawn = .{ .child = &child, .options = .{ .argv = &.{"mox-io-nonexistent-child-7c25e1"} } };
            _ = try spawn.submit(&loop, .{});
            var result: [1]t.Completion = undefined;
            try gather(&loop, &result);
            _ = spawn.complete(result[0]);
            try testing.expect(result[0].status == .failed and result[0].native_error != 0);
            try testing.expect(child.native == t.invalid_native and !child.spawning);
        }

        test "spawn argument quoting and working directory preserve literal arguments" {
            var loop: Loop = undefined;
            try init(&loop);
            defer cleanup(&loop) catch unreachable;
            var child: mox_io.process.Child = .{};
            var pipe: mox_io.Pipe = .{};
            try pipe.init();
            defer pipe.deinit() catch unreachable;
            // Use a private fixture so the cwd contract survives package relocation.
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.writeFile(testing.io, .{ .sub_path = "cwd-marker", .data = "" });
            var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const path_len = try tmp.dir.realPath(testing.io, &path_buffer);
            const cwd = try testing.allocator.dupeSentinel(u8, path_buffer[0..path_len], 0);
            defer testing.allocator.free(cwd);
            const args: []const [:0]const u8 = if (builtin.os.tag == .windows)
                &.{ "where.exe", "mox-io-argument-with-space and quote\" and slash\\" }
            else
                &.{ "/bin/sh", "-c", "test \"$1\" = 'space and quote\" and slash\\' && test -f cwd-marker && printf quoted", "sh", "space and quote\" and slash\\" };
            // Windows where.exe uses ordinary argv parsing and returns 1 for no match.
            try child.spawn(.{ .argv = args, .cwd = cwd, .stdout = &pipe.writer, .stderr = &pipe.writer });
            try pipe.writer.close();
            var bytes: [2048]u8 = undefined;
            var read: mox_io.Pipe.Transfer = .{ .end = &pipe.reader, .read_buffer = &bytes };
            _ = try read.submit(&loop, .{});
            _ = try child.wait(&loop, .{});
            var results: [2]t.Completion = undefined;
            try gather(&loop, &results);
            var count: usize = 0;
            for (results) |result| {
                try testing.expect(result.status == .ok);
                if (read.complete(result)) count = result.bytes;
                _ = child.complete(result);
            }
            try testing.expect(child.termination.?.exited == @as(u32, if (builtin.os.tag == .windows) 1 else 0));
            if (builtin.os.tag != .windows) try testing.expectEqualStrings("quoted", bytes[0..count]);
            try child.deinit();
        }

        test "shared executor runs portable work and retained file work orders close" {
            var executor: mox_io.fs.Executor = undefined;
            try executor.init(mox_io.mem.PageAllocator.allocator(), .{ .jobs = 16, .clients = 1, .threads = 2 });
            defer executor.deinit() catch unreachable;
            var loop: Loop = undefined;
            loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 4, .resources = 1, .file_executor = &executor }) catch |err| {
                if (Backend == mox_io.backends.Uring and err == error.BackendUnavailable) return error.SkipZigTest;
                return err;
            };
            defer cleanup(&loop) catch unreachable;
            _ = try loop.openFileAsync("out/extension-pinned-file", .{ .access = .read_write, .creation = .create_always }, .{});
            var result: [1]t.Completion = undefined;
            try gather(&loop, &result);
            try testing.expect(result[0].status == .ok);
            const file = result[0].opened.?;
            var gate: Gate = .{};
            defer gate.release.store(true, .release);
            const id = try loop.workOn(file, .{ .context = &gate, .run = Gate.run }, .{});
            try loop.pump(.none);
            const deadline = loop.now() + 5_000_000_000;
            while (!gate.entered.load(.acquire)) {
                if (loop.now() > deadline) return error.TestTimeout;
                mox_io.sync.Thread.yield();
            }
            try loop.close(file, .cancel, 91);
            try testing.expect(try loop.poll(&result, .none) == 0);
            gate.release.store(true, .release);
            var results: [2]t.Completion = undefined;
            try gather(&loop, &results);
            try testing.expect(results[0].id.?.index == id.index and results[0].status == .canceled);
            try testing.expect(results[1].kind == .close and results[1].tag == 91);
            try testing.expect(loop.backend.workers.pending == 0);
            var remove: mox_io.fs.Native.Request = .{ .action = .{ .delete_file = "out/extension-pinned-file" } };
            try command(&loop, &remove);
        }

        test "portable work without executor completes with backend unavailable" {
            var loop: Loop = undefined;
            loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 1, .resources = 1, .file_threads = 0 }) catch |err| {
                if (Backend == mox_io.backends.Uring and err == error.BackendUnavailable) return error.SkipZigTest;
                return err;
            };
            defer cleanup(&loop) catch unreachable;
            var job: Job = .{};
            _ = try loop.work(.{ .context = &job, .run = Job.run }, .{});
            var result: [1]t.Completion = undefined;
            try gather(&loop, &result);
            try testing.expect(result[0].status == .failed and result[0].library_error.? == error.BackendUnavailable and job.calls == 0);
            try testing.expect(loop.backend.workers.pending == 0);
        }

        test "async spawn borrows pipe ends until completion including queued cancellation" {
            var loop: Loop = undefined;
            try init(&loop);
            defer cleanup(&loop) catch unreachable;
            var pipe: mox_io.Pipe = .{};
            try pipe.init();
            defer pipe.deinit() catch unreachable;
            var child: mox_io.process.Child = .{};
            var spawn: mox_io.process.Spawn = .{ .child = &child, .options = .{ .argv = &.{"unused"}, .stdout = &pipe.writer } };
            const id = try spawn.submit(&loop, .{});
            try testing.expectError(error.Busy, pipe.writer.close());
            try testing.expectError(error.Busy, child.wait(&loop, .{}));
            try testing.expectError(error.Busy, spawn.submit(&loop, .{}));
            _ = try loop.cancel(id);
            var result: [1]t.Completion = undefined;
            try gather(&loop, &result);
            _ = spawn.complete(result[0]);
            try testing.expect(result[0].status == .canceled and child.native == t.invalid_native);
            try pipe.writer.close();
        }

        test "canceling a child wait permits explicit termination and safe reaping" {
            var loop: Loop = undefined;
            try init(&loop);
            defer cleanup(&loop) catch unreachable;
            var child: mox_io.process.Child = .{};
            var output: mox_io.Pipe = .{};
            try output.init();
            defer output.deinit() catch unreachable;
            const args: []const [:0]const u8 = if (builtin.os.tag == .windows) &.{ "ping.exe", "-n", "30", "127.0.0.1" } else &.{ "/bin/sh", "-c", "exec sleep 30" };
            try child.spawn(.{ .argv = args, .stdout = &output.writer });
            try output.writer.close();
            const id = try child.wait(&loop, .{});
            try loop.pump(.none);
            _ = try loop.cancel(id);
            try child.kill();
            var result: [1]t.Completion = undefined;
            try gather(&loop, &result);
            _ = child.complete(result[0]);
            try testing.expect(result[0].status == .canceled);
            // A queued cancellation may skip the wait callback altogether.
            if (!child.reaped) {
                _ = try child.wait(&loop, .{});
                try gather(&loop, &result);
                _ = child.complete(result[0]);
            }
            try testing.expect(child.termination != null);
            try child.deinit();
        }
    };
}
