//! Owned child processes with selective pipe redirection and worker-backed waits.

const posix_abi = @import("os/abi/posix.zig");
const win_abi = @import("os/abi/windows.zig");
const builtin = @import("builtin");
const t = @import("types.zig");
const Error = @import("error.zig").Error;
const Mutex = @import("sync/mutex.zig");
const Pipe = @import("io/pipe.zig");
const w = @import("os/windows.zig");

const windows = builtin.os.tag == .windows;
const Posix = posix_abi;
const Startup = win_abi.Startup;
const StartupEx = win_abi.StartupEx;
const ProcessInfo = win_abi.ProcessInfo;
const Win = win_abi;

pub const Options = struct {
    argv: []const [:0]const u8,
    cwd: ?[:0]const u8 = null,
    stdin: ?*Pipe.End = null,
    stdout: ?*Pipe.End = null,
    stderr: ?*Pipe.End = null,

    /// Explicit Windows command line for programs with non-CRT parsing, such as cmd.exe.
    windows_command_line: ?[:0]const u8 = null,
};

pub const Termination = union(enum) { exited: u32, signal: u32 };

/// Keep the child at a stable address; the owner and wait worker share its mutex.
pub const Child = struct {
    native: usize = t.invalid_native,
    mutex: Mutex = .{},
    pending: ?t.OpId = null,
    spawning: bool = false,
    reaped: bool = false,
    termination: ?Termination = null,
    native_error: i32 = 0,

    /// Spawn is a setup call. Use Spawn.submit() to perform it on a worker.
    pub fn spawn(self: *Child, options: Options) Error!void {
        if (self.spawning) return error.Busy;
        for ([_]?*Pipe.End{ options.stdin, options.stdout, options.stderr }) |end|
            if (end) |value| {
                if (value.borrowers != 0) return error.Busy;
            };
        return self.spawnOwned(options);
    }

    fn spawnOwned(self: *Child, options: Options) Error!void {
        if (self.native != t.invalid_native or self.pending != null) return error.InvalidState;
        if (options.argv.len == 0 or options.argv.len >= 128 or options.argv[0].len == 0) return error.InvalidOptions;
        for (options.argv) |arg| for (arg) |byte| {
            if (byte == 0) return error.InvalidOptions;
        };
        if (options.cwd) |cwd| for (cwd) |byte| {
            if (byte == 0) return error.InvalidOptions;
        };

        const ends = [_]?*Pipe.End{ options.stdin, options.stdout, options.stderr };
        for (ends, 0..) |end, index| if (end) |value| {
            if (value.pending != null) return error.Busy;
            if (value.native == t.invalid_native or value.direction != (if (index == 0) Pipe.Direction.read else .write)) return error.InvalidResource;
        };
        try self.mutex.init();
        errdefer self.mutex.deinit();
        self.reaped = false;
        self.termination = null;
        self.native_error = 0;
        if (windows) self.spawnWindows(options) catch |err| {
            if (err == error.NativeFailure and self.native_error == 0) self.native_error = @bitCast(w.GetLastError());
            return err;
        } else {
            if (options.windows_command_line != null) return error.InvalidOptions;
            try self.spawnPosix(options);
        }
    }

    fn spawnPosix(self: *Child, options: Options) Error!void {
        const gate = @import("core/spawn_gate.zig");

        gate.lock();
        defer gate.unlock();
        // Opaque platform objects are initialized/destroyed by libc, never copied.
        var actions: [256]u8 align(16) = undefined;
        var code = Posix.posix_spawn_file_actions_init(&actions);
        if (code != 0) {
            self.native_error = code;
            return error.NativeFailure;
        }
        defer _ = Posix.posix_spawn_file_actions_destroy(&actions);
        const ends = [_]?*Pipe.End{ options.stdin, options.stdout, options.stderr };
        for (ends, 0..) |end, index| if (end) |value| {
            // Duplicating stdio descriptors would make redirection order ambiguous.
            if (value.native < 3) return error.InvalidResource;
            code = Posix.posix_spawn_file_actions_adddup2(&actions, @intCast(value.native), @intCast(index));
            if (code != 0) {
                self.native_error = code;
                return error.NativeFailure;
            }
        };
        if (options.cwd) |cwd| {
            code = Posix.posix_spawn_file_actions_addchdir_np(&actions, cwd.ptr);
            if (code != 0) {
                self.native_error = code;
                return error.NativeFailure;
            }
        }
        var arguments: [128:null]?[*:0]const u8 = @splat(null);
        for (options.argv, 0..) |arg, index| arguments[index] = arg.ptr;
        var pid: c_int = 0;
        const environment = if (builtin.os.tag == .macos) Posix._NSGetEnviron().* else Posix.environ;
        code = Posix.posix_spawnp(&pid, options.argv[0].ptr, &actions, null, arguments[0..options.argv.len :null].ptr, environment);
        if (code != 0) {
            self.native_error = code;
            return error.NativeFailure;
        }
        self.native = @intCast(pid);
    }

    fn spawnWindows(self: *Child, options: Options) Error!void {
        var command: [32768]u8 = undefined;
        var used: usize = 0;
        for (options.argv, 0..) |arg, index| {
            if (index != 0) try append(&command, &used, ' ');
            try append(&command, &used, '"');
            var slashes: usize = 0;
            for (arg) |byte| {
                if (byte == '\\') {
                    slashes += 1;
                    continue;
                }
                for (0..(if (byte == '"') slashes * 2 + 1 else slashes)) |_| try append(&command, &used, '\\');
                slashes = 0;
                try append(&command, &used, byte);
            }
            for (0..slashes * 2) |_| try append(&command, &used, '\\');
            try append(&command, &used, '"');
        }
        var wide_command: [32768]u16 = undefined;
        const wide = try @import("fs/path.zig").utf16(options.windows_command_line orelse command[0..used], &wide_command);
        var wide_cwd: [32768]u16 = undefined;
        const cwd: ?[*:0]const u16 = if (options.cwd) |value| (try @import("fs/path.zig").utf16(value, &wide_cwd)).ptr else null;
        var duplicates: [3]w.Handle = undefined;
        var count: usize = 0;
        defer for (duplicates[0..count]) |handle| {
            _ = w.CloseHandle(handle);
        };
        var standard: [3]?w.Handle = @splat(null);
        const ends = [_]?*Pipe.End{ options.stdin, options.stdout, options.stderr };
        for (ends, 0..) |end, index| {
            const original: ?w.Handle = if (end) |value| @ptrFromInt(value.native) else w.GetStdHandle(@as(u32, 0xfffffff6) - @as(u32, @intCast(index)));
            if (original == null or original == w.invalid_handle) continue;
            if (Win.DuplicateHandle(Win.GetCurrentProcess(), original.?, Win.GetCurrentProcess(), &duplicates[count], 0, 1, 2) == 0) return error.NativeFailure;
            standard[index] = duplicates[count];
            count += 1;
        }
        var attributes: [512]u8 align(16) = undefined;
        var startup: StartupEx = .{ .startup = .{ .size = @sizeOf(StartupEx), .flags = 0x100, .input = standard[0], .output = standard[1], .err = standard[2] } };
        var attribute_size: usize = 0;
        if (count != 0) {
            _ = Win.InitializeProcThreadAttributeList(null, 1, 0, &attribute_size);
            if (attribute_size > attributes.len) return error.Capacity;
            if (Win.InitializeProcThreadAttributeList(&attributes, 1, 0, &attribute_size) == 0) return error.NativeFailure;
            startup.attributes = &attributes;
        }
        defer if (startup.attributes) |list| Win.DeleteProcThreadAttributeList(list);
        if (startup.attributes) |list| {
            if (Win.UpdateProcThreadAttribute(list, 0, 0x20002, &duplicates, count * @sizeOf(w.Handle), null, null) == 0) return error.NativeFailure;
        }
        var info: ProcessInfo = undefined;
        if (Win.CreateProcessW(null, wide.ptr, null, null, @intFromBool(count != 0), 0x80000, null, cwd, &startup.startup, &info) == 0) {
            self.native_error = @bitCast(w.GetLastError());
            return error.NativeFailure;
        }
        _ = w.CloseHandle(info.thread);
        self.native = @intFromPtr(info.process);
    }

    pub fn wait(self: *Child, loop: anytype, options: t.SubmitOptions) Error!t.OpId {
        if (self.spawning) return error.Busy;
        if (self.native == t.invalid_native) return error.InvalidState;
        if (self.pending != null) return error.Busy;
        const id = try loop.work(.{ .context = self, .run = waitWork, .native_error = &self.native_error }, options);
        self.pending = id;
        return id;
    }

    pub fn complete(self: *Child, result: t.Completion) bool {
        const expected = self.pending orelse return false;
        const actual = result.id orelse return false;
        if (expected.index != actual.index or expected.generation != actual.generation) return false;
        self.pending = null;
        return true;
    }

    fn waitWork(context: ?*anyopaque, _: usize) Error!usize {
        const self: *Child = @ptrCast(@alignCast(context.?));
        while (true) {
            self.mutex.lock();
            if (self.reaped) {
                self.mutex.unlock();
                return 0;
            }
            if (windows) {
                const state = Win.WaitForSingleObject(@ptrFromInt(self.native), 0);
                if (state == 0) {
                    var code: u32 = 0;
                    if (Win.GetExitCodeProcess(@ptrFromInt(self.native), &code) == 0) {
                        self.native_error = @bitCast(w.GetLastError());
                        self.mutex.unlock();
                        return error.NativeFailure;
                    }
                    self.termination = .{ .exited = code };
                    self.reaped = true;
                } else if (state != 258) {
                    self.native_error = @bitCast(w.GetLastError());
                    self.mutex.unlock();
                    return error.NativeFailure;
                }
            } else {
                var status: c_int = 0;
                const pid = Posix.waitpid(@intCast(self.native), &status, 1);
                if (pid > 0) {
                    self.termination = if (status & 0x7f == 0) .{ .exited = @intCast((status >> 8) & 0xff) } else .{ .signal = @intCast(status & 0x7f) };
                    self.reaped = true;
                } else if (pid < 0 and Pipe.Posix.errno() != 4) {
                    self.native_error = Pipe.Posix.errno();
                    self.mutex.unlock();
                    return error.NativeFailure;
                }
            }

            const done = self.reaped;
            self.mutex.unlock();
            if (done) return 0;
            if (windows) w.Sleep(1) else {
                const delay: @import("os/posix.zig").Timespec = .{ .sec = 0, .nsec = 1_000_000 };
                _ = Posix.nanosleep(&delay, null);
            }
        }
    }

    /// Terminate explicitly; canceling a wait alone does not kill the child.
    pub fn kill(self: *Child) Error!void {
        if (self.spawning) return error.Busy;
        if (self.native == t.invalid_native) return error.InvalidState;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.reaped) return;
        if (windows) {
            if (Win.TerminateProcess(@ptrFromInt(self.native), 137) == 0) return error.NativeFailure;
        } else if (Posix.kill(@intCast(self.native), 9) != 0) return error.NativeFailure;
    }

    /// A child must be waited and its completion consumed before releasing it.
    pub fn deinit(self: *Child) Error!void {
        if (self.spawning) return error.Busy;
        if (self.pending != null) return error.Busy;
        if (self.native == t.invalid_native) return error.InvalidState;
        if (!self.reaped) return error.Busy;
        if (windows and w.CloseHandle(@ptrFromInt(self.native)) == 0) return error.NativeFailure;
        self.native = t.invalid_native;
        self.mutex.deinit();
    }
};

/// Cancellation cannot undo a successful native spawn; inspect and reap the child.
pub const Spawn = struct {
    child: *Child,
    options: Options,
    id: ?t.OpId = null,

    pub fn submit(self: *Spawn, loop: anytype, options: t.SubmitOptions) Error!t.OpId {
        if (self.id != null or self.child.spawning or self.child.native != t.invalid_native or self.child.pending != null) return error.Busy;
        const ends = [_]?*Pipe.End{ self.options.stdin, self.options.stdout, self.options.stderr };
        for (ends) |end| if (end) |value| {
            var uses: usize = 0;
            for (ends) |other| {
                if (other == end) uses += 1;
            }
            if (value.pending != null or value.native == t.invalid_native or value.borrowers > ~@as(usize, 0) - uses) return error.Busy;
        };

        const id = try loop.work(.{ .context = self, .run = run, .native_error = &self.child.native_error }, options);
        // Pins prevent owner-side endpoint closure while the spawn worker uses them.
        self.child.spawning = true;
        for ([_]?*Pipe.End{ self.options.stdin, self.options.stdout, self.options.stderr }) |end|
            if (end) |value| {
                value.borrowers += 1;
            };
        self.id = id;
        return id;
    }

    pub fn complete(self: *Spawn, result: t.Completion) bool {
        const expected = self.id orelse return false;
        const actual = result.id orelse return false;
        if (expected.index != actual.index or expected.generation != actual.generation) return false;
        self.id = null;
        self.child.spawning = false;
        for ([_]?*Pipe.End{ self.options.stdin, self.options.stdout, self.options.stderr }) |end|
            if (end) |value| {
                value.borrowers -= 1;
            };
        return true;
    }

    fn run(context: ?*anyopaque, _: usize) Error!usize {
        const self: *Spawn = @ptrCast(@alignCast(context.?));
        try self.child.spawnOwned(self.options);
        return 0;
    }
};

fn append(output: []u8, used: *usize, byte: u8) Error!void {
    if (used.* == output.len) return error.Capacity;
    output[used.*] = byte;
    used.* += 1;
}
