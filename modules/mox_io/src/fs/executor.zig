//! A fixed-capacity blocking executor shared by multiple Loop owners.

const t = @import("../core/values.zig");
const c = @import("../core/execution.zig");
const mem = @import("../mem/allocator.zig");
const Tracking = @import("../mem/tracking.zig");
const Arena = @import("../mem/arena.zig");
const Layout = @import("../mem/layout.zig").Layout;
const Mutex = @import("../sync/mutex.zig");
const Condition = @import("../sync/condition.zig");
const Thread = @import("../sync/thread.zig");
const Queue = @import("../core/queue.zig").Queue;
const Error = @import("../error.zig").Error;

const Executor = @This();

pub const Perform = *const fn (*c.Request, []u8) c.Event;
const Wake = *const fn (*anyopaque) void;

pub const Options = struct { jobs: u32 = 4096, clients: u32 = 16, threads: u32 = 4, path_capacity: u32 = 4096 };

// A completed job stays reserved until its client consumes the native result.
const State = enum { unreserved, free, queued, running, done };

const Job = struct {
    state: State = .unreserved,
    canceled: bool = false,
    client: u32 = t.none,
    next: u32 = t.none,
    request: *c.Request = undefined,
    result: c.Event = undefined,
};

const ClientSlot = struct {
    used: bool = false,
    generation: u64 = 0,
    base: u32 = 0,
    capacity: u32 = 0,
    active: u32 = 0,
    head: u32 = t.none,
    tail: u32 = t.none,
    perform: Perform = undefined,
    wake: Wake = undefined,
    context: *anyopaque = undefined,
};

const Worker = struct { thread: Thread = .{}, executor: *Executor = undefined, scratch: []u8 = &.{} };

pub const Stats = struct {
    memory: Tracking.Stats,
    workers: usize,
    clients: u32,
    jobs_active: u32,
    submitted: u64,
    completed: u64,
    canceled: u64,
    wakeups: u64,
};

// Owned backing and synchronization shared by all attached clients.
tracking: Tracking,
allocation: ?mem.Allocation = null,
mutex: Mutex = .{},
condition: Condition = .{},

// Reservations outlive queued, running and unconsumed completed jobs.
jobs: []Job = &.{},
clients: []ClientSlot = &.{},
threads: []Worker = &.{},
work: Queue(u32) = .{ .storage = &.{} },
path_capacity: usize = 0,
started: usize = 0,

active_clients: u32 = 0,
active_jobs: u32 = 0,
submitted: u64 = 0,
completed: u64 = 0,
canceled: u64 = 0,
wakeups: u64 = 0,

stopping: bool = false,
initialized: bool = false,

pub fn memoryRequired(options: Options) Error!usize {
    if (options.jobs == 0 or options.clients == 0 or options.threads == 0 or options.threads > 64 or options.path_capacity == 0) return error.InvalidOptions;
    var layout: Layout = .{};
    try layout.add(Job, options.jobs);
    try layout.add(ClientSlot, options.clients);
    try layout.add(Worker, options.threads);
    try layout.add(u32, options.jobs);
    try layout.add(u16, @as(usize, options.threads) * options.path_capacity);
    return layout.size;
}

/// Initialize in place; every attached Loop and worker borrows this stable address.
pub fn init(self: *Executor, allocator: mem.Allocator, options: Options) Error!void {
    self.* = .{ .tracking = .{ .parent = allocator }, .path_capacity = options.path_capacity };
    const allocation = try self.tracking.allocator().allocate(try memoryRequired(options), 64);
    self.allocation = allocation;
    errdefer {
        self.tracking.allocator().release(allocation);
        self.allocation = null;
    }
    var arena: Arena = .{ .bytes = allocation.bytes };
    self.jobs = try arena.allocate(Job, options.jobs);
    self.clients = try arena.allocate(ClientSlot, options.clients);
    self.threads = try arena.allocate(Worker, options.threads);
    self.work = .{ .storage = try arena.allocate(u32, options.jobs) };
    const units = try arena.allocate(u16, @as(usize, options.threads) * options.path_capacity);
    const scratch: [*]u8 = @ptrCast(units.ptr);
    for (self.jobs) |*job| job.* = .{};
    for (self.clients) |*client| client.* = .{};
    try self.mutex.init();
    errdefer self.mutex.deinit();
    try self.condition.init();
    errdefer self.condition.deinit();
    errdefer self.stopThreads();
    for (self.threads, 0..) |*descriptor, index| {
        const length = @as(usize, options.path_capacity) * 2;
        descriptor.* = .{ .executor = self, .scratch = scratch[index * length .. (index + 1) * length] };
        try descriptor.thread.start(worker, descriptor);
        self.started += 1;
    }
    self.initialized = true;
}

fn stopThreads(self: *Executor) void {
    self.mutex.lock();
    self.stopping = true;
    self.condition.broadcast();
    self.mutex.unlock();
    for (self.threads[0..self.started]) |*descriptor| descriptor.thread.join();
    self.started = 0;
}

pub fn deinit(self: *Executor) Error!void {
    if (!self.initialized) return error.InvalidState;
    self.mutex.lock();
    const busy = self.active_clients != 0 or self.active_jobs != 0;
    self.mutex.unlock();
    if (busy) return error.Busy;
    // Producers must be detached before the caller destroys the executor.
    self.stopThreads();
    self.condition.deinit();
    self.mutex.deinit();
    self.tracking.allocator().release(self.allocation.?);
    self.allocation = null;
    self.initialized = false;
}

pub fn stats(self: *Executor) Stats {
    if (self.initialized) self.mutex.lock();
    defer if (self.initialized) self.mutex.unlock();
    return .{ .memory = self.tracking.stats(), .workers = self.started, .clients = self.active_clients, .jobs_active = self.active_jobs, .submitted = self.submitted, .completed = self.completed, .canceled = self.canceled, .wakeups = self.wakeups };
}

/// Reserve all job records at attachment, so accepted work cannot run out of storage.
pub fn attach(self: *Executor, capacity: u32, path_capacity: usize, perform: Perform, context: *anyopaque, wake: Wake) Error!Client {
    if (!self.initialized) return error.InvalidState;
    if (path_capacity > self.path_capacity or capacity == 0) return error.InvalidOptions;
    self.mutex.lock();
    defer self.mutex.unlock();
    var client_index: u32 = t.none;
    for (self.clients, 0..) |slot, index| {
        if (!slot.used and slot.generation != ~@as(u64, 0)) {
            client_index = @intCast(index);
            break;
        }
    }
    if (client_index == t.none) return error.Capacity;
    var base: u32 = 0;
    var length: u32 = 0;
    for (self.jobs, 0..) |job, index| {
        if (job.state == .unreserved) {
            if (length == 0) base = @intCast(index);
            length += 1;
            if (length == capacity) break;
        } else length = 0;
    }
    if (length != capacity) return error.Capacity;
    const slot = &self.clients[client_index];
    slot.* = .{ .used = true, .generation = slot.generation + 1, .base = base, .capacity = capacity, .perform = perform, .context = context, .wake = wake };
    for (self.jobs[base .. @as(usize, base) + capacity]) |*job| job.* = .{ .state = .free, .client = client_index };
    self.active_clients += 1;
    return .{ .executor = self, .index = client_index, .generation = slot.generation };
}

pub const Client = struct {
    executor: *Executor,
    index: u32,
    generation: u64,

    fn slot(self: *const Client) *ClientSlot {
        const client = &self.executor.clients[self.index];
        if (!client.used or client.generation != self.generation) @panic("stale executor client");
        return client;
    }

    pub fn deinit(self: *Client) void {
        const executor = self.executor;
        executor.mutex.lock();
        defer executor.mutex.unlock();
        const client = self.slot();
        if (client.active != 0 or client.head != t.none) @panic("executor client detached with active jobs");
        for (executor.jobs[client.base .. @as(usize, client.base) + client.capacity]) |*job| job.* = .{};
        client.used = false;
        executor.active_clients -= 1;
    }

    pub fn submit(self: *Client, request: *c.Request) Error!void {
        const executor = self.executor;
        executor.mutex.lock();
        defer executor.mutex.unlock();
        const client = self.slot();
        if (request.id.index >= client.capacity) return error.Capacity;
        // Each Loop operation maps to its own reserved job; clients cannot steal it.
        const index = client.base + request.id.index;
        const job = &executor.jobs[index];
        if (job.state != .free) @panic("shared worker record reused while active");
        job.* = .{ .state = .queued, .client = self.index, .request = request };
        if (!executor.work.push(index)) @panic("shared work reservation lost");
        client.active += 1;
        executor.active_jobs += 1;
        executor.submitted +|= 1;
        executor.condition.signal();
    }

    pub fn cancel(self: *Client, id: t.OpId) void {
        const executor = self.executor;
        executor.mutex.lock();
        defer executor.mutex.unlock();
        const client = self.slot();
        const job = &executor.jobs[client.base + id.index];
        if (job.state != .free and !job.canceled) {
            job.canceled = true;
            executor.canceled +|= 1;
        }
    }

    pub fn poll(self: *Client, output: []c.Event) usize {
        const executor = self.executor;
        executor.mutex.lock();
        defer executor.mutex.unlock();
        const client = self.slot();
        var count: usize = 0;
        while (count < output.len and client.head != t.none) {
            const job = &executor.jobs[client.head];
            client.head = job.next;
            if (client.head == t.none) client.tail = t.none;
            output[count] = job.result;
            job.state = .free;
            job.next = t.none;
            client.active -= 1;
            executor.active_jobs -= 1;
            count += 1;
        }
        return count;
    }
};

fn worker(context: *anyopaque) void {
    const descriptor: *Worker = @ptrCast(@alignCast(context));
    const self = descriptor.executor;
    while (true) {
        self.mutex.lock();
        while (self.work.count == 0 and !self.stopping) self.condition.wait(&self.mutex);
        const index = self.work.pop() orelse {
            self.mutex.unlock();
            return;
        };

        const job = &self.jobs[index];
        const client = &self.clients[job.client];
        job.state = .running;
        const canceled = job.canceled;
        const request = job.request;
        const perform = client.perform;
        self.mutex.unlock();
        // Do not hold the executor lock across user code or a blocking syscall.
        // Cancellation after this point waits for native retirement in the Loop.
        const event: c.Event = if (canceled) .{ .id = request.id, .status = .canceled } else if (request.kind == .work) c.performWork(request) else perform(request, descriptor.scratch);
        self.mutex.lock();
        job.result = event;
        job.state = .done;
        const was_empty = client.head == t.none;
        if (client.tail != t.none) self.jobs[client.tail].next = index else client.head = index;
        client.tail = index;
        self.completed +|= 1;
        // Detach uses this lock, so the client remains alive until wake returns.
        if (was_empty) {
            client.wake(client.context);
            self.wakeups +|= 1;
        }
        self.mutex.unlock();
    }
}
