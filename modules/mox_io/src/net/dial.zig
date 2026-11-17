//! Completion-driven hostname connections with sequential address fallback.

const t = @import("../types.zig");
const Error = @import("../error.zig").Error;
const Resolve = @import("resolve.zig");

pub fn Dial(comptime LoopType: type) type {
    return struct {
        const Self = @This();

        pub const State = enum { idle, resolving, connecting, closing, done };
        loop: *LoopType,
        resolve: Resolve,
        state: State = .idle,
        handle: ?t.Handle = null,
        id: ?t.OpId = null,
        result: ?t.Completion = null,
        options: t.SubmitOptions = .{},
        next: usize = 0,
        canceled: bool = false,

        pub fn init(loop: *LoopType, hostname: [:0]const u8, port: u16, addresses: []t.Address) Self {
            return .{ .loop = loop, .resolve = .{ .hostname = hostname, .port = port, .output = addresses } };
        }

        /// Each stage has its own OpId; feed all Loop results through complete().
        pub fn start(self: *Self, options: t.SubmitOptions) Error!void {
            if (self.state != .idle and self.state != .done) return error.Busy;
            if (self.handle != null) return error.Busy;
            const id = try self.resolve.submit(self.loop, options);
            self.options = options;
            self.id = id;
            self.result = null;
            self.next = 0;
            self.canceled = false;
            self.state = .resolving;
        }

        pub fn ready(self: *const Self) bool {
            return self.state == .done;
        }

        /// Transfer a successful connection to the caller; its Loop still owns the resource.
        pub fn takeHandle(self: *Self) Error!t.Handle {
            if (!self.ready() or self.result.?.status != .ok) return error.InvalidState;
            const handle = self.handle orelse return error.InvalidState;
            self.handle = null;
            return handle;
        }

        pub fn cancel(self: *Self) Error!void {
            if (self.state == .idle or self.state == .done) return;
            self.canceled = true;
            if (self.id) |id| _ = try self.loop.cancel(id);
        }

        pub fn complete(self: *Self, event: t.Completion) Error!bool {
            switch (self.state) {
                .idle, .done => return false,
                .resolving, .connecting => {
                    const actual = event.id orelse return false;
                    const expected = self.id.?;
                    if (actual.index != expected.index or actual.generation != expected.generation) return false;
                    self.id = null;
                    self.result = event;
                    if (self.state == .resolving) {
                        _ = self.resolve.complete(event);
                        if (self.canceled or event.status != .ok) {
                            self.finish();
                            return true;
                        }
                        try self.connectNext();
                    } else if (event.status == .ok and !self.canceled) {
                        self.finish();
                    } else try self.closeAttempt();
                },
                .closing => {
                    // A failed attempt retains its handle until the close result arrives.
                    if (event.kind != .close or event.id != null) return false;
                    const handle = self.handle.?;
                    if (handle.index != event.handle.index or handle.generation != event.handle.generation) return false;
                    self.handle = null;
                    if (self.canceled or self.result.?.status == .timed_out) self.finish() else try self.connectNext();
                },
            }
            return true;
        }

        fn finish(self: *Self) void {
            if (self.canceled) self.result.?.status = .canceled;
            self.state = .done;
        }

        fn connectNext(self: *Self) Error!void {
            while (self.next < self.resolve.count) {
                const address = self.resolve.output[self.next];
                self.next += 1;
                const handle = self.loop.openTcp(address.family) catch |err| {
                    self.result.?.status = .failed;
                    self.result.?.library_error = err;
                    continue;
                };
                self.handle = handle;
                // Every attempt shares the original absolute deadline, not a fresh timeout.
                self.id = self.loop.connect(handle, address, self.options) catch |err| {
                    self.result.?.status = .failed;
                    self.result.?.library_error = err;
                    try self.closeAttempt();
                    return;
                };
                self.state = .connecting;
                return;
            }
            self.finish();
        }

        fn closeAttempt(self: *Self) Error!void {
            self.state = .closing;
            self.id = null;
            self.loop.close(self.handle.?, .cancel, 0) catch |err| {
                // Retained native close failures are retried by the Loop.
                if (err != error.NativeFailure) return err;
            };
        }
    };
}
