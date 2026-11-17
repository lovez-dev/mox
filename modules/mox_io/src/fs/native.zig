//! Native filesystem commands on bounded workers; paths are borrowed UTF-8 strings.

const posix_abi = @import("../os/abi/posix.zig");
const win_abi = @import("../os/abi/windows.zig");
const builtin = @import("builtin");
const t = @import("../types.zig");
const Error = @import("../error.zig").Error;
const w = @import("../os/windows.zig");

const windows = builtin.os.tag == .windows;

const Posix = struct {
    const mkdir = posix_abi.mkdir;
    const unlink = posix_abi.unlink;
    const rmdir = posix_abi.rmdir;
    const rename = posix_abi.rename;
    const ftruncate = posix_abi.ftruncate;
    const fchmod = posix_abi.fchmod;
    const opendir = posix_abi.opendir;
    const readdir = posix_abi.readdir;
    const @"readdir$INODE64" = posix_abi.@"readdir$INODE64";
    const closedir = posix_abi.closedir;
    const __errno_location = posix_abi.__errno_location;
    const __error = posix_abi.__error;

    fn errno() *c_int {
        return if (builtin.os.tag == .linux) __errno_location() else __error();
    }
};

const FindData = win_abi.FindData;
const Win = win_abi;

/// Owned directory state. Keep it stable and feed each command's completion.
pub const Directory = struct {
    native: ?*anyopaque = null,
    pending: ?t.OpId = null,
    first: bool = false,
    ended: bool = false,
    current: ?[*]const u8 = null,
    data: if (windows) FindData else void = undefined,
};

pub const Action = union(enum) {
    make_dir: struct { path: [:0]const u8, permissions: u16 = 0o755 },
    delete_file: [:0]const u8,
    remove_dir: [:0]const u8,
    rename: struct { from: [:0]const u8, to: [:0]const u8 },
    set_size: u64,
    set_permissions: u16,
    open_dir: struct { path: [:0]const u8, directory: *Directory },
    read_dir: struct { directory: *Directory, name: []u8 },
    close_dir: *Directory,
};

pub const Request = struct {
    action: Action,

    /// File commands retain this Loop handle through native retirement.
    handle: ?t.Handle = null,
    entry: ?@import("types.zig").DirectoryEntry = null,
    native_error: i32 = 0,
    id: ?t.OpId = null,

    fn directory(self: *Request) ?*Directory {
        return switch (self.action) {
            .open_dir => |a| a.directory,
            .read_dir => |a| a.directory,
            .close_dir => |a| a,
            else => null,
        };
    }

    /// Borrow paths, output buffers and directory state until complete() accepts the result.
    pub fn submit(self: *Request, loop: anytype, options: t.SubmitOptions) Error!t.OpId {
        if (self.id != null) return error.Busy;
        if (self.directory()) |dir| {
            if (dir.pending != null) return error.Busy;
            switch (self.action) {
                .open_dir => if (dir.native != null) return error.InvalidState,
                .read_dir, .close_dir => if (dir.native == null) return error.InvalidState,
                else => unreachable,
            }
        }

        const file_command = switch (self.action) {
            .set_size, .set_permissions => true,
            else => false,
        };
        if (file_command != (self.handle != null)) return error.InvalidOptions;
        switch (self.action) {
            .set_size => |size| if (size > 0x7fffffffffffffff) return error.InvalidOptions,
            else => {},
        }
        self.entry = null;
        self.native_error = 0;
        const task: t.Work = .{ .context = self, .run = run, .native_error = &self.native_error };
        const id = if (self.handle) |handle| try loop.workOn(handle, task, options) else try loop.work(task, options);
        self.id = id;
        if (self.directory()) |dir| dir.pending = id;
        return id;
    }

    pub fn complete(self: *Request, result: t.Completion) bool {
        const expected = self.id orelse return false;
        const actual = result.id orelse return false;
        if (expected.index != actual.index or expected.generation != actual.generation) return false;
        self.id = null;
        if (self.directory()) |dir| dir.pending = null;
        return true;
    }

    fn run(context: ?*anyopaque, native: usize) Error!usize {
        const self: *Request = @ptrCast(@alignCast(context.?));
        if (windows) return self.runWindows(native) else return self.runPosix(native);
    }

    fn checkPath(path: [:0]const u8) Error!void {
        if (path.len == 0) return error.InvalidOptions;
        for (path) |byte| if (byte == 0) return error.InvalidOptions;
    }

    fn runPosix(self: *Request, native: usize) Error!usize {
        const code = switch (self.action) {
            .make_dir => |a| blk: {
                try checkPath(a.path);
                break :blk Posix.mkdir(a.path.ptr, a.permissions);
            },
            .delete_file => |path| blk: {
                try checkPath(path);
                break :blk Posix.unlink(path.ptr);
            },
            .remove_dir => |path| blk: {
                try checkPath(path);
                break :blk Posix.rmdir(path.ptr);
            },
            .rename => |a| blk: {
                try checkPath(a.from);
                try checkPath(a.to);
                break :blk Posix.rename(a.from.ptr, a.to.ptr);
            },
            .set_size => |size| Posix.ftruncate(@intCast(native), @intCast(size)),
            .set_permissions => |mode| Posix.fchmod(@intCast(native), mode),
            .open_dir => |a| {
                try checkPath(a.path);
                a.directory.native = Posix.opendir(a.path.ptr) orelse {
                    self.native_error = Posix.errno().*;
                    return error.NativeFailure;
                };
                a.directory.ended = false;
                a.directory.current = null;
                return 0;
            },
            .read_dir => |a| {
                if (a.directory.ended) return 0;
                while (true) {
                    Posix.errno().* = 0;
                    const next = if (a.directory.current) |current| current else if (builtin.os.tag == .macos and builtin.cpu.arch == .x86_64)
                        Posix.@"readdir$INODE64"(a.directory.native.?)
                    else
                        Posix.readdir(a.directory.native.?);
                    const raw = next orelse {
                        self.native_error = Posix.errno().*;
                        if (self.native_error != 0) return error.NativeFailure;
                        a.directory.ended = true;
                        return 0;
                    };
                    a.directory.current = raw;
                    const offset: usize = if (builtin.os.tag == .linux) 19 else if (builtin.os.tag == .macos) 21 else 24;
                    const kind_offset: usize = if (builtin.os.tag == .linux) 18 else if (builtin.os.tag == .macos) 20 else 18;
                    var length: usize = 0;
                    const maximum: usize = if (builtin.os.tag == .macos) 1024 else 256;
                    while (length < maximum and raw[offset + length] != 0) : (length += 1) {}
                    if (length == maximum) return error.Capacity;
                    if (dot(raw[offset..][0..length])) {
                        a.directory.current = null;
                        continue;
                    }
                    if (length > a.name.len) return error.Capacity;
                    @memcpy(a.name[0..length], raw[offset..][0..length]);
                    self.entry = .{ .name = a.name[0..length], .kind = switch (raw[kind_offset]) {
                        4 => .directory,
                        8 => .file,
                        else => .other,
                    } };
                    a.directory.current = null;
                    return 1;
                }
            },
            .close_dir => |dir| blk: {
                const result = Posix.closedir(dir.native.?);
                // closedir consumes the directory stream; never reuse its pointer.
                dir.native = null;
                break :blk result;
            },
        };
        if (code != 0) {
            self.native_error = Posix.errno().*;
            return error.NativeFailure;
        }
        return 0;
    }

    fn wide(path: [:0]const u8, buffer: []u16) Error![:0]u16 {
        try checkPath(path);
        return @import("path.zig").utf16(path, buffer);
    }

    fn runWindows(self: *Request, native: usize) Error!usize {
        var first: [32768]u16 = undefined;
        var second: [32768]u16 = undefined;
        const code = switch (self.action) {
            .make_dir => |a| Win.CreateDirectoryW((try wide(a.path, &first)).ptr, null),
            .delete_file => |path| Win.DeleteFileW((try wide(path, &first)).ptr),
            .remove_dir => |path| Win.RemoveDirectoryW((try wide(path, &first)).ptr),
            .rename => |a| Win.MoveFileExW((try wide(a.from, &first)).ptr, (try wide(a.to, &second)).ptr, 1),
            .set_size => |size| blk: {
                const value: i64 = @intCast(size);
                break :blk Win.SetFileInformationByHandle(@ptrFromInt(native), 6, &value, 8);
            },
            .set_permissions => return error.BackendUnavailable,
            .open_dir => |a| {
                const path = try wide(a.path, &first);
                if (path.len + 3 >= first.len) return error.Capacity;
                first[path.len] = '\\';
                first[path.len + 1] = '*';
                first[path.len + 2] = 0;
                const handle = Win.FindFirstFileW(first[0 .. path.len + 2 :0].ptr, &a.directory.data);
                if (handle == w.invalid_handle) {
                    self.native_error = @bitCast(w.GetLastError());
                    return error.NativeFailure;
                }
                a.directory.native = handle;
                a.directory.first = true;
                a.directory.ended = false;
                return 0;
            },
            .read_dir => |a| {
                if (a.directory.ended) return 0;
                while (true) {
                    if (!a.directory.first and Win.FindNextFileW(a.directory.native.?, &a.directory.data) == 0) {
                        if (w.GetLastError() != 18) {
                            self.native_error = @bitCast(w.GetLastError());
                            return error.NativeFailure;
                        }
                        a.directory.ended = true;
                        return 0;
                    }
                    a.directory.first = false;
                    const data = &a.directory.data;
                    var length: usize = 0;
                    while (length < data.name.len and data.name[length] != 0) : (length += 1) {}
                    if ((length == 1 and data.name[0] == '.') or (length == 2 and data.name[0] == '.' and data.name[1] == '.')) continue;
                    if (a.name.len > 0x7fffffff) return error.InvalidOptions;
                    const count = Win.WideCharToMultiByte(65001, 0x80, &data.name, @intCast(length), a.name.ptr, @intCast(a.name.len), null, null);
                    if (count <= 0 or a.name.len == 0) {
                        a.directory.first = true;
                        return error.Capacity;
                    }
                    self.entry = .{ .name = a.name[0..@intCast(count)], .kind = if (data.attributes & 0x400 != 0) .other else if (data.attributes & 0x10 != 0) .directory else .file };
                    return 1;
                }
            },
            .close_dir => |dir| blk: {
                const result = Win.FindClose(dir.native.?);
                if (result != 0) dir.native = null;
                break :blk result;
            },
        };
        if (code == 0) {
            self.native_error = @bitCast(w.GetLastError());
            return error.NativeFailure;
        }
        return 0;
    }
};

fn dot(name: []const u8) bool {
    return (name.len == 1 and name[0] == '.') or (name.len == 2 and name[0] == '.' and name[1] == '.');
}
