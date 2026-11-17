//! A framed TCP service on independent owner threads and a child-pipe client.

const std = @import("std");
const mox_io = @import("mox_io");

const t = mox_io.types;
const builtin = @import("builtin");

pub fn Suite(comptime Backend: type) type {
    return struct {
        const Loop = mox_io.Loop(Backend);
        const frames = 32;

        fn init(loop: *Loop) !void {
            loop.init(mox_io.mem.PageAllocator.allocator(), .{ .operations = 8, .resources = 3, .file_threads = 3 }) catch |err| {
                if (Backend == mox_io.backends.Uring and err == error.BackendUnavailable) return error.SkipZigTest;
                return err;
            };
        }

        fn gather(loop: *Loop, output: []t.Completion) !void {
            var count: usize = 0;
            const deadline = loop.now() + 5_000_000_000;
            while (count < output.len) {
                if (loop.now() >= deadline) return error.ApplicationTimeout;
                count += try loop.poll(output[count..], .{ .until = deadline });
            }
        }

        fn one(loop: *Loop) !t.Completion {
            var result: [1]t.Completion = undefined;
            try gather(loop, &result);
            if (result[0].status != .ok) return error.ApplicationTransfer;
            return result[0];
        }

        fn close(loop: *Loop) void {
            loop.shutdown() catch @panic("application shutdown failed");
            const deadline = loop.now() + 5_000_000_000;
            var results: [8]t.Completion = undefined;
            while (loop.stats().active_resources != 0 or loop.stats().active_operations != 0 or loop.stats().completions_queued != 0) {
                if (loop.now() >= deadline) @panic("application drain timed out");
                _ = loop.poll(&results, .{ .until = deadline }) catch @panic("application drain failed");
            }
            loop.deinit() catch @panic("application deinit failed");
            if (loop.stats().memory.live_bytes != 0) @panic("application leaked memory");
        }

        const Client = struct {
            address: t.Address,
            failure: ?anyerror = null,
            frame_count: usize,

            fn entry(context: *anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(context));
                self.run() catch |err| {
                    self.failure = err;
                };
            }

            fn run(self: *@This()) !void {
                var loop: Loop = undefined;
                try init(&loop);
                defer close(&loop);
                const socket = try loop.openTcp(.ipv4);
                _ = try loop.connect(socket, self.address, .{});
                _ = try one(&loop);
                try loop.noDelay(socket, true);
                const allocations = loop.stats().memory.allocations;
                for (0..self.frame_count) |frame| {
                    const length = 1 + (frame * 137) % 2048;
                    const header: [2]u8 = .{ @intCast(length >> 8), @truncate(length) };
                    var payload: [2048]u8 = undefined;
                    for (payload[0..length], 0..) |*byte, index| byte.* = @truncate(frame + index);
                    // Deliberately split the header and body across transfers.
                    _ = try loop.sendAll(socket, header[0..1], .{});
                    _ = try one(&loop);
                    _ = try loop.sendAll(socket, header[1..], .{});
                    _ = try one(&loop);
                    _ = try loop.sendAll(socket, payload[0..length], .{});
                    _ = try one(&loop);
                    var response: [2048]u8 = undefined;
                    _ = try loop.recvExact(socket, response[0..length], .{});
                    const result = try one(&loop);
                    if (result.bytes != length) return error.ApplicationLength;
                    for (response[0..length], payload[0..length]) |actual, expected|
                        if (actual != expected ^ 0x5a) return error.ApplicationPayload;
                }
                try loop.shutdownSocket(socket, .write);
                var byte: [1]u8 = undefined;
                _ = try loop.recv(socket, &byte, .{});
                var result: [1]t.Completion = undefined;
                try gather(&loop, &result);
                if (result[0].status != .eof) return error.ApplicationEof;
                if (loop.stats().memory.allocations != allocations) return error.ApplicationAllocation;
            }
        };

        pub fn tcp() !void {
            return tcpFrames(frames);
        }

        pub fn tcpFrames(frame_count: usize) !void {
            var loop: Loop = undefined;
            try init(&loop);
            defer close(&loop);
            const listener = try loop.listen(t.Address.loopback(0), 8);
            var client: Client = .{ .address = try loop.localAddress(listener), .frame_count = frame_count };
            var thread: mox_io.sync.Thread = .{};
            try thread.start(Client.entry, &client);
            var joined = false;
            defer if (!joined) thread.join();
            _ = try loop.accept(listener, .{});
            const peer = (try one(&loop)).accepted.?;
            try loop.noDelay(peer, true);
            const allocations = loop.stats().memory.allocations;
            for (0..frame_count) |_| {
                var header: [2]u8 = undefined;
                _ = try loop.recvExact(peer, &header, .{});
                _ = try one(&loop);
                const length = @as(usize, header[0]) * 256 + header[1];
                if (length == 0 or length > 2048) return error.ApplicationFrame;
                var payload: [2048]u8 = undefined;
                _ = try loop.recvExact(peer, payload[0..length], .{});
                _ = try one(&loop);
                for (payload[0..length]) |*byte| byte.* ^= 0x5a;
                _ = try loop.sendAll(peer, payload[0..length], .{});
                _ = try one(&loop);
            }
            var byte: [1]u8 = undefined;
            _ = try loop.recv(peer, &byte, .{});
            var result: [1]t.Completion = undefined;
            try gather(&loop, &result);
            if (result[0].status != .eof) return error.ApplicationEof;
            try loop.shutdownSocket(peer, .write);
            thread.join();
            joined = true;
            if (client.failure) |err| return err;
            try std.testing.expect(loop.stats().memory.allocations == allocations);
        }

        pub fn childPipe() !void {
            var loop: Loop = undefined;
            try init(&loop);
            defer close(&loop);
            var input: mox_io.Pipe = .{};
            try input.init();
            defer input.deinit() catch unreachable;
            var output: mox_io.Pipe = .{};
            try output.init();
            defer output.deinit() catch unreachable;
            var child: mox_io.process.Child = .{};
            const args: []const [:0]const u8 = if (builtin.os.tag == .windows) &.{"sort.exe"} else &.{"sort"};
            try child.spawn(.{ .argv = args, .stdin = &input.reader, .stdout = &output.writer });
            defer {
                if (!child.reaped) {
                    child.kill() catch {};
                    _ = child.wait(&loop, .{}) catch @panic("child cleanup wait failed");
                    var result: [1]t.Completion = undefined;
                    gather(&loop, &result) catch @panic("child cleanup drain failed");
                    _ = child.complete(result[0]);
                }
                child.deinit() catch @panic("child cleanup failed");
            }
            try input.reader.close();
            try output.writer.close();
            var write: mox_io.Pipe.Transfer = .{ .end = &input.writer, .write_buffer = "zebra\napple\nmango\n" };
            _ = try write.submit(&loop, .{});
            var result: [1]t.Completion = undefined;
            try gather(&loop, &result);
            _ = write.complete(result[0]);
            try std.testing.expect(result[0].status == .ok and result[0].bytes == write.write_buffer.len);
            try input.writer.close();
            var bytes: [128]u8 = undefined;
            var used: usize = 0;
            while (true) {
                var read: mox_io.Pipe.Transfer = .{ .end = &output.reader, .read_buffer = bytes[used..] };
                if (used == bytes.len) return error.ApplicationLength;
                _ = try read.submit(&loop, .{});
                try gather(&loop, &result);
                _ = read.complete(result[0]);
                try std.testing.expect(result[0].status == .ok);
                used += result[0].bytes;
                if (read.eof) break;
            }
            var normalized: [128]u8 = undefined;
            var count: usize = 0;
            for (bytes[0..used]) |byte| if (byte != '\r') {
                normalized[count] = byte;
                count += 1;
            };
            try std.testing.expectEqualStrings("apple\nmango\nzebra\n", normalized[0..count]);
            _ = try child.wait(&loop, .{});
            try gather(&loop, &result);
            _ = child.complete(result[0]);
            try std.testing.expect(result[0].status == .ok and child.termination.?.exited == 0);
        }

        test "application framed TCP service across independent owner threads" {
            try tcp();
        }

        test "application child sort pipeline closes stdin drains stdout and reaps" {
            try childPipe();
        }
    };
}
