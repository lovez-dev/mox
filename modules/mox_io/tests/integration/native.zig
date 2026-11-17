//! Native socket, file, wakeup and cancellation integration contracts.

const mox_io = @import("mox_io");
const testing = @import("std").testing;

const t = mox_io.types;

pub fn Suite(comptime Backend: type) type {
    return struct {
        const Loop = mox_io.Loop(Backend);

        test "native TCP connect, accept and binary transfer" {
            try prepare();
            try tcp();
        }

        test "native read timeout retires buffers before close" {
            try prepare();
            try timeout();
        }

        test "native UDP preserves payload and sender address" {
            try prepare();
            try udp();
        }

        test "native file offset writes and reads preserve data" {
            try prepare();
            try file();
        }

        test "native file sync and EOF preserve completion semantics" {
            try prepare();
            try fileEof();
        }

        test "native UDP truncation and empty datagrams stay distinct" {
            try prepare();
            try udpBoundaries();
        }

        test "native timer wakes an idle loop and shutdown cancels future timers" {
            try prepare();
            try timers();
        }

        test "native inbox wakes the owner and preserves per-producer ordering" {
            try prepare();
            inbox() catch |err| {
                @import("std").debug.print("inbox backend={s} error={s}\n", .{ @typeName(Backend), @errorName(err) });
                return err;
            };
        }

        test "native pending accept retires before listener close at full capacity" {
            try prepare();
            try acceptClose();
        }

        test "native asynchronous open and metadata preserve resource ownership" {
            try prepare();
            try asyncFile();
        }

        test "native legacy and option opens preserve creation semantics" {
            try prepare();
            try fileOpenModes();
        }

        test "native failed and canceled opens release reserved resources" {
            try prepare();
            try openFailure();
        }

        test "native cancellation survives repeated operation slot reuse" {
            try prepare();
            try cancelReuse();
        }

        test "native loops share a bounded executor and account for memory separately" {
            try prepare();
            try sharedExecutor();
        }

        /// Reuse native lifecycle checks during the bounded stress test.
        pub fn repeat() !void {
            try prepare();
            try tcp();
            try timeout();
            try udp();
            try file();
            try fileEof();
            try udpBoundaries();
            try timers();
            try inbox();
            try acceptClose();
            try asyncFile();
            try openFailure();
            try cancelReuse();
            try sharedExecutor();
        }

        fn prepare() !void {
            if (@import("builtin").os.tag == .linux and Backend == mox_io.backends.Uring) {
                if (!try Backend.probe()) return error.SkipZigTest;
            }
            try @import("std").Io.Dir.cwd().createDirPath(testing.io, "out");
        }

        fn until() t.Wait {
            return .{ .until = mox_io.os.now() + 5_000_000_000 };
        }

        fn gather(loop: *Loop, results: []t.Completion) !void {
            return gatherResults(loop, results, false);
        }

        fn gatherResults(loop: *Loop, results: []t.Completion, reject_failed: bool) !void {
            var count: usize = 0;
            const deadline = mox_io.os.now() + 5_000_000_000;
            while (count < results.len) {
                if (mox_io.os.now() >= deadline) {
                    @import("std").debug.print("native timeout backend={s} delivered={d}/{d} stats={any}\n", .{ @typeName(Backend), count, results.len, loop.stats() });
                    for (results[0..count]) |result|
                        @import("std").debug.print("delivered kind={s} status={s} code={d} library={any}\n", .{ @tagName(result.kind), @tagName(result.status), result.native_error, result.library_error });
                    return error.TestTimeout;
                }
                const received = try loop.poll(results[count..], .{ .until = deadline });
                if (reject_failed) for (results[count..][0..received]) |result| {
                    if (result.status == .failed) {
                        @import("std").debug.print("native failure backend={s} kind={s} code={d} library={any}\n", .{ @typeName(Backend), @tagName(result.kind), result.native_error, result.library_error });
                        return error.NativeOperationFailed;
                    }
                };
                count += received;
            }
        }

        fn pair(loop: *Loop) !struct { listener: t.Handle, client: t.Handle, peer: t.Handle } {
            // A failed connect must retire the still-pending accept before unwinding.
            errdefer drain(loop) catch @panic("connection setup cleanup failed");
            const listener = try loop.listen(t.Address.loopback(0), 16);
            const client = try loop.openTcp(.ipv4);
            _ = try loop.accept(listener, .{ .tag = 1 });
            _ = try loop.connect(client, try loop.localAddress(listener), .{ .tag = 2 });
            var results: [2]t.Completion = undefined;
            try gatherResults(loop, &results, true);
            var peer: ?t.Handle = null;
            for (results) |result| {
                try testing.expect(result.status == .ok);
                if (result.kind == .accept) peer = result.accepted;
            }
            return .{ .listener = listener, .client = client, .peer = peer orelse return error.AcceptMissing };
        }

        fn drain(loop: *Loop) !void {
            try loop.shutdown();
            var results: [32]t.Completion = undefined;
            const deadline = mox_io.os.now() + 5_000_000_000;
            while (loop.stats().active_operations != 0 or loop.stats().active_resources != 0) {
                if (mox_io.os.now() >= deadline) return error.DrainTimeout;
                _ = try loop.poll(&results, .{ .until = deadline });
            }
            try loop.deinit();
            try testing.expect(loop.stats().memory.live_bytes == 0);
        }

        fn tcp() !void {
            var loop: Loop = undefined;
            try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 16, .resources = 8, .events = 8 });
            const sockets = try pair(&loop);
            const allocator = mox_io.mem.PageAllocator.allocator();
            const input = try allocator.allocate(32771, 64);
            defer allocator.release(input);
            const output = try allocator.allocate(32771, 64);
            defer allocator.release(output);
            for (input.bytes[0..32771], 0..) |*byte, index| byte.* = @truncate(index *% 31 +% 7);
            _ = try loop.recvExact(sockets.peer, output.bytes[0..32771], .{});
            _ = try loop.sendAll(sockets.client, input.bytes[0..32771], .{});
            var results: [2]t.Completion = undefined;
            try gather(&loop, &results);
            for (results) |result| try testing.expect(result.status == .ok and result.bytes == 32771);
            try testing.expect(mox_io.mem.bytes.equal(input.bytes[0..32771], output.bytes[0..32771]));
            try testing.expect(loop.stats().memory.allocations == 1 and loop.stats().bytes_read == 32771 and loop.stats().bytes_written == 32771);
            try drain(&loop);
        }

        fn timeout() !void {
            var loop: Loop = undefined;
            try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 8, .resources = 4 });
            const sockets = try pair(&loop);
            var buffer: [8]u8 = undefined;
            _ = try loop.recv(sockets.peer, &buffer, .{ .deadline = mox_io.os.now() + 1_000_000 });
            var result: [1]t.Completion = undefined;
            try gather(&loop, &result);
            try testing.expect(result[0].status == .timed_out);
            @memset(&buffer, 0);
            _ = try loop.sendAll(sockets.client, "ok", .{});
            _ = try loop.recvExact(sockets.peer, buffer[0..2], .{});
            var transfer: [2]t.Completion = undefined;
            try gather(&loop, &transfer);
            for (transfer) |completed| try testing.expect(completed.status == .ok);
            try testing.expect(mox_io.mem.bytes.equal("ok", buffer[0..2]));
            try drain(&loop);
        }

        fn udp() !void {
            var loop: Loop = undefined;
            try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 4, .resources = 2 });
            const sender = try loop.bindUdp(t.Address.loopback(0));
            const receiver = try loop.bindUdp(t.Address.loopback(0));
            var buffer: [32]u8 = undefined;
            _ = try loop.recvFrom(receiver, &buffer, .{});
            _ = try loop.sendTo(sender, "datagram", try loop.localAddress(receiver), .{});
            var results: [2]t.Completion = undefined;
            try gather(&loop, &results);
            for (results) |result| {
                try testing.expect(result.status == .ok and result.bytes == 8);
                if (result.kind == .recv_from) try testing.expect(result.peer.port == (try loop.localAddress(sender)).port);
            }
            try testing.expect(mox_io.mem.bytes.equal(buffer[0..8], "datagram"));
            try drain(&loop);
        }

        fn file() !void {
            defer @import("std").Io.Dir.cwd().deleteFile(testing.io, "out/mox-io-file-test.bin") catch {};
            var loop: Loop = undefined;
            try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 8, .resources = 2 });
            const descriptor = try loop.openFile("out/mox-io-file-test.bin", true, true);
            _ = try loop.writeAllAt(descriptor, "left", 0, .{});
            _ = try loop.writeAllAt(descriptor, "right", 4, .{});
            var results: [2]t.Completion = undefined;
            try gather(&loop, &results);
            for (results) |result| try testing.expect(result.status == .ok);
            var buffer: [9]u8 = undefined;
            _ = try loop.readExactAt(descriptor, &buffer, 0, .{});
            var read: [1]t.Completion = undefined;
            try gather(&loop, &read);
            try testing.expect(read[0].status == .ok and mox_io.mem.bytes.equal(&buffer, "leftright"));
            try drain(&loop);
        }

        fn fileEof() !void {
            defer @import("std").Io.Dir.cwd().deleteFile(testing.io, "out/mox-io-eof-test.bin") catch {};
            var loop: Loop = undefined;
            try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 4, .resources = 1 });
            const descriptor = try loop.openFile("out/mox-io-eof-test.bin", true, true);
            _ = try loop.writeAllAt(descriptor, "abc", 0, .{});
            var result: [1]t.Completion = undefined;
            try gather(&loop, &result);
            try testing.expect(result[0].status == .ok);
            _ = try loop.sync(descriptor, .{});
            try gather(&loop, &result);
            try testing.expect(result[0].status == .ok);
            var buffer: [8]u8 = undefined;
            _ = try loop.readExactAt(descriptor, &buffer, 0, .{});
            try gather(&loop, &result);
            try testing.expect(result[0].status == .eof and result[0].bytes == 3 and mox_io.mem.bytes.equal(buffer[0..3], "abc"));
            _ = try loop.readAt(descriptor, &buffer, 64, .{});
            try gather(&loop, &result);
            try testing.expect(result[0].status == .eof and result[0].bytes == 0);
            try testing.expect(try loop.poll(&result, .none) == 0);
            try drain(&loop);
        }

        fn udpBoundaries() !void {
            var loop: Loop = undefined;
            try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 4, .resources = 2 });
            const sender = try loop.bindUdp(t.Address.loopback(0));
            const receiver = try loop.bindUdp(t.Address.loopback(0));
            const destination = try loop.localAddress(receiver);
            var buffer: [3]u8 = undefined;
            _ = try loop.recvFrom(receiver, &buffer, .{});
            _ = try loop.sendTo(sender, "long datagram", destination, .{});
            var results: [2]t.Completion = undefined;
            try gather(&loop, &results);
            for (results) |result| {
                try testing.expect(result.status == .ok);
                if (result.kind == .recv_from) try testing.expect(result.truncated and result.bytes == 3 and mox_io.mem.bytes.equal(&buffer, "lon"));
            }
            _ = try loop.recvFrom(receiver, &buffer, .{});
            _ = try loop.sendTo(sender, "", destination, .{});
            try gather(&loop, &results);
            for (results) |result| try testing.expect(result.status == .ok and result.bytes == 0 and !result.truncated);
            // Submit a receive after the datagram has already reached the socket.
            _ = try loop.sendTo(sender, "already queued", destination, .{});
            var sent: [1]t.Completion = undefined;
            try gather(&loop, &sent);
            _ = try loop.recvFrom(receiver, &buffer, .{});
            try gather(&loop, &sent);
            try testing.expect(sent[0].status == .ok and sent[0].truncated and sent[0].bytes == 3);
            try drain(&loop);
        }

        fn timers() !void {
            var loop: Loop = undefined;
            try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 2, .resources = 1, .file_threads = 0 });
            const start = loop.now();
            _ = try loop.sleepFor(1_000_000, 3);
            var result: [1]t.Completion = undefined;
            try gather(&loop, &result);
            try testing.expect(result[0].kind == .timer and result[0].status == .ok and loop.now() >= start + 1_000_000);
            _ = try loop.sleepFor(60_000_000_000, 4);
            try loop.shutdown();
            try gather(&loop, &result);
            try testing.expect(result[0].status == .canceled and result[0].tag == 4);
            try loop.deinit();
        }

        const Aggregate = struct { next: [4]usize = @splat(0), total: usize = 0, invalid: bool = false };

        const Task = struct { aggregate: *Aggregate, producer: usize, sequence: usize };

        const Producer = struct { loop: *Loop, tasks: []Task, failed: u32 = 0 };

        fn receiveTask(context: ?*anyopaque, _: *Loop) void {
            const task: *Task = @ptrCast(@alignCast(context.?));
            const aggregate = task.aggregate;
            if (aggregate.next[task.producer] != task.sequence) aggregate.invalid = true;
            aggregate.next[task.producer] += 1;
            aggregate.total += 1;
        }

        fn produce(context: *anyopaque) void {
            const producer: *Producer = @ptrCast(@alignCast(context));
            if (producer.loop.sleepUntil(1, 0)) |_| {
                @atomicStore(u32, &producer.failed, 1, .release);
            } else |err| {
                if (err != error.WrongThread) @atomicStore(u32, &producer.failed, 1, .release);
            }
            for (producer.tasks) |*task| {
                while (true) {
                    producer.loop.post(.{ .task = .{ .context = task, .run = receiveTask } }) catch |err| {
                        if (err == error.QueueFull) {
                            mox_io.sync.Thread.yield();
                            continue;
                        }
                        @atomicStore(u32, &producer.failed, 1, .release);
                        return;
                    };
                    break;
                }
            }
        }

        pub fn inbox() !void {
            var loop: Loop = undefined;
            try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 1, .resources = 1, .events = 8, .inbox = 8, .file_threads = 0 });
            var aggregate: Aggregate = .{};
            var tasks: [4][512]Task = undefined;
            var producers: [4]Producer = undefined;
            var threads: [4]mox_io.sync.Thread = undefined;
            var started: usize = 0;
            defer {
                loop.closeInbox() catch {};
                for (threads[0..started]) |*thread| thread.join();
            }
            for (&producers, &tasks, &threads, 0..) |*producer, *batch, *thread, index| {
                for (batch, 0..) |*task, sequence| task.* = .{ .aggregate = &aggregate, .producer = index, .sequence = sequence };
                producer.* = .{ .loop = &loop, .tasks = batch };
                try thread.start(produce, producer);
                started += 1;
            }
            var results: [1]t.Completion = undefined;
            const deadline = loop.now() + 10_000_000_000;
            var nonblocking = true;
            while (aggregate.total < 4 * 512) {
                if (loop.now() >= deadline) {
                    @import("std").debug.print("inbox timeout delivered={d} stats={any}\n", .{ aggregate.total, loop.stats().inbox });
                    return error.InboxTimeout;
                }
                // Alternate busy polling and waits to exercise notification rearming.
                const wait: t.Wait = if (nonblocking) .none else .{ .until = deadline };
                nonblocking = !nonblocking;
                _ = loop.poll(&results, wait) catch |err| {
                    @import("std").debug.print("inbox poll native_error={d} delivered={d} stats={any}\n", .{ loop.backend.last_error, aggregate.total, loop.stats().inbox });
                    return err;
                };
            }
            for (threads[0..started]) |*thread| thread.join();
            started = 0;
            try testing.expect(!aggregate.invalid);
            for (producers) |producer| try testing.expect(@atomicLoad(u32, &producer.failed, .acquire) == 0);
            const stats = loop.stats();
            try testing.expect(stats.inbox.posted == 4 * 512 and stats.inbox.processed == 4 * 512 and stats.inbox.queued == 0);
            try testing.expect(stats.inbox.high_water <= 8 and stats.inbox.active_producers == 0 and stats.memory.allocations == 1);
            try loop.deinit();
        }

        fn acceptClose() !void {
            var loop: Loop = undefined;
            try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 1, .resources = 2 });
            const listener = try loop.listen(t.Address.loopback(0), 8);
            _ = try loop.accept(listener, .{ .tag = 7 });
            try loop.pump(.none);
            try loop.close(listener, .cancel, 8);
            var results: [2]t.Completion = undefined;
            try gather(&loop, &results);
            try testing.expect(results[0].kind == .accept and results[0].status == .canceled and results[0].tag == 7);
            try testing.expect(results[1].kind == .close and results[1].status == .ok and results[1].tag == 8);
            try testing.expect(loop.stats().active_resources == 0 and loop.stats().active_operations == 0);
            try loop.deinit();
        }

        fn asyncFile() !void {
            defer @import("std").Io.Dir.cwd().deleteFile(testing.io, "out/mox-io-async-file.bin") catch {};
            var loop: Loop = undefined;
            try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 4, .resources = 1 });
            _ = try loop.openFileAsync("out/mox-io-async-file.bin", .{ .access = .read_write, .creation = .create_always }, .{ .tag = 17 });
            try testing.expect(loop.stats().active_resources == 1);
            var result: [1]t.Completion = undefined;
            try gather(&loop, &result);
            try testing.expect(result[0].status == .ok and result[0].kind == .open and result[0].tag == 17);
            const descriptor = result[0].opened orelse return error.OpenMissing;
            _ = try loop.writeAllAt(descriptor, "async data", 0, .{});
            try gather(&loop, &result);
            try testing.expect(result[0].status == .ok and result[0].bytes == 10);
            _ = try loop.stat(descriptor, .{ .tag = 18 });
            try gather(&loop, &result);
            try testing.expect(result[0].status == .ok and result[0].file_info.kind == .file and result[0].file_info.size == 10);
            try testing.expect(result[0].file_info.modified.seconds > 0);
            try testing.expect(loop.stats().memory.allocations == 1 and loop.stats().native.worker_jobs >= 2);
            try drain(&loop);
        }

        fn fileOpenModes() !void {
            const path = "out/mox-io-open-modes.bin";
            defer @import("std").Io.Dir.cwd().deleteFile(testing.io, path) catch {};
            var loop: Loop = undefined;
            try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 2, .resources = 1 });
            errdefer drain(&loop) catch @panic("file mode cleanup failed");
            var result: [1]t.Completion = undefined;
            try testing.expectError(error.InvalidOptions, loop.openFile("bad\x00path", false, false));
            try testing.expectError(error.InvalidOptions, loop.openFileAsync("bad\x00path", .{}, .{}));
            try testing.expect(loop.stats().active_resources == 0 and loop.stats().active_operations == 0);

            const initial = try loop.openFile(path, true, true);
            _ = try loop.writeAllAt(initial, "retained", 0, .{});
            try gather(&loop, &result);
            try testing.expect(result[0].status == .ok and result[0].bytes == 8);
            try loop.close(initial, .drain, 0);
            try gather(&loop, &result);

            // Both setup and worker opens must retain existing contents.
            const legacy = try loop.openFile(path, false, false);
            var data: [8]u8 = undefined;
            _ = try loop.readExactAt(legacy, &data, 0, .{});
            try gather(&loop, &result);
            try testing.expect(result[0].status == .ok);
            try testing.expectEqualStrings("retained", &data);
            try loop.close(legacy, .drain, 0);
            try gather(&loop, &result);
            for ([_]mox_io.fs.Creation{ .open_existing, .open_or_create }) |creation| {
                _ = try loop.openFileAsync(path, .{ .access = .read_write, .creation = creation }, .{});
                try gather(&loop, &result);
                try testing.expect(result[0].status == .ok);
                const handle = result[0].opened.?;
                _ = try loop.readExactAt(handle, &data, 0, .{});
                try gather(&loop, &result);
                try testing.expect(result[0].status == .ok);
                try testing.expectEqualStrings("retained", &data);
                try loop.close(handle, .drain, 0);
                try gather(&loop, &result);
            }
            _ = try loop.openFileAsync(path, .{ .access = .read_write, .creation = .create_new }, .{});
            try gather(&loop, &result);
            try testing.expect(result[0].status == .failed and result[0].native_error != 0 and result[0].opened == null);
            try testing.expect(loop.stats().active_resources == 0);

            _ = try loop.openFileAsync(path, .{ .access = .read_write, .creation = .truncate_existing }, .{});
            try gather(&loop, &result);
            try testing.expect(result[0].status == .ok);
            const truncated = result[0].opened.?;
            _ = try loop.stat(truncated, .{});
            try gather(&loop, &result);
            try testing.expect(result[0].status == .ok and result[0].file_info.size == 0);
            _ = try loop.writeAllAt(truncated, "replace", 0, .{});
            try gather(&loop, &result);
            try testing.expect(result[0].status == .ok);
            try loop.close(truncated, .drain, 0);
            try gather(&loop, &result);

            // The legacy create flag retains its create-and-truncate contract.
            const recreated = try loop.openFile(path, true, true);
            _ = try loop.stat(recreated, .{});
            try gather(&loop, &result);
            try testing.expect(result[0].status == .ok and result[0].file_info.size == 0);
            try loop.close(recreated, .drain, 0);
            try gather(&loop, &result);
            try @import("std").Io.Dir.cwd().deleteFile(testing.io, path);
            _ = try loop.openFileAsync(path, .{ .access = .write, .creation = .truncate_existing }, .{});
            try gather(&loop, &result);
            try testing.expect(result[0].status == .failed and result[0].native_error != 0 and result[0].opened == null);
            try testing.expect(loop.stats().active_resources == 0 and loop.stats().active_operations == 0);
            try loop.deinit();
        }

        fn openFailure() !void {
            defer @import("std").Io.Dir.cwd().deleteFile(testing.io, "out/mox-io-canceled-open.bin") catch {};
            var loop: Loop = undefined;
            try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 2, .resources = 1 });
            const canceled = try loop.openFileAsync("out/mox-io-canceled-open.bin", .{ .access = .read_write, .creation = .create_always }, .{});
            _ = try loop.cancel(canceled);
            var result: [1]t.Completion = undefined;
            try gather(&loop, &result);
            try testing.expect(result[0].status == .canceled and result[0].opened == null);
            try testing.expect(loop.stats().active_resources == 0 and loop.stats().native.submissions == 0);
            _ = try loop.openFileAsync("out/mox-io-missing-parent/no-file.bin", .{}, .{});
            try gather(&loop, &result);
            try testing.expect(result[0].status == .failed and result[0].native_error != 0 and result[0].opened == null);
            try testing.expect(loop.stats().active_resources == 0);
            try loop.deinit();
        }

        fn cancelReuse() !void {
            var loop: Loop = undefined;
            try loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 4, .resources = 4, .events = 1 });
            const sockets = try pair(&loop);
            var buffer: [8]u8 = undefined;
            var result: [1]t.Completion = undefined;
            for (0..128) |_| {
                const id = try loop.recv(sockets.peer, &buffer, .{});
                try loop.pump(.none);
                _ = try loop.cancel(id);
                try gather(&loop, &result);
                try testing.expect(result[0].status == .canceled and result[0].bytes == 0);
                try testing.expectError(error.StaleOperation, loop.cancel(id));
                @memset(&buffer, 0xcc);
            }
            _ = try loop.recvExact(sockets.peer, buffer[0..2], .{});
            _ = try loop.sendAll(sockets.client, "ok", .{});
            var results: [2]t.Completion = undefined;
            try gather(&loop, &results);
            try testing.expect(mox_io.mem.bytes.equal(buffer[0..2], "ok") and loop.stats().canceled == 128);
            try drain(&loop);
        }

        fn sharedExecutor() !void {
            defer @import("std").Io.Dir.cwd().deleteFile(testing.io, "out/mox-io-shared-first.bin") catch {};
            defer @import("std").Io.Dir.cwd().deleteFile(testing.io, "out/mox-io-shared-second.bin") catch {};
            var tracking: mox_io.mem.TrackingAllocator = .{ .parent = mox_io.mem.PageAllocator.allocator() };
            var executor: mox_io.fs.Executor = undefined;
            try executor.init(tracking.allocator(), .{ .jobs = 10, .clients = 2, .threads = 2, .path_capacity = 128 });
            var first: Loop = undefined;
            var second: Loop = undefined;
            const options: t.Options = .{ .operations = 4, .resources = 1, .path_capacity = 128, .file_executor = &executor };
            try first.init(tracking.allocator(), options);
            try second.init(tracking.allocator(), options);
            try testing.expect(executor.stats().clients == 2 and first.stats().native.shared_executor and second.stats().native.shared_executor);
            try testing.expectError(error.Busy, executor.deinit());
            var rejected: Loop = undefined;
            try testing.expectError(error.Capacity, rejected.init(tracking.allocator(), options));
            try testing.expect(rejected.stats().memory.live_bytes == 0 and executor.stats().clients == 2);
            _ = try first.openFileAsync("out/mox-io-shared-first.bin", .{ .access = .read_write, .creation = .create_always }, .{});
            _ = try second.openFileAsync("out/mox-io-shared-second.bin", .{ .access = .read_write, .creation = .create_always }, .{});
            var result: [1]t.Completion = undefined;
            try gather(&first, &result);
            try testing.expect(result[0].status == .ok);
            try gather(&second, &result);
            const descriptor = result[0].opened orelse return error.SharedOpenMissing;
            try testing.expect(tracking.stats().live_bytes == executor.stats().memory.live_bytes + first.stats().memory.live_bytes + second.stats().memory.live_bytes);
            try drain(&first);
            try testing.expect(executor.stats().clients == 1 and executor.stats().workers == 2);
            _ = try second.stat(descriptor, .{});
            try gather(&second, &result);
            try testing.expect(result[0].status == .ok and result[0].file_info.size == 0);
            try drain(&second);
            try executor.deinit();
            try testing.expect(tracking.stats().live_bytes == 0 and tracking.stats().allocations == tracking.stats().releases);
        }
    };
}
