//! Bounded synchronous sinks. Models remain unchanged for the entire render call.
const std = @import("std");

pub const Limits = struct {
    max_output_bytes: usize = 1024 * 1024,
    max_input_bytes: usize = 8 * 1024 * 1024,
    max_iterations: usize = 100_000,
    max_work: usize = 1_000_000,
    /// Caller keeps this flag alive. Another thread may set it to cancel a render.
    cancelled: ?*const std.atomic.Value(bool) = null,
    /// Optional caller storage, meaningful after a render error. Never contains model data.
    diagnostic: ?*Diagnostic = null,
};

pub const Diagnostic = struct {
    path: []const u8 = "",
    line: usize = 0,
    column: usize = 0,
    /// Layout entries use positions in their expanded source.
    expanded_layout: bool = false,
    phase: enum { render, allocation } = .render,
};

pub const Error = error{ OutputLimitExceeded, InputLimitExceeded, IterationLimitExceeded, WorkLimitExceeded, BufferTooSmall, InvalidText, InvalidUrl, InvalidNumber, Cancelled };

/// References caller memory. Validation is repeated when rendered, including for
/// directly initialized values; the bytes must remain valid and unchanged.
pub const Url = struct {
    bytes: []const u8,

    pub fn init(bytes: []const u8) Error!Url {
        try validateUrl(bytes);
        return .{ .bytes = bytes };
    }
};

pub fn validateUrl(bytes: []const u8) Error!void {
    if (bytes.len == 0 or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUrl;
    for (bytes) |c| if (c <= 0x20 or c == 0x7f or c == '\\') return error.InvalidUrl;
    if (std.mem.startsWith(u8, bytes, "//")) return error.InvalidUrl;
    // A colon before the first path/query/fragment separator denotes a scheme.
    const end = std.mem.indexOfAny(u8, bytes, "/?#") orelse bytes.len;
    if (std.mem.indexOfScalar(u8, bytes[0..end], ':')) |_| {
        if (!std.ascii.startsWithIgnoreCase(bytes, "https://") and !std.ascii.startsWithIgnoreCase(bytes, "http://")) return error.InvalidUrl;
        const start: usize = if (std.ascii.startsWithIgnoreCase(bytes, "https://")) 8 else 7;
        const host_end = std.mem.indexOfAnyPos(u8, bytes, start, "/?#") orelse bytes.len;
        if (start == host_end or std.mem.indexOfScalar(u8, bytes[start..host_end], '@') != null) return error.InvalidUrl;
    }
}

pub fn validateText(bytes: []const u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidText;
    for (bytes) |c| if ((c < 32 and c != 9 and c != 10 and c != 13) or c == 127) return error.InvalidText;
}

pub const Budget = struct {
    limits: Limits,
    input: usize = 0,
    iterations: usize = 0,
    work: usize = 0,

    pub fn at(self: *Budget, comptime location: Diagnostic) void {
        if (self.limits.diagnostic) |diagnostic| diagnostic.* = location;
    }

    pub fn step(self: *Budget) Error!void {
        try self.poll();
        if (self.work >= self.limits.max_work) return error.WorkLimitExceeded;
        self.work += 1;
    }
    pub fn scan(self: *Budget, len: usize) Error!void {
        try self.poll();
        if (len > self.limits.max_input_bytes - self.input) return error.InputLimitExceeded;
        self.input += len;
        const units = len / 64 + @intFromBool(len % 64 != 0);
        if (units > self.limits.max_work - self.work) return error.WorkLimitExceeded;
        self.work += units;
    }
    pub fn poll(self: *Budget) Error!void {
        if (self.limits.cancelled) |flag| if (flag.load(.monotonic)) return error.Cancelled;
    }
    pub fn iteration(self: *Budget) Error!void {
        if (self.iterations >= self.limits.max_iterations) return error.IterationLimitExceeded;
        self.iterations += 1;
        try self.step();
    }
};

pub const Buffer = struct {
    bytes: ?[]u8 = null,
    len: usize = 0,
    limit: usize,

    pub fn writeAll(self: *Buffer, text: []const u8) Error!void {
        if (text.len > self.limit - self.len) return error.OutputLimitExceeded;
        if (self.bytes) |bytes| {
            if (text.len > bytes.len - self.len) return error.BufferTooSmall;
            @memcpy(bytes[self.len..][0..text.len], text);
        }
        self.len += text.len;
    }
};

pub fn Writer(comptime T: type) type {
    return struct {
        target: T,
        len: usize = 0,
        limit: usize,
        pub fn writeAll(self: *@This(), bytes: []const u8) !void {
            if (bytes.len > self.limit - self.len) return error.OutputLimitExceeded;
            try self.target.writeAll(bytes);
            self.len += bytes.len;
        }
    };
}

pub fn isText(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .array => |a| a.child == u8,
        .pointer => |p| (p.size == .slice and p.child == u8) or (p.size == .one and @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8),
        else => false,
    };
}

pub fn scalar(comptime T: type) bool {
    return isText(T) or T == Url or switch (@typeInfo(T)) {
        .bool => true,
        .int => |i| i.bits <= 128,
        .float => |f| f.bits <= 64,
        else => false,
    };
}

pub fn emit(sink: anytype, budget: *Budget, value: anytype) !void {
    const T = @TypeOf(value);
    var scratch: [384]u8 = undefined;
    const bytes: []const u8 = if (comptime isText(T)) (if (@typeInfo(T) == .array) &value else value) else if (T == Url) value.bytes else switch (@typeInfo(T)) {
        .bool => if (value) "true" else "false",
        .int => try std.fmt.bufPrint(&scratch, "{d}", .{value}),
        .float => blk: {
            if (!std.math.isFinite(value)) return error.InvalidNumber;
            break :blk try std.fmt.bufPrint(&scratch, "{d}", .{value});
        },
        else => unreachable,
    };
    try budget.scan(bytes.len);
    if (T == Url) try validateUrl(bytes);
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidText;
    try escape(sink, budget, bytes);
}

fn escape(sink: anytype, budget: *Budget, bytes: []const u8) !void {
    var start: usize = 0;
    var cursor: usize = 0;
    // Text was validated as UTF-8 above. Skip complete safe runs in 16-byte
    // vectors while detecting both markup and forbidden controls; Unicode bytes
    // remain untouched. Poll between bounded scan blocks, including clean input.
    while (cursor < bytes.len) {
        try budget.poll();
        const end = cursor + @min(@as(usize, 256), bytes.len - cursor);
        const Vec = @Vector(16, u8);
        while (end - cursor >= 16) : (cursor += 16) {
            const chunk: Vec = bytes[cursor..][0..16].*;
            const controls = ((chunk < @as(Vec, @splat(32))) & (chunk != @as(Vec, @splat(9))) & (chunk != @as(Vec, @splat(10))) & (chunk != @as(Vec, @splat(13)))) | (chunk == @as(Vec, @splat(127)));
            const markup = (chunk == @as(Vec, @splat('&'))) | (chunk == @as(Vec, @splat('<'))) | (chunk == @as(Vec, @splat('>'))) | (chunk == @as(Vec, @splat('"'))) | (chunk == @as(Vec, @splat('\'')));
            if (!@reduce(.Or, controls | markup)) continue;
            for (bytes[cursor..][0..16], cursor..) |c, i| try escapeByte(sink, bytes, &start, c, i);
        }
        while (cursor < end) : (cursor += 1) try escapeByte(sink, bytes, &start, bytes[cursor], cursor);
    }
    try sink.writeAll(bytes[start..]);
}

fn escapeByte(sink: anytype, bytes: []const u8, start: *usize, c: u8, i: usize) !void {
    if ((c < 32 and c != 9 and c != 10 and c != 13) or c == 127) return error.InvalidText;
    const escaped: []const u8 = switch (c) {
        '&' => "&amp;",
        '<' => "&lt;",
        '>' => "&gt;",
        '"' => "&quot;",
        '\'' => "&#39;",
        else => return,
    };
    if (start.* != i) try sink.writeAll(bytes[start.*..i]);
    try sink.writeAll(escaped);
    start.* = i + 1;
}
