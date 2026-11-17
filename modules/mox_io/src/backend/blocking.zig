//! Fixed worker records borrowed until the owner consumes their native results.

const t = @import("../types.zig");
const c = @import("common.zig");
const Mutex = @import("../sync/mutex.zig");
const Condition = @import("../sync/condition.zig");
const Thread = @import("../sync/thread.zig");
const Queue = @import("../core/queue.zig").Queue;
const Arena = @import("../mem/arena.zig");
const Layout = @import("../mem/layout.zig").Layout;
const Error = @import("../error.zig").Error;
const Executor = @import("../fs/executor.zig");

const Pool = @This();

const State = enum { free, queued, running, done };

const Job = struct { request: *c.Request = undefined, result: c.Event = undefined, state: State = .free, canceled: bool = false };

pub const Perform = *const fn (*c.Request, []u8) c.Event;

const Worker = struct { thread: Thread = .{}, pool: *Pool = undefined, scratch: []u8 = &.{} };

mutex: Mutex = .{},
condition: Condition = .{},

jobs: []Job,
threads: []Worker,
work: Queue(u32),
completed: Queue(u32),

// The owner remains alive until every worker result retires.
perform: Perform,
wake_context: *anyopaque,
wake_function: *const fn (*anyopaque) void,

stopping: bool = false,
started: usize = 0,
shared: ?Executor.Client = null,

// Owner-only: accepted jobs stay pending until their results are consumed.
pending: usize = 0,

pub fn layout(sizer: *Layout, options: t.Options) Error!void {
    if (options.file_executor != null) return;
    if (options.file_threads > 64) return error.InvalidOptions;
    if (options.file_threads == 0) return;
    const capacity = try c.workerCapacity(options);
    try sizer.add(Job, capacity);
    try sizer.add(Worker, options.file_threads);
    try sizer.add(u32, capacity);
    try sizer.add(u32, capacity);
    try sizer.add(u16, @as(usize, options.file_threads) * options.path_capacity);
}

pub fn init(self: *Pool, arena: *Arena, options: t.Options, perform: Perform, context: *anyopaque, wake_function: *const fn (*anyopaque) void) Error!void {
    if (options.file_executor) |executor| {
        self.* = .{
            .jobs = &.{},
            .threads = &.{},
            .work = .{ .storage = &.{} },
            .completed = .{ .storage = &.{} },
            .perform = perform,
            .wake_context = context,
            .wake_function = wake_function,
            .shared = try executor.attach(try c.workerCapacity(options), options.path_capacity, perform, context, wake_function),
        };
        return;
    }
    if (options.file_threads == 0) {
        self.* = .{ .jobs = &.{}, .threads = &.{}, .work = .{ .storage = &.{} }, .completed = .{ .storage = &.{} }, .perform = perform, .wake_context = context, .wake_function = wake_function };
        return;
    }
    self.* = .{
        .jobs = try arena.allocate(Job, try c.workerCapacity(options)),
        .threads = try arena.allocate(Worker, options.file_threads),
        .work = .{ .storage = try arena.allocate(u32, try c.workerCapacity(options)) },
        .completed = .{ .storage = try arena.allocate(u32, try c.workerCapacity(options)) },
        .perform = perform,
        .wake_context = context,
        .wake_function = wake_function,
    };

    const units = try arena.allocate(u16, @as(usize, options.file_threads) * options.path_capacity);
    const scratch: [*]u8 = @ptrCast(units.ptr);
    for (self.jobs) |*job| job.* = .{};
    try self.mutex.init();
    errdefer self.mutex.deinit();
    try self.condition.init();
    errdefer self.condition.deinit();
    errdefer self.stopThreads();
    for (self.threads, 0..) |*descriptor, index| {
        const length = @as(usize, options.path_capacity) * 2;
        descriptor.* = .{ .pool = self, .scratch = scratch[index * length .. (index + 1) * length] };
        try descriptor.thread.start(worker, descriptor);
        self.started += 1;
    }
}

fn stopThreads(self: *Pool) void {
    self.mutex.lock();
    self.stopping = true;
    self.condition.broadcast();
    self.mutex.unlock();
    for (self.threads[0..self.started]) |*descriptor| descriptor.thread.join();
    self.started = 0;
}

pub fn deinit(self: *Pool) void {
    if (self.shared) |*client| {
        client.deinit();
        self.shared = null;
        return;
    }
    if (self.started == 0) return;
    self.stopThreads();
    self.condition.deinit();
    self.mutex.deinit();
}

pub fn submit(self: *Pool, request: *c.Request) Error!void {
    if (self.shared) |*client| {
        try client.submit(request);
        self.pending += 1;
        return;
    }
    if (self.started == 0) return error.BackendUnavailable;
    self.mutex.lock();
    defer self.mutex.unlock();
    const job = &self.jobs[request.id.index];
    // Operation and close reservations map directly to distinct worker records.
    if (job.state != .free) @panic("worker record reused while active");
    job.* = .{ .request = request, .state = .queued };
    if (!self.work.push(request.id.index)) @panic("worker admission reservation lost");
    self.pending += 1;
    self.condition.signal();
}

pub fn cancel(self: *Pool, id: t.OpId) void {
    if (self.shared) |*client| {
        client.cancel(id);
        return;
    }
    if (self.started == 0) return;
    // Queued jobs skip the syscall; running jobs retire before completion is published.
    self.mutex.lock();
    defer self.mutex.unlock();
    const job = &self.jobs[id.index];
    if (job.state != .free) job.canceled = true;
}

pub fn poll(self: *Pool, output: []c.Event) usize {
    // Network-only pumps do not need the worker or shared executor mutex.
    if (self.pending == 0 or output.len == 0) return 0;
    if (self.shared) |*client| {
        const count = client.poll(output);
        self.pending -= count;
        return count;
    }
    if (self.started == 0) return 0;
    self.mutex.lock();
    defer self.mutex.unlock();
    var count: usize = 0;
    while (count < output.len) {
        const index = self.completed.pop() orelse break;
        output[count] = self.jobs[index].result;
        self.jobs[index].state = .free;
        count += 1;
    }
    self.pending -= count;
    return count;
}

pub fn workerCount(self: *const Pool) u32 {
    return @intCast(if (self.shared) |client| client.executor.started else self.started);
}

pub fn isShared(self: *const Pool) bool {
    return self.shared != null;
}

fn worker(context: *anyopaque) void {
    const descriptor: *Worker = @ptrCast(@alignCast(context));
    const self = descriptor.pool;
    while (true) {
        self.mutex.lock();
        while (self.work.count == 0 and !self.stopping) self.condition.wait(&self.mutex);
        const index = self.work.pop() orelse {
            self.mutex.unlock();
            return;
        };

        const job = &self.jobs[index];
        job.state = .running;
        const canceled = job.canceled;
        const request = job.request;
        self.mutex.unlock();
        // The syscall must not hold the queue lock; cancellation only marks the record.
        const event: c.Event = if (canceled) .{ .id = request.id, .status = .canceled } else if (request.kind == .work) c.performWork(request) else self.perform(request, descriptor.scratch);
        self.mutex.lock();
        job.result = event;
        job.state = .done;
        const was_empty = self.completed.count == 0;
        // Decide the empty-to-nonempty transition under the lock; signal afterward.
        if (!self.completed.push(index)) @panic("worker completion reservation lost");
        self.mutex.unlock();
        if (was_empty) self.wake_function(self.wake_context);
    }
}
