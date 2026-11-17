//! System resolver executed on bounded workers, with caller-owned output storage.

const posix_abi = @import("../os/abi/posix.zig");
const win_abi = @import("../os/abi/windows.zig");
const builtin = @import("builtin");
const t = @import("../types.zig");
const Error = @import("../error.zig").Error;

const Resolve = @This();

const sockaddr = @import("../os/socket_address.zig");

const windows = builtin.os.tag == .windows;
const AddrInfo = if (windows) win_abi.AddrInfo else posix_abi.AddrInfo;
const Win = win_abi;
const Posix = posix_abi;

hostname: [:0]const u8,
port: u16,
output: []t.Address,
family: ?t.Address.Family = null,

// The owner reads these results only after the worker has retired.
count: usize = 0,
truncated: bool = false,
native_error: i32 = 0,
id: ?t.OpId = null,

/// Borrow the hostname, output slice and request through complete(); DNS runs on a worker.
pub fn submit(self: *Resolve, loop: anytype, options: t.SubmitOptions) Error!t.OpId {
    if (self.id != null) return error.Busy;
    if (self.hostname.len == 0 or self.output.len == 0) return error.InvalidOptions;
    for (self.hostname) |byte| if (byte == 0) return error.InvalidOptions;
    self.count = 0;
    self.truncated = false;
    self.native_error = 0;
    const id = try loop.work(.{ .context = self, .run = run, .native_error = &self.native_error }, options);
    self.id = id;
    return id;
}

pub fn complete(self: *Resolve, result: t.Completion) bool {
    const expected = self.id orelse return false;
    const actual = result.id orelse return false;
    if (expected.index != actual.index or expected.generation != actual.generation) return false;
    self.id = null;
    return true;
}

fn run(context: ?*anyopaque, _: usize) Error!usize {
    const self: *Resolve = @ptrCast(@alignCast(context.?));
    const ipv6: i32 = sockaddr.family6;
    var hints: AddrInfo = .{ .flags = 0, .family = 0, .socket_type = 0, .protocol = 0, .length = 0, .address = null, .name = null, .next = null };
    hints.socket_type = 1;
    hints.protocol = 6;
    hints.family = if (self.family) |family| (if (family == .ipv4) 2 else ipv6) else 0;
    var head: ?*AddrInfo = null;
    self.native_error = if (windows) Win.getaddrinfo(self.hostname.ptr, null, &hints, &head) else Posix.getaddrinfo(self.hostname.ptr, null, &hints, &head);
    if (self.native_error != 0) return error.NativeFailure;
    defer if (head) |first| {
        if (windows) Win.freeaddrinfo(first) else Posix.freeaddrinfo(first);
    };
    var cursor = head;
    while (cursor) |item| : (cursor = item.next) {
        if (item.family != 2 and item.family != ipv6) continue;
        const address = item.address orelse continue;
        var value = sockaddr.decodeSlice(address[0..item.length]) orelse continue;
        if ((value.family == .ipv4) != (item.family == 2)) continue;
        value.port = self.port;
        var duplicate = false;
        for (self.output[0..self.count]) |existing| {
            if (existing.family == value.family and existing.scope == value.scope and @import("../mem/bytes.zig").equal(&existing.bytes, &value.bytes)) duplicate = true;
        }
        if (duplicate) continue;
        if (self.count == self.output.len) {
            self.truncated = true;
            continue;
        }
        self.output[self.count] = value;
        self.count += 1;
    }
    if (self.count == 0) return error.NativeFailure;
    return self.count;
}
