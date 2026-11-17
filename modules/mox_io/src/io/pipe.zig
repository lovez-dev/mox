//! Anonymous byte pipes. Transfers run on workers and retain caller-owned endpoints.

const posix_abi = @import("../os/abi/posix.zig");
const win_abi = @import("../os/abi/windows.zig");
const builtin = @import("builtin");
const t = @import("../types.zig");
const Error = @import("../error.zig").Error;
const w = @import("../os/windows.zig");

const windows = builtin.os.tag == .windows;
const Pipe = @This();

pub const Posix = struct {
    pub const close = posix_abi.close;
    pub const read = posix_abi.read;
    pub const write = posix_abi.write;
    const pipe = posix_abi.pipe;
    const pipe2 = posix_abi.pipe2;
    const fcntl = posix_abi.fcntl;
    const __errno_location = posix_abi.__errno_location;
    const __error = posix_abi.__error;
    const sigemptyset = posix_abi.sigemptyset;
    const sigaddset = posix_abi.sigaddset;
    const sigismember = posix_abi.sigismember;
    const sigpending = posix_abi.sigpending;
    const pthread_sigmask = posix_abi.pthread_sigmask;
    const sigwait = posix_abi.sigwait;

    pub fn errno() i32 {
        return (if (builtin.os.tag == .linux) __errno_location() else __error()).*;
    }
};

const Win = struct {
    const CreatePipe = win_abi.CreatePipe;
    const ReadFile = win_abi.ReadFile;
};

pub const Direction = enum { read, write };

pub const End = struct {
    native: usize = t.invalid_native,
    direction: Direction,
    pending: ?t.OpId = null,
    borrowers: usize = 0,

    /// Close child-side ends in the parent after spawning to permit EOF delivery.
    pub fn close(self: *End) Error!void {
        if (self.pending != null or self.borrowers != 0) return error.Busy;
        if (self.native == t.invalid_native) return error.InvalidState;
        if (windows) {
            if (w.CloseHandle(@ptrFromInt(self.native)) == 0) return error.NativeFailure;
        } else {
            const code = Posix.close(@intCast(self.native));
            // Linux consumes the descriptor even if close reports an error.
            if (code != 0 and builtin.os.tag != .linux) return error.NativeFailure;
            self.native = t.invalid_native;
            if (code != 0) return error.NativeFailure;
        }
        self.native = t.invalid_native;
    }
};

reader: End = .{ .direction = .read },
writer: End = .{ .direction = .write },

pub fn init(self: *Pipe) Error!void {
    if (self.reader.native != t.invalid_native or self.writer.native != t.invalid_native) return error.InvalidState;
    if (windows) {
        var reader: w.Handle = undefined;
        var writer: w.Handle = undefined;
        if (Win.CreatePipe(&reader, &writer, null, 0) == 0) return error.NativeFailure;
        self.reader.native = @intFromPtr(reader);
        self.writer.native = @intFromPtr(writer);
    } else {
        const gate = @import("../core/spawn_gate.zig");

        gate.lock();
        defer gate.unlock();
        var fds: [2]c_int = undefined;
        if (builtin.os.tag == .linux or builtin.os.tag == .freebsd) {
            if (Posix.pipe2(&fds, if (builtin.os.tag == .linux) 0x80000 else 0x100000) != 0) return error.NativeFailure;
        } else {
            if (Posix.pipe(&fds) != 0) return error.NativeFailure;
            if (Posix.fcntl(fds[0], 2, @as(c_int, 1)) < 0 or Posix.fcntl(fds[1], 2, @as(c_int, 1)) < 0) {
                _ = Posix.close(fds[0]);
                _ = Posix.close(fds[1]);
                return error.NativeFailure;
            }
        }
        errdefer {
            _ = Posix.close(fds[0]);
            _ = Posix.close(fds[1]);
        }
        // Reserve stdio numbers for child redirection, even without parent stdio.
        for (&fds) |*fd| if (fd.* < 3) {
            const duplicate = Posix.fcntl(fd.*, 0, @as(c_int, 3));
            if (duplicate < 0) return error.NativeFailure;
            if (Posix.fcntl(duplicate, 2, @as(c_int, 1)) < 0) {
                _ = Posix.close(duplicate);
                return error.NativeFailure;
            }
            _ = Posix.close(fd.*);
            fd.* = duplicate;
        };
        self.reader.native = @intCast(fds[0]);
        self.writer.native = @intCast(fds[1]);
    }
}

pub fn deinit(self: *Pipe) Error!void {
    if (self.reader.pending != null or self.writer.pending != null or self.reader.borrowers != 0 or self.writer.borrowers != 0) return error.Busy;
    var failure: ?Error = null;
    if (self.reader.native != t.invalid_native) self.reader.close() catch |err| {
        failure = err;
    };
    if (self.writer.native != t.invalid_native) self.writer.close() catch |err| {
        if (failure == null) failure = err;
    };
    if (failure) |err| return err;
}

pub const Transfer = struct {
    end: *End,
    read_buffer: []u8 = &.{},
    write_buffer: []const u8 = &.{},
    eof: bool = false,
    native_error: i32 = 0,
    id: ?t.OpId = null,

    /// Keep this request, endpoint and buffer stable through complete(), including cancellation.
    pub fn submit(self: *Transfer, loop: anytype, options: t.SubmitOptions) Error!t.OpId {
        if (self.id != null or self.end.pending != null or self.end.borrowers != 0) return error.Busy;
        if (self.end.native == t.invalid_native) return error.InvalidState;
        if ((self.end.direction == .read and self.write_buffer.len != 0) or (self.end.direction == .write and self.read_buffer.len != 0)) return error.InvalidOptions;
        self.eof = false;
        self.native_error = 0;
        const id = try loop.work(.{ .context = self, .run = run, .native_error = &self.native_error }, options);
        self.id = id;
        self.end.pending = id;
        return id;
    }

    /// Release owner-side borrowing only after the worker's terminal result is delivered.
    pub fn complete(self: *Transfer, result: t.Completion) bool {
        const expected = self.id orelse return false;
        const actual = result.id orelse return false;
        if (expected.index != actual.index or expected.generation != actual.generation) return false;
        self.id = null;
        self.end.pending = null;
        return true;
    }

    fn run(context: ?*anyopaque, _: usize) Error!usize {
        const self: *Transfer = @ptrCast(@alignCast(context.?));
        const reading = self.end.direction == .read;
        const length = if (reading) self.read_buffer.len else self.write_buffer.len;
        if (length == 0) return 0;
        if (windows) {
            var count: u32 = 0;
            const size: u32 = @intCast(@min(length, 0x7fffffff));
            const success = if (reading) Win.ReadFile(@ptrFromInt(self.end.native), self.read_buffer.ptr, size, &count, null) else w.WriteFile(@ptrFromInt(self.end.native), self.write_buffer.ptr, size, &count, null);
            if (success == 0) {
                self.native_error = @bitCast(w.GetLastError());
                if (reading and self.native_error == 109) {
                    self.eof = true;
                    return 0;
                }
                return error.NativeFailure;
            }
            self.eof = reading and count == 0;
            return count;
        }
        // Suppress only this write's SIGPIPE; do not change process signal policy.
        var blocked: [128]u8 align(8) = @splat(0);
        var previous: [128]u8 align(8) = undefined;
        var pending: [128]u8 align(8) = undefined;
        var already_pending = false;
        if (!reading) {
            if (Posix.sigemptyset(&blocked) != 0 or Posix.sigaddset(&blocked, 13) != 0) return error.NativeFailure;
            if (Posix.pthread_sigmask(if (builtin.os.tag == .linux) 0 else 1, &blocked, &previous) != 0) return error.NativeFailure;
            if (Posix.sigpending(&pending) != 0) {
                _ = Posix.pthread_sigmask(if (builtin.os.tag == .linux) 2 else 3, &previous, null);
                return error.NativeFailure;
            }
            already_pending = Posix.sigismember(&pending, 13) == 1;
        }
        defer if (!reading) {
            if (!already_pending and Posix.sigpending(&pending) == 0 and Posix.sigismember(&pending, 13) == 1) {
                var signal: c_int = 0;
                _ = Posix.sigwait(&blocked, &signal);
            }
            _ = Posix.pthread_sigmask(if (builtin.os.tag == .linux) 2 else 3, &previous, null);
        };
        while (true) {
            const count = if (reading) Posix.read(@intCast(self.end.native), self.read_buffer.ptr, @min(length, 0x7ffff000)) else Posix.write(@intCast(self.end.native), self.write_buffer.ptr, @min(length, 0x7ffff000));
            if (count >= 0) {
                self.eof = reading and count == 0;
                return @intCast(count);
            }
            self.native_error = Posix.errno();
            if (self.native_error != 4) return error.NativeFailure;
        }
    }
};
