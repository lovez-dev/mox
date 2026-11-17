//! Shared diagnostics, completion collection and orderly example cleanup.

const mox_io = @import("mox_io");

pub fn number(prefix: []const u8, value: u64) void {
    var buffer: [20]u8 = undefined;
    mox_io.os.writeStdout(prefix);
    mox_io.os.writeStdout(mox_io.fmt.decimal(value, &buffer));
    mox_io.os.writeStdout("\n");
}

pub fn report(err: anyerror) void {
    mox_io.os.writeStderr("Example failed: ");
    mox_io.os.writeStderr(@errorName(err));
    mox_io.os.writeStderr("\n");
}

pub fn success(result: mox_io.types.Completion) !void {
    if (result.status != .ok) {
        mox_io.os.writeStderr("I/O result: ");
        mox_io.os.writeStderr(@tagName(result.status));
        if (result.library_error) |err| {
            mox_io.os.writeStderr(" (");
            mox_io.os.writeStderr(@errorName(err));
            mox_io.os.writeStderr(")");
        }
        mox_io.os.writeStderr("\n");
        return error.OperationFailed;
    }
}

pub fn gather(loop: anytype, output: []mox_io.types.Completion) !void {
    const deadline = loop.now() + 5_000_000_000;
    var count: usize = 0;
    while (count < output.len) {
        if (loop.now() >= deadline) return error.CompletionTimeout;
        count += try loop.poll(output[count..], .{ .until = deadline });
    }
}

pub fn one(loop: anytype) !mox_io.types.Completion {
    var output: [1]mox_io.types.Completion = undefined;
    try gather(loop, &output);
    return output[0];
}

/// Cleanup runs before caller buffers and producer contexts leave their scope.
pub fn drain(loop: anytype) !void {
    loop.shutdown() catch |err| {
        if (err != error.NativeFailure) return err;
    };
    const deadline = loop.now() + 5_000_000_000;
    var results: [64]mox_io.types.Completion = undefined;
    while (true) {
        const stats = loop.stats();
        if (stats.active_operations == 0 and stats.active_resources == 0 and stats.inbox.queued == 0 and stats.inbox.active_producers == 0) break;
        if (loop.now() >= deadline) return error.ShutdownTimeout;
        _ = try loop.poll(&results, .{ .until = deadline });
    }
    try loop.deinit();
}
