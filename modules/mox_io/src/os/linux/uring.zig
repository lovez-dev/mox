//! Single-issuer Linux io_uring mapping, submission and completion access.

const s = @import("../abi/linux.zig");
const abi = @import("../abi/uring.zig");
const Error = @import("../../error.zig").Error;

pub const Sqe = abi.Sqe;
pub const Cqe = abi.Cqe;
pub const sqe_fixed_file = abi.sqe_fixed_file;
const Parameters = abi.Parameters;
const Probe = abi.Probe;
const Timespec = abi.Timespec;
const WaitArguments = abi.WaitArguments;

pub const Ring = struct {
    fd: i32 = -1,
    sq_map: []u8 = &.{},
    cq_map: []u8 = &.{},
    entries_map: []u8 = &.{},
    sq_head: *u32 = undefined,
    sq_tail: *u32 = undefined,
    cq_head: *u32 = undefined,
    cq_tail: *u32 = undefined,
    sq_array: [*]u32 = undefined,
    entries: [*]Sqe = undefined,
    completions: [*]Cqe = undefined,
    sq_mask: u32 = 0,
    cq_mask: u32 = 0,
    sq_capacity: u32 = 0,
    local_tail: u32 = 0,
    last_error: i32 = 0,
    mapped_bytes: usize = 0,

    pub fn init(self: *Ring, entry_capacity: u32) Error!void {
        self.* = .{};
        // Size the CQ for primary, cancellation and wake completions without drops.
        // SINGLE_ISSUER + DEFER_TASKRUN keep completion work on the polling owner.
        var parameters: Parameters = .{ .cq_entries = entry_capacity * 2, .flags = 8 | 256 | 4096 | 8192 };
        var descriptor = s.uring_setup(entry_capacity, &parameters);
        if (s.errno(descriptor) == 22) {
            parameters = .{ .cq_entries = entry_capacity * 2, .flags = 8 };
            descriptor = s.uring_setup(entry_capacity, &parameters);
        }
        self.last_error = s.errno(descriptor);
        if (self.last_error != 0) return if (self.last_error == 1 or self.last_error == 38 or self.last_error == 95) error.BackendUnavailable else error.NativeFailure;
        self.fd = @intCast(descriptor);
        errdefer self.deinit();
        // Extended waits and native poll retry are required for consistent deadlines.
        if (parameters.features & (2 | 32 | 256) != (2 | 32 | 256)) return error.BackendUnavailable;
        try self.probe();
        const sq_bytes = @as(usize, parameters.sq.array) + @as(usize, parameters.sq_entries) * 4;
        const cq_bytes = @as(usize, parameters.cq.completions) + @as(usize, parameters.cq_entries) * @sizeOf(Cqe);
        const single_map = parameters.features & 1 != 0;
        self.sq_map = try self.map(if (single_map) @max(sq_bytes, cq_bytes) else sq_bytes, 0);
        if (!single_map) self.cq_map = try self.map(cq_bytes, 0x8000000);
        const cq = if (single_map) self.sq_map else self.cq_map;
        self.entries_map = try self.map(@as(usize, parameters.sq_entries) * @sizeOf(Sqe), 0x10000000);
        self.sq_head = pointer(u32, self.sq_map, parameters.sq.head);
        self.sq_tail = pointer(u32, self.sq_map, parameters.sq.tail);
        self.cq_head = pointer(u32, cq, parameters.cq.head);
        self.cq_tail = pointer(u32, cq, parameters.cq.tail);
        self.sq_array = @ptrCast(pointer(u32, self.sq_map, parameters.sq.array));
        self.entries = @ptrCast(@alignCast(self.entries_map.ptr));
        self.completions = @ptrCast(pointer(Cqe, cq, parameters.cq.completions));
        self.sq_mask = pointer(u32, self.sq_map, parameters.sq.mask).*;
        self.cq_mask = pointer(u32, cq, parameters.cq.mask).*;
        self.sq_capacity = parameters.sq_entries;
        self.local_tail = @atomicLoad(u32, self.sq_tail, .acquire);
    }

    fn pointer(comptime T: type, bytes: []u8, offset: u32) *T {
        return @ptrCast(@alignCast(bytes.ptr + offset));
    }

    fn map(self: *Ring, length: usize, offset: usize) Error![]u8 {
        const page = @import("../root.zig").pageSize();
        const rounded = (length + page - 1) & ~(page - 1);
        const result = s.mmap(null, rounded, 3, 1, self.fd, offset);
        self.last_error = s.errno(result);
        if (self.last_error != 0) return error.NativeFailure;
        const bytes: [*]u8 = @ptrFromInt(@as(usize, @bitCast(result)));
        self.mapped_bytes += rounded;
        return bytes[0..rounded];
    }

    fn probe(self: *Ring) Error!void {
        var data: Probe = .{};

        const result = s.uring_register(self.fd, 8, &data, data.operations.len);
        self.last_error = s.errno(result);
        if (self.last_error != 0) return if (self.last_error == 1 or self.last_error == 22 or self.last_error == 38 or self.last_error == 95) error.BackendUnavailable else error.NativeFailure;
        for ([_]u8{ 3, 6, 9, 10, 13, 14, 16, 19, 22, 23, 26, 27 }) |opcode| {
            var supported = false;
            for (data.operations[0..data.length]) |operation| {
                if (operation.opcode == opcode and operation.flags & 1 != 0) supported = true;
            }
            if (!supported) return error.BackendUnavailable;
        }
    }

    /// Empty (-1) slots reserve a fixed-size table without retaining any files.
    pub fn registerFiles(self: *Ring, descriptors: []i32) Error!bool {
        const result = while (true) {
            const value = s.uring_register(self.fd, abi.register_files, descriptors.ptr, @intCast(descriptors.len));
            if (s.errno(value) != 4) break value;
        };
        self.last_error = s.errno(result);
        // Unsupported or policy-disabled registration keeps ordinary descriptors.
        // Resource exhaustion is an initialization error, not a silent fallback.
        if (self.last_error == 1 or self.last_error == 22 or self.last_error == 38 or self.last_error == 95) return false;
        if (self.last_error != 0) return error.NativeFailure;
        return true;
    }

    /// A successful update takes or releases one kernel reference synchronously.
    pub fn updateFile(self: *Ring, index: u32, descriptor: i32) Error!void {
        var value = descriptor;
        var update: abi.FilesUpdate = .{ .offset = index, .descriptors = @intFromPtr(&value) };
        const result = while (true) {
            const updated = s.uring_register(self.fd, abi.register_files_update, &update, 1);
            if (s.errno(updated) != 4) break updated;
        };
        self.last_error = s.errno(result);
        if (self.last_error != 0) return error.NativeFailure;
        if (result != 1) {
            self.last_error = 5; // A one-slot update must report one installed entry.
            return error.NativeFailure;
        }
    }

    pub fn deinit(self: *Ring) void {
        if (self.fd >= 0) _ = s.close(self.fd);
        for ([_][]u8{ self.entries_map, self.cq_map, self.sq_map }) |bytes| {
            if (bytes.len != 0) _ = s.munmap(bytes);
        }
        self.fd = -1;
    }

    pub fn reserve(self: *Ring) ?*Sqe {
        // Only the owner advances local_tail; flush publishes all prepared SQEs together.
        const head = @atomicLoad(u32, self.sq_head, .acquire);
        if (self.local_tail -% head == self.sq_capacity) return null;
        const index = self.local_tail & self.sq_mask;
        self.sq_array[index] = index;
        self.local_tail +%= 1;
        return &self.entries[index];
    }

    pub fn flush(self: *Ring) Error!void {
        // SQE writes become visible before the kernel observes the published tail.
        @atomicStore(u32, self.sq_tail, self.local_tail, .release);
        while (true) {
            const pending = self.local_tail -% @atomicLoad(u32, self.sq_head, .acquire);
            if (pending == 0) return;
            const result = s.uring_enter(self.fd, pending, 0, 0, null);
            self.last_error = s.errno(result);
            if (self.last_error == 4) continue;
            if (self.last_error != 0) return error.NativeFailure;
            if (result == 0) @panic("io_uring submission made no progress");
        }
    }

    pub fn pop(self: *Ring) ?Cqe {
        const head = @atomicLoad(u32, self.cq_head, .monotonic);
        if (head == @atomicLoad(u32, self.cq_tail, .acquire)) return null;
        const event = self.completions[head & self.cq_mask];
        // Copy the CQE before releasing its slot back to the kernel.
        @atomicStore(u32, self.cq_head, head +% 1, .release);
        return event;
    }

    pub fn flushAndWait(self: *Ring, duration: ?u64) Error!void {
        // Publish SQEs before combining their submission with the completion wait.
        @atomicStore(u32, self.sq_tail, self.local_tail, .release);
        const pending = self.local_tail -% @atomicLoad(u32, self.sq_head, .acquire);
        try self.enterWait(duration, pending);
        // EINTR, timeout or partial submission must not strand accepted requests.
        try self.flush();
    }

    pub fn wait(self: *Ring, duration: ?u64) Error!void {
        return self.enterWait(duration, 0);
    }

    fn enterWait(self: *Ring, duration: ?u64, pending: u32) Error!void {
        var timeout: Timespec = .{ .seconds = 0, .nanoseconds = 0 };
        var arguments: WaitArguments = .{};
        if (duration) |ns| {
            timeout = .{ .seconds = @intCast(@min(ns / 1_000_000_000, 0x7fffffff)), .nanoseconds = @intCast(ns % 1_000_000_000) };
            arguments.timeout = @intFromPtr(&timeout);
        }
        const result = s.uring_enter(self.fd, pending, if (duration != null and duration.? == 0) 0 else 1, if (duration != null) 1 | 8 else 1, if (duration != null) &arguments else null);
        self.last_error = s.errno(result);
        if (self.last_error != 0 and self.last_error != 4 and self.last_error != 62) return error.NativeFailure;
    }
};

pub fn capacity(operations: u32) Error!u32 {
    if (operations == 0 or operations > 16383) return error.InvalidOptions;
    var size: u32 = 1;
    while (size < operations * 2 + 1) size *= 2;
    return size;
}
