//! Documented Winsock overlapped I/O and batched IOCP completion harvesting.

const win_abi = @import("../os/abi/windows.zig");
const t = @import("../types.zig");
const c = @import("common.zig");
const w = @import("../os/windows.zig");
const Arena = @import("../mem/arena.zig");
const Layout = @import("../mem/layout.zig").Layout;
const Error = @import("../error.zig").Error;
const Queue = @import("../core/queue.zig").Queue;
const Blocking = @import("blocking.zig");
const file = @import("native/windows_file.zig");

const Driver = @This();

// Owner-managed completion storage.
port: w.Handle,
contexts: []Context,
resources: []Resource,
entries: []Entry,
path: []u16,
completed: Queue(c.Event),

// Blocking file control operations publish into the same completion stream.
workers: Blocking = undefined,
requests: []c.Request,
close_requests: []c.Request,

last_error: i32 = 0,
counters: c.NativeStats = .{},
wake_posted: u32 = 0,

pub const capabilities: c.Capabilities = .{ .native_files = true, .file_workers = true };

pub const Overlapped = win_abi.Overlapped;

const Entry = win_abi.Entry;
const WsaBuffer = win_abi.WsaBuffer;
const Guid = win_abi.Guid;

// Winsock extension entry points are cached per adopted socket.
const AcceptEx = *const fn (usize, usize, *anyopaque, u32, u32, u32, *u32, *Overlapped) callconv(.winapi) w.Bool;
const ConnectEx = *const fn (usize, *const anyopaque, i32, ?*const anyopaque, u32, ?*u32, *Overlapped) callconv(.winapi) w.Bool;

const accept_guid: Guid = .{ .a = 0xb5367df1, .b = 0xcbac, .c = 0x11cf, .d = .{ 0x95, 0xca, 0, 0x80, 0x5f, 0x48, 0xa1, 0x92 } };

const connect_guid: Guid = .{ .a = 0x25a207b9, .b = 0xddf3, .c = 0x4660, .d = .{ 0x8e, 0xe9, 0x76, 0xe5, 0x8c, 0x74, 0x06, 0x3e } };

const Resource = struct { accept_ex: ?AcceptEx = null, connect_ex: ?ConnectEx = null };

const Context = struct {
    // OVERLAPPED storage stays pinned until its completion packet is harvested.
    overlapped: Overlapped = .{},
    request: ?*c.Request = null,
    active: bool = false,
    buffer: WsaBuffer = undefined,
    flags: u32 = 0,
    address: [128]u8 align(8) = @splat(0),
    address_length: i32 = 128,
    accept_buffer: [288]u8 = undefined,
    accepted: usize = t.invalid_native,
    transferred: u32 = 0,
};

// Shared native bindings used by the completion driver.
pub const CreateIoCompletionPort = win_abi.CreateIoCompletionPort;
pub const GetQueuedCompletionStatusEx = win_abi.GetQueuedCompletionStatusEx;
pub const PostQueuedCompletionStatus = win_abi.PostQueuedCompletionStatus;
pub const CancelIoEx = win_abi.CancelIoEx;
pub const ReadFile = win_abi.ReadFile;
pub const RtlNtStatusToDosError = win_abi.RtlNtStatusToDosError;
pub const WSAStartup = win_abi.WSAStartup;
pub const WSACleanup = win_abi.WSACleanup;
pub const WSAGetLastError = win_abi.WSAGetLastError;
pub const WSASocketW = win_abi.WSASocketW;
pub const closesocket = win_abi.closesocket;
pub const bind = win_abi.bind;
pub const listen = win_abi.listen;
pub const getsockname = win_abi.getsockname;
pub const getpeername = win_abi.getpeername;
pub const setsockopt = win_abi.setsockopt;
pub const WSAIoctl = win_abi.WSAIoctl;
pub const WSARecv = win_abi.WSARecv;
pub const WSASend = win_abi.WSASend;
pub const WSARecvFrom = win_abi.WSARecvFrom;
pub const WSASendTo = win_abi.WSASendTo;

pub fn layout(sizer: *Layout, options: t.Options) Error!void {
    try sizer.add(Context, options.operations);
    try sizer.add(Resource, options.resources);
    try sizer.add(Entry, options.events);
    try sizer.add(u16, options.path_capacity);
    try sizer.add(c.Event, options.operations);
    try sizer.add(c.Request, options.resources);
    try Blocking.layout(sizer, options);
}

pub fn init(self: *Driver, arena: *Arena, options: t.Options, requests: []c.Request) Error!void {
    var data: [512]u8 align(8) = undefined;
    if (WSAStartup(0x202, &data) != 0) return error.BackendUnavailable;
    errdefer _ = WSACleanup();
    const port = CreateIoCompletionPort(w.invalid_handle, null, 0, 1) orelse return error.NativeFailure;
    errdefer _ = w.CloseHandle(port);
    self.* = .{
        .port = port,
        .contexts = try arena.allocate(Context, options.operations),
        .resources = try arena.allocate(Resource, options.resources),
        .entries = try arena.allocate(Entry, options.events),
        .path = try arena.allocate(u16, options.path_capacity),
        .completed = .{ .storage = try arena.allocate(c.Event, options.operations) },
        .requests = requests,
        .close_requests = try arena.allocate(c.Request, options.resources),
    };
    for (self.contexts) |*context| context.* = .{};
    for (self.resources) |*resource| resource.* = .{};
    try self.workers.init(arena, options, file.work, self, wakeThunk);
    self.counters.workers = self.workers.workerCount();
    self.counters.shared_executor = self.workers.isShared();
}

pub fn deinit(self: *Driver) void {
    self.workers.deinit();
    _ = w.CloseHandle(self.port);
    _ = WSACleanup();
}

pub fn attach(self: *Driver, handle: t.Handle, native: usize, _: t.ResourceKind) Error!void {
    if (CreateIoCompletionPort(@ptrFromInt(native), self.port, handle.index, 0) == null) {
        self.last_error = @bitCast(w.GetLastError());
        return error.NativeFailure;
    }
    self.resources[handle.index] = .{};
}

pub fn detach(self: *Driver, handle: t.Handle, native: usize, kind: t.ResourceKind) c.CloseResult {
    if (kind == .file and self.workers.workerCount() != 0) {
        const request = &self.close_requests[handle.index];
        request.* = .{ .id = .{ .index = @intCast(self.requests.len + handle.index), .generation = handle.generation }, .handle = handle, .native = native, .kind = .close, .options = .{} };
        self.workers.submit(request) catch @panic("reserved file close was rejected");
        self.counters.worker_jobs +|= 1;
        return .{ .pending = true };
    }
    return closeNative(native, kind);
}

pub fn closeNative(native: usize, kind: t.ResourceKind) c.CloseResult {
    const success = if (kind == .file) w.CloseHandle(@ptrFromInt(native)) != 0 else closesocket(native) == 0;
    return .{ .closed = success, .native_error = if (success) 0 else if (kind == .file) @bitCast(w.GetLastError()) else WSAGetLastError() };
}

pub fn socket(kind: t.ResourceKind, family: t.Address.Family, address: ?t.Address, backlog: u32) Error!usize {
    const fd = WSASocketW(if (family == .ipv4) 2 else 23, if (kind == .udp) 2 else 1, if (kind == .udp) 17 else 6, null, 0, 0x81);
    if (fd == t.invalid_native) return error.NativeFailure;
    errdefer _ = closesocket(fd);
    if (address) |value| {
        var storage: [128]u8 align(8) = undefined;
        const length = encode(value, &storage);
        if (bind(fd, &storage, length) != 0) return error.NativeFailure;
    }
    if (kind == .listener and listen(fd, @intCast(@min(backlog, 0x7fffffff))) != 0) return error.NativeFailure;
    return fd;
}

pub fn openFile(self: *Driver, path: []const u8, create: bool, writable: bool) Error!usize {
    const scratch: [*]u8 = @ptrCast(self.path.ptr);
    return file.openFile(path, t.FileOpenOptions.legacy(create, writable), scratch[0 .. self.path.len * 2]);
}

pub fn localAddress(native: usize) Error!t.Address {
    var storage: [128]u8 align(8) = undefined;
    var length: i32 = 128;
    if (getsockname(native, &storage, &length) != 0) return error.NativeFailure;
    return decode(&storage);
}

pub fn noDelay(native: usize, enabled: bool) Error!void {
    const value: i32 = @intFromBool(enabled);
    if (setsockopt(native, 6, 1, &value, 4) != 0) return error.NativeFailure;
}

fn extension(self: *Driver, comptime T: type, fd: usize, guid: *const Guid) Error!T {
    var pointer: T = undefined;
    var count: u32 = 0;
    if (WSAIoctl(fd, 0xc8000006, guid, @sizeOf(Guid), @ptrCast(&pointer), @sizeOf(T), &count, null, null) != 0) {
        self.last_error = WSAGetLastError();
        return error.NativeFailure;
    }
    return pointer;
}

pub fn submit(self: *Driver, request: *c.Request) Error!void {
    self.last_error = 0;
    self.counters.submissions +|= 1;
    if (request.kind == .work or request.kind == .sync or request.kind == .open or request.kind == .stat) {
        try self.workers.submit(request);
        self.counters.worker_jobs +|= 1;
        return;
    }
    const context = &self.contexts[request.id.index];
    if (context.active) @panic("overlapped context reused while active");
    context.overlapped = .{};
    context.request = request;
    context.active = true;
    context.flags = 0;
    context.address_length = 128;
    context.accepted = t.invalid_native;
    context.transferred = 0;
    errdefer {
        context.active = false;
        if (context.accepted != t.invalid_native) {
            _ = closesocket(context.accepted);
            context.accepted = t.invalid_native;
        }
    }
    const reading = request.kind == .recv or request.kind == .read or request.kind == .recv_from;
    const buffer = if (reading) request.read_buffer else @constCast(request.write_buffer);
    context.buffer = .{ .length = @intCast(@min(buffer.len, 0xffffffff)), .pointer = buffer.ptr };
    var result: i32 = 0;
    switch (request.kind) {
        .recv => result = WSARecv(request.native, &context.buffer, 1, null, &context.flags, &context.overlapped, null),
        .send => result = WSASend(request.native, &context.buffer, 1, null, 0, &context.overlapped, null),
        .recv_from => result = WSARecvFrom(request.native, &context.buffer, 1, &context.transferred, &context.flags, &context.address, &context.address_length, &context.overlapped, null),
        .send_to => {
            context.address_length = encode(request.address, &context.address);
            result = WSASendTo(request.native, &context.buffer, 1, null, 0, &context.address, context.address_length, &context.overlapped, null);
        },
        .accept => {
            const resource = &self.resources[request.handle.index];
            const accept_ex = resource.accept_ex orelse try self.extension(AcceptEx, request.native, &accept_guid);
            resource.accept_ex = accept_ex;
            const family = (try localAddress(request.native)).family;
            context.accepted = try socket(.tcp, family, null, 0);
            if (accept_ex(request.native, context.accepted, &context.accept_buffer, 0, 144, 144, &context.transferred, &context.overlapped) == 0) result = -1;
        },
        .connect => {
            const resource = &self.resources[request.handle.index];
            const connect_ex = resource.connect_ex orelse try self.extension(ConnectEx, request.native, &connect_guid);
            resource.connect_ex = connect_ex;
            var unspecified = request.address;
            unspecified.bytes = @splat(0);
            unspecified.port = 0;
            unspecified.scope = 0;
            const bind_length = encode(unspecified, &context.address);
            if (bind(request.native, &context.address, bind_length) != 0) {
                self.last_error = WSAGetLastError();
                return error.NativeFailure;
            }
            context.address_length = encode(request.address, &context.address);
            if (connect_ex(request.native, &context.address, context.address_length, null, 0, null, &context.overlapped) == 0) result = -1;
        },
        .read, .write => {
            context.overlapped.offset = @truncate(request.offset);
            context.overlapped.offset_high = @truncate(request.offset >> 32);
            const success = if (request.kind == .read)
                ReadFile(@ptrFromInt(request.native), buffer.ptr, context.buffer.length, null, &context.overlapped)
            else
                w.WriteFile(@ptrFromInt(request.native), buffer.ptr, context.buffer.length, null, &context.overlapped);
            if (success == 0) {
                self.last_error = @bitCast(w.GetLastError());
                if (self.last_error == 38 and request.kind == .read) {
                    // Immediate EOF produces no IOCP packet and is completed locally.
                    context.active = false;
                    self.queue(.{ .id = request.id, .status = .eof });
                    return;
                }
                if (self.last_error != 997) return error.NativeFailure;
            }
            return;
        },
        else => return error.BackendUnavailable,
    }
    if (result != 0) {
        self.last_error = WSAGetLastError();
        if (self.last_error == 10040 and request.kind == .recv_from) {
            context.active = false;
            self.queue(.{ .id = request.id, .bytes = @min(context.transferred, buffer.len), .peer = decode(&context.address), .truncated = true });
            return;
        }
        if (self.last_error != 997) return error.NativeFailure;
    }
    // Synchronous success still produces a packet; never complete it twice.
}

pub fn cancel(self: *Driver, id: t.OpId) void {
    // CancelIoEx requests cancellation; the completion packet still owns retirement.
    self.counters.cancellations +|= 1;
    if (self.requests[id.index].kind == .work or self.requests[id.index].kind == .sync or self.requests[id.index].kind == .open or self.requests[id.index].kind == .stat) {
        self.workers.cancel(id);
        return;
    }
    const context = &self.contexts[id.index];
    if (context.active) _ = CancelIoEx(@ptrFromInt(context.request.?.native), &context.overlapped);
}

pub fn wake(self: *Driver) void {
    // Keep at most one unconsumed wake packet in the port.
    if (@atomicRmw(u32, &self.wake_posted, .Xchg, 1, .acq_rel) != 0) return;
    if (PostQueuedCompletionStatus(self.port, 0, ~@as(usize, 0), null) == 0) @panic("IOCP wake failed");
}

fn wakeThunk(context: *anyopaque) void {
    const self: *Driver = @ptrCast(@alignCast(context));
    self.wake();
}

fn queue(self: *Driver, event: c.Event) void {
    if (!self.completed.push(event)) @panic("IOCP completion reservation lost");
    self.counters.completions +|= 1;
}

fn harvest(self: *Driver, output: []c.Event) usize {
    var count = self.workers.poll(output);
    self.counters.completions +|= count;
    while (count < output.len) {
        output[count] = self.completed.pop() orelse break;
        count += 1;
    }
    return count;
}

pub fn poll(self: *Driver, output: []c.Event, duration: ?u64) Error!usize {
    self.counters.polls +|= 1;
    const present = self.harvest(output);
    if (present != 0) return present;
    const milliseconds: u32 = if (duration) |ns| @intCast(@min(ns / 1_000_000 + @intFromBool(ns % 1_000_000 != 0), 0xfffffffe)) else 0xffffffff;
    var count: u32 = 0;
    if (GetQueuedCompletionStatusEx(self.port, self.entries.ptr, @intCast(@min(self.entries.len, output.len)), &count, milliseconds, 0) == 0) {
        self.last_error = @bitCast(w.GetLastError());
        if (self.last_error == 258) return 0;
        return error.NativeFailure;
    }
    var emitted: usize = 0;
    for (self.entries[0..count]) |entry| {
        const overlapped = entry.overlapped orelse {
            @atomicStore(u32, &self.wake_posted, 0, .release);
            self.counters.wakeups +|= 1;
            continue;
        };

        const context: *Context = @alignCast(@fieldParentPtr("overlapped", overlapped));
        if (!context.active) @panic("unexpected IOCP completion");
        const request = context.request.?;
        // Batched entries carry NTSTATUS, not the thread's last Win32 error value.
        const native_error: u32 = if (entry.internal == 0) 0 else RtlNtStatusToDosError(@truncate(entry.internal));
        var event: c.Event = .{ .id = request.id, .bytes = entry.bytes, .native_error = @bitCast(native_error) };
        if (native_error == 995) event.status = .canceled else if (native_error == 38) event.status = .eof else if (native_error != 0) event.status = .failed;
        if (request.kind == .recv_from and (native_error == 10040 or native_error == 234)) {
            event.status = .ok;
            event.bytes = @min(entry.bytes, request.read_buffer.len);
            event.truncated = true;
        }
        if (event.status == .ok) {
            switch (request.kind) {
                .accept => {
                    var listener = request.native;
                    // AcceptEx sockets inherit listener context only after explicit promotion.
                    if (setsockopt(context.accepted, 0xffff, 0x700b, &listener, @sizeOf(usize)) != 0) {
                        event.status = .failed;
                        event.native_error = WSAGetLastError();
                    } else {
                        event.accepted_native = context.accepted;
                        var length: i32 = 128;
                        if (getpeername(context.accepted, &context.address, &length) == 0) event.peer = decode(&context.address);
                    }
                },
                .connect => if (setsockopt(request.native, 0xffff, 0x7010, null, 0) != 0) {
                    event.status = .failed;
                    event.native_error = WSAGetLastError();
                },
                .recv, .read => if (event.bytes == 0) {
                    event.status = .eof;
                },
                .recv_from => {
                    event.peer = decode(&context.address);
                    event.truncated = event.truncated or context.flags & 0x8000 != 0;
                },
                else => {},
            }
        }
        if (request.kind == .accept and event.accepted_native == t.invalid_native and context.accepted != t.invalid_native) _ = closesocket(context.accepted);
        context.active = false;
        context.accepted = t.invalid_native;
        output[emitted] = event;
        emitted += 1;
        self.counters.completions +|= 1;
    }
    return emitted + self.harvest(output[emitted..]);
}

pub fn stats(self: *const Driver) c.NativeStats {
    return self.counters;
}

fn encode(address: t.Address, storage: *[128]u8) i32 {
    return @intCast(@import("../os/socket_address.zig").encode(address, storage));
}

const decode = @import("../os/socket_address.zig").decode;
