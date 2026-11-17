//! Source API sentinels: signature and default changes require an explicit review.

const std = @import("std");
const mox_io = @import("mox_io");

const t = mox_io.types;
const Loop = mox_io.DefaultLoop;

fn signature(comptime actual: type, comptime expected: type) void {
    if (actual != expected) @compileError("public API signature changed");
}

test "public Runtime signatures and defaults preserve owner and admission contracts" {
    const Runtime = mox_io.DefaultRuntime;

    comptime {
        signature(@TypeOf(Runtime.init), fn (*Runtime, mox_io.mem.Allocator, Runtime.Options) mox_io.Error!void);
        signature(@TypeOf(Runtime.start), fn (*Runtime, Runtime.Hooks) mox_io.Error!void);
        signature(@TypeOf(Runtime.post), fn (*Runtime, Runtime.Task) mox_io.Error!usize);
        signature(@TypeOf(Runtime.postTo), fn (*Runtime, usize, Runtime.Task) mox_io.Error!void);
        signature(@TypeOf(Runtime.shutdown), fn (*Runtime) void);
        signature(@TypeOf(Runtime.join), fn (*Runtime) mox_io.Error!void);
        signature(@TypeOf(Runtime.deinit), fn (*Runtime) mox_io.Error!void);
        signature(@TypeOf(Runtime.stats), fn (*Runtime) Runtime.Stats);
        signature(@TypeOf(Runtime.failure), fn (*Runtime) ?Runtime.Failure);
        signature(@TypeOf(Runtime.Worker.loop), fn (*Runtime.Worker) *Runtime.Loop);
        signature(@TypeOf(Runtime.Worker.runtime), fn (*Runtime.Worker) *Runtime);
    }
    const options: Runtime.Options = .{};
    try std.testing.expect(options.threads == 0 and options.queue_capacity == 256 and options.completion_batch == 64);
    try std.testing.expect(options.loop.file_threads == 0 and options.loop.inbox == 0);
}

test "public completion API signatures and conservative defaults remain compatible" {
    comptime {
        signature(@TypeOf(Loop.init), fn (*Loop, mox_io.mem.Allocator, t.Options) mox_io.Error!void);
        signature(@TypeOf(Loop.memoryRequired), fn (t.Options) mox_io.Error!usize);
        signature(@TypeOf(Loop.deinit), fn (*Loop) mox_io.Error!void);
        signature(@TypeOf(Loop.poll), fn (*Loop, []t.Completion, t.Wait) mox_io.Error!usize);
        signature(@TypeOf(Loop.pump), fn (*Loop, t.Wait) mox_io.Error!void);
        signature(@TypeOf(Loop.post), fn (*Loop, Loop.Command) mox_io.Error!void);
        signature(@TypeOf(Loop.closeInbox), fn (*Loop) mox_io.Error!void);
        signature(@TypeOf(Loop.now), fn (*const Loop) u64);
        signature(@TypeOf(Loop.cachedNow), fn (*const Loop) u64);
        signature(@TypeOf(Loop.sleepUntil), fn (*Loop, u64, usize) mox_io.Error!t.OpId);
        signature(@TypeOf(Loop.sleepFor), fn (*Loop, u64, usize) mox_io.Error!t.OpId);
        signature(@TypeOf(Loop.adopt), fn (*Loop, usize, t.ResourceKind, bool) mox_io.Error!t.Handle);
        signature(@TypeOf(Loop.openTcp), fn (*Loop, t.Address.Family) mox_io.Error!t.Handle);
        signature(@TypeOf(Loop.listen), fn (*Loop, t.Address, u32) mox_io.Error!t.Handle);
        signature(@TypeOf(Loop.bindUdp), fn (*Loop, t.Address) mox_io.Error!t.Handle);
        signature(@TypeOf(Loop.openFile), fn (*Loop, []const u8, bool, bool) mox_io.Error!t.Handle);
        signature(@TypeOf(Loop.openFileAsync), fn (*Loop, []const u8, t.FileOpenOptions, t.SubmitOptions) mox_io.Error!t.OpId);
        signature(@TypeOf(Loop.localAddress), fn (*Loop, t.Handle) mox_io.Error!t.Address);
        signature(@TypeOf(Loop.noDelay), fn (*Loop, t.Handle, bool) mox_io.Error!void);
        signature(@TypeOf(Loop.socketOption), fn (*Loop, t.Handle, mox_io.net.SocketOption, i32) mox_io.Error!void);
        signature(@TypeOf(Loop.getSocketOption), fn (*Loop, t.Handle, mox_io.net.SocketOption) mox_io.Error!i32);
        signature(@TypeOf(Loop.shutdownSocket), fn (*Loop, t.Handle, mox_io.net.Shutdown) mox_io.Error!void);
        signature(@TypeOf(Loop.listenOn), fn (*Loop, t.Handle, t.Address, u32) mox_io.Error!void);
        signature(@TypeOf(Loop.accept), fn (*Loop, t.Handle, t.SubmitOptions) mox_io.Error!t.OpId);
        signature(@TypeOf(Loop.connect), fn (*Loop, t.Handle, t.Address, t.SubmitOptions) mox_io.Error!t.OpId);
        signature(@TypeOf(Loop.cancel), fn (*Loop, t.OpId) mox_io.Error!t.CancelResult);
        signature(@TypeOf(Loop.close), fn (*Loop, t.Handle, t.CloseMode, usize) mox_io.Error!void);
        signature(@TypeOf(Loop.work), fn (*Loop, t.Work, t.SubmitOptions) mox_io.Error!t.OpId);
        signature(@TypeOf(Loop.workOn), fn (*Loop, t.Handle, t.Work, t.SubmitOptions) mox_io.Error!t.OpId);
        signature(@TypeOf(Loop.stats), fn (*const Loop) mox_io.Stats);
        signature(@TypeOf(Loop.recv), fn (*Loop, t.Handle, []u8, t.SubmitOptions) mox_io.Error!t.OpId);
        signature(@TypeOf(Loop.recvExact), fn (*Loop, t.Handle, []u8, t.SubmitOptions) mox_io.Error!t.OpId);
        signature(@TypeOf(Loop.send), fn (*Loop, t.Handle, []const u8, t.SubmitOptions) mox_io.Error!t.OpId);
        signature(@TypeOf(Loop.sendAll), fn (*Loop, t.Handle, []const u8, t.SubmitOptions) mox_io.Error!t.OpId);
        signature(@TypeOf(Loop.recvFrom), fn (*Loop, t.Handle, []u8, t.SubmitOptions) mox_io.Error!t.OpId);
        signature(@TypeOf(Loop.sendTo), fn (*Loop, t.Handle, []const u8, t.Address, t.SubmitOptions) mox_io.Error!t.OpId);
        signature(@TypeOf(Loop.readAt), fn (*Loop, t.Handle, []u8, u64, t.SubmitOptions) mox_io.Error!t.OpId);
        signature(@TypeOf(Loop.readExactAt), fn (*Loop, t.Handle, []u8, u64, t.SubmitOptions) mox_io.Error!t.OpId);
        signature(@TypeOf(Loop.writeAt), fn (*Loop, t.Handle, []const u8, u64, t.SubmitOptions) mox_io.Error!t.OpId);
        signature(@TypeOf(Loop.writeAllAt), fn (*Loop, t.Handle, []const u8, u64, t.SubmitOptions) mox_io.Error!t.OpId);
        signature(@TypeOf(Loop.sync), fn (*Loop, t.Handle, t.SubmitOptions) mox_io.Error!t.OpId);
        signature(@TypeOf(Loop.stat), fn (*Loop, t.Handle, t.SubmitOptions) mox_io.Error!t.OpId);
        signature(@TypeOf(Loop.stop), fn (*Loop) mox_io.Error!void);
        signature(@TypeOf(Loop.shutdown), fn (*Loop) mox_io.Error!void);
        const Stream = mox_io.Stream(Loop);
        signature(@TypeOf(Stream.tcp), fn (*Loop, t.Handle) Stream);
        signature(@TypeOf(Stream.file), fn (*Loop, t.Handle, u64) Stream);
        signature(@TypeOf(Stream.read), fn (*Stream, []u8, t.SubmitOptions) mox_io.Error!t.OpId);
        signature(@TypeOf(Stream.readExact), fn (*Stream, []u8, t.SubmitOptions) mox_io.Error!t.OpId);
        signature(@TypeOf(Stream.write), fn (*Stream, []const u8, t.SubmitOptions) mox_io.Error!t.OpId);
        signature(@TypeOf(Stream.writeAll), fn (*Stream, []const u8, t.SubmitOptions) mox_io.Error!t.OpId);
        signature(@TypeOf(Stream.complete), fn (*Stream, t.Completion) bool);
        signature(@TypeOf(Stream.seek), fn (*Stream, u64) mox_io.Error!void);
        signature(@TypeOf(mox_io.net.Resolve.complete), fn (*mox_io.net.Resolve, t.Completion) bool);
        signature(@TypeOf(mox_io.fs.Native.Request.complete), fn (*mox_io.fs.Native.Request, t.Completion) bool);
        signature(@TypeOf(mox_io.Pipe.Transfer.complete), fn (*mox_io.Pipe.Transfer, t.Completion) bool);
        signature(@TypeOf(mox_io.process.Child.complete), fn (*mox_io.process.Child, t.Completion) bool);
        signature(@TypeOf(mox_io.process.Child.kill), fn (*mox_io.process.Child) mox_io.Error!void);
        signature(@TypeOf(mox_io.process.Child.deinit), fn (*mox_io.process.Child) mox_io.Error!void);
        signature(@TypeOf(mox_io.process.Spawn.complete), fn (*mox_io.process.Spawn, t.Completion) bool);
        const Group = mox_io.Group(Loop);
        signature(@TypeOf(Group.add), fn (*Group, t.OpId) mox_io.Error!void);
        signature(@TypeOf(Group.complete), fn (*Group, t.Completion) bool);
        signature(@TypeOf(Group.cancelRemaining), fn (*Group) mox_io.Error!void);
        signature(@TypeOf(Group.reset), fn (*Group, mox_io.GroupMode) mox_io.Error!void);
        const Dial = mox_io.net.Dial(Loop);
        signature(@TypeOf(Dial.start), fn (*Dial, t.SubmitOptions) mox_io.Error!void);
        signature(@TypeOf(Dial.complete), fn (*Dial, t.Completion) mox_io.Error!bool);
        signature(@TypeOf(Dial.takeHandle), fn (*Dial) mox_io.Error!t.Handle);
    }
    const options: t.Options = .{};
    const submit: t.SubmitOptions = .{};
    try std.testing.expect(options.operations == 1024 and options.resources == 256);
    try std.testing.expect(options.events == 64 and options.inbox == 256);
    try std.testing.expect(options.file_threads == 2 and options.file_executor == null);
    try std.testing.expect(options.path_capacity == 4096);
    try std.testing.expect(!options.uring_fixed_files);
    try std.testing.expect(submit.deadline == null and submit.tag == 0);
    try std.testing.expect(@sizeOf(t.Handle) == @sizeOf(t.OpId));
}
