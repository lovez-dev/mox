//! Deterministic backend events for owner-side lifecycle tests.

const t = @import("mox_io").types;
const common = @import("mox_io").backend_common;
const Arena = @import("mox_io").mem.Arena;
const Layout = @import("mox_io").Layout;
const Queue = @import("mox_io").Queue;
const Error = @import("mox_io").Error;

const Fake = @This();

pending: []?*common.Request,
events: Queue(common.Event),
last_error: i32 = 0,
cancel_immediately: bool = true,
counters: common.NativeStats = .{},
close_failures: u32 = 0,
last_duration: ?u64 = null,

pub const capabilities: common.Capabilities = .{};

pub fn layout(sizer: *Layout, options: t.Options) Error!void {
    try sizer.add(?*common.Request, options.operations);
    try sizer.add(common.Event, @as(usize, options.operations) * 2 + 4);
}

pub fn init(self: *Fake, arena: *Arena, options: t.Options, _: []common.Request) Error!void {
    self.* = .{
        .pending = try arena.allocate(?*common.Request, options.operations),
        .events = .{ .storage = try arena.allocate(common.Event, @as(usize, options.operations) * 2 + 4) },
    };
    for (self.pending) |*pending| pending.* = null;
}

pub fn deinit(_: *Fake) void {}

pub fn wake(_: *Fake) void {}

pub fn attach(_: *Fake, _: t.Handle, _: usize, _: t.ResourceKind) Error!void {}

pub fn detach(self: *Fake, _: t.Handle, native: usize, kind: t.ResourceKind) common.CloseResult {
    if (self.close_failures != 0) {
        self.close_failures -= 1;
        return .{ .closed = false, .native_error = 5 };
    }
    return closeNative(native, kind);
}

pub fn closeNative(_: usize, _: t.ResourceKind) common.CloseResult {
    return .{};
}

pub fn socket(_: t.ResourceKind, _: t.Address.Family, _: ?t.Address, _: u32) Error!usize {
    return 42;
}

pub fn openFile(_: *Fake, _: []const u8, _: bool, _: bool) Error!usize {
    return 43;
}

pub fn localAddress(_: usize) Error!t.Address {
    return t.Address.loopback(8000);
}

pub fn noDelay(_: usize, _: bool) Error!void {}

pub fn submit(self: *Fake, request: *common.Request) Error!void {
    self.pending[request.id.index] = request;
    self.counters.submissions +|= 1;
}

pub fn cancel(self: *Fake, id: t.OpId) void {
    self.counters.cancellations +|= 1;
    if (self.cancel_immediately) self.complete(.{ .id = id, .status = .canceled });
}

pub fn complete(self: *Fake, event: common.Event) void {
    self.pending[event.id.index] = null;
    if (!self.events.push(event)) @panic("fake event queue full");
}

pub fn poll(self: *Fake, output: []common.Event, duration: ?u64) Error!usize {
    self.last_duration = duration;
    self.counters.polls +|= 1;
    var count: usize = 0;
    while (count < output.len) {
        output[count] = self.events.pop() orelse break;
        count += 1;
        self.counters.completions +|= 1;
    }
    return count;
}

pub fn stats(self: *const Fake) common.NativeStats {
    return self.counters;
}
