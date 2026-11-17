//! Buffered and incremental multipart/form-data decoding.
//! Buffered parts reference the input; streaming event slices last only through the callback.

const std = @import("std");

pub const Part = struct {
    /// Content-Disposition name parameter.
    name: []const u8 = "",
    /// Optional Content-Disposition filename parameter.
    filename: []const u8 = "",
    /// Optional Content-Type; an empty value implies text/plain.
    content_type: []const u8 = "",
    /// Raw part bytes referencing the input body.
    data: []const u8 = "",
};

pub const ParseError = error{
    MissingBoundary,
    InvalidBoundary,
    TruncatedBody,
    TooManyParts,
};

pub const max_parts = 32;
pub const max_stream_header = 16 * 1024;

pub const StreamEvent = union(enum) {
    part_begin: Part,
    part_data: []const u8,
    part_end,
    complete,
};

pub const StreamHandler = *const fn (?*anyopaque, StreamEvent) anyerror!void;

/// Incremental multipart decoder. It retains only a part header and enough tail
/// bytes to detect a boundary split between input chunks; part data is borrowed.
pub const StreamParser = struct {
    allocator: std.mem.Allocator,
    boundary: []u8,
    delimiter: []u8,
    pending: std.ArrayList(u8) = .empty,
    state: enum { first_boundary, headers, data, boundary_suffix, closing, done, failed } = .first_boundary,
    parts: usize = 0,

    pub fn init(allocator: std.mem.Allocator, boundary: []const u8) (ParseError || std.mem.Allocator.Error)!StreamParser {
        if (boundary.len == 0) return error.MissingBoundary;
        if (boundary.len > 126) return error.InvalidBoundary;
        const owned_boundary = try allocator.dupe(u8, boundary);
        errdefer allocator.free(owned_boundary);
        const delimiter = try std.mem.concat(allocator, u8, &.{ "\r\n--", boundary });
        return .{ .allocator = allocator, .boundary = owned_boundary, .delimiter = delimiter };
    }

    pub fn deinit(self: *StreamParser) void {
        self.pending.deinit(self.allocator);
        self.allocator.free(self.boundary);
        self.allocator.free(self.delimiter);
        self.* = undefined;
    }

    pub fn feed(self: *StreamParser, chunk: []const u8, final: bool, state: ?*anyopaque, handler: StreamHandler) (ParseError || std.mem.Allocator.Error || anyerror)!void {
        if (self.state == .failed or self.state == .done) return error.TruncatedBody;
        try self.pending.appendSlice(self.allocator, chunk);
        while (true) switch (self.state) {
            .first_boundary => {
                const first = try std.mem.concat(self.allocator, u8, &.{ "--", self.boundary });
                defer self.allocator.free(first);
                if (self.pending.items.len < first.len + 2) break;
                if (!std.mem.startsWith(u8, self.pending.items, first)) return self.fail(error.TruncatedBody);
                var used = first.len;
                if (std.mem.startsWith(u8, self.pending.items[used..], "--")) {
                    used += 2;
                    self.consume(used);
                    self.state = .done;
                    try handler(state, .complete);
                    break;
                }
                if (!std.mem.startsWith(u8, self.pending.items[used..], "\r\n")) return self.fail(error.TruncatedBody);
                self.consume(used + 2);
                self.state = .headers;
            },
            .headers => {
                const end = std.mem.indexOf(u8, self.pending.items, "\r\n\r\n") orelse {
                    if (self.pending.items.len > max_stream_header) return self.fail(error.InvalidBoundary);
                    break;
                };
                if (end > max_stream_header) return self.fail(error.InvalidBoundary);
                if (self.parts == max_parts) return self.fail(error.TooManyParts);
                const part = parsePartHeaders(self.pending.items[0..end]);
                self.parts += 1;
                try handler(state, .{ .part_begin = part });
                self.consume(end + 4);
                self.state = .data;
            },
            .data => {
                if (std.mem.indexOf(u8, self.pending.items, self.delimiter)) |at| {
                    if (at > 0) try handler(state, .{ .part_data = self.pending.items[0..at] });
                    self.consume(at + self.delimiter.len);
                    try handler(state, .part_end);
                    self.state = .boundary_suffix;
                } else {
                    const safe = self.pending.items.len -| (self.delimiter.len - 1);
                    if (safe > 0) {
                        try handler(state, .{ .part_data = self.pending.items[0..safe] });
                        self.consume(safe);
                    }
                    break;
                }
            },
            .boundary_suffix => {
                if (self.pending.items.len < 2) break;
                if (std.mem.startsWith(u8, self.pending.items, "--")) {
                    self.consume(2);
                    self.state = .closing;
                } else if (std.mem.startsWith(u8, self.pending.items, "\r\n")) {
                    self.consume(2);
                    self.state = .headers;
                } else return self.fail(error.TruncatedBody);
            },
            .closing => {
                if (self.pending.items.len == 0) {
                    if (!final) break;
                } else if (self.pending.items[0] == '\r') {
                    if (self.pending.items.len < 2) break;
                    if (!std.mem.startsWith(u8, self.pending.items, "\r\n")) return self.fail(error.TruncatedBody);
                    self.consume(2);
                }
                if (self.pending.items.len != 0) return self.fail(error.TruncatedBody);
                if (!final) break;
                self.state = .done;
                try handler(state, .complete);
            },
            .done => break,
            .failed => return error.TruncatedBody,
        };
        if (final and self.state != .done) return self.fail(error.TruncatedBody);
    }

    fn consume(self: *StreamParser, n: usize) void {
        const remaining = self.pending.items.len - n;
        if (remaining > 0) std.mem.copyForwards(u8, self.pending.items[0..remaining], self.pending.items[n..]);
        self.pending.items.len = remaining;
    }

    fn fail(self: *StreamParser, err: ParseError) ParseError {
        self.state = .failed;
        return err;
    }
};

fn parsePartHeaders(headers: []const u8) Part {
    var part = Part{};
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-disposition")) {
            part.name = extractParam(value, "name") orelse "";
            part.filename = extractParam(value, "filename") orelse "";
        } else if (std.ascii.eqlIgnoreCase(name, "content-type")) part.content_type = value;
    }
    return part;
}

/// Extract the boundary parameter from Content-Type without allocating.
pub fn extractBoundary(content_type: []const u8) ?[]const u8 {
    const kw = "boundary=";
    const idx = std.mem.indexOf(u8, content_type, kw) orelse return null;
    var val = content_type[idx + kw.len ..];
    if (val.len > 0 and val[0] == '"') {
        val = val[1..];
        if (std.mem.indexOfScalar(u8, val, '"')) |end| val = val[0..end];
    } else {
        if (std.mem.indexOfAny(u8, val, " \t;")) |end| val = val[0..end];
    }
    return if (val.len > 0) val else null;
}

/// Write parsed parts into out and return their count.
/// Every returned slice remains valid only while body remains unchanged.
pub fn parse(
    body: []const u8,
    boundary: []const u8,
    out: []Part,
) ParseError!usize {
    if (boundary.len == 0) return error.MissingBoundary;
    var delim_buf: [128]u8 = undefined;
    if (boundary.len + 2 > delim_buf.len) return error.InvalidBoundary;
    delim_buf[0] = '-';
    delim_buf[1] = '-';
    @memcpy(delim_buf[2 .. 2 + boundary.len], boundary);
    const delim = delim_buf[0 .. 2 + boundary.len];

    var pos: usize = 0;
    var count: usize = 0;

    pos = std.mem.indexOf(u8, body, delim) orelse return error.TruncatedBody;
    pos += delim.len;
    if (pos + 2 <= body.len and body[pos] == '-' and body[pos + 1] == '-') return 0;
    if (pos < body.len and body[pos] == '\r') pos += 1;
    if (pos < body.len and body[pos] == '\n') pos += 1;

    while (pos < body.len) {
        const next = std.mem.indexOf(u8, body[pos..], delim) orelse return error.TruncatedBody;
        const part_raw = body[pos .. pos + next];

        const header_end = std.mem.indexOf(u8, part_raw, "\r\n\r\n") orelse
            return error.TruncatedBody;
        const headers_block = part_raw[0..header_end];
        var data = part_raw[header_end + 4 ..];
        if (std.mem.endsWith(u8, data, "\r\n")) data = data[0 .. data.len - 2];

        var part = Part{ .data = data };
        var hlines = std.mem.splitSequence(u8, headers_block, "\r\n");
        while (hlines.next()) |hline| {
            const colon = std.mem.indexOfScalar(u8, hline, ':') orelse continue;
            const hname = std.mem.trim(u8, hline[0..colon], " \t");
            const hval = std.mem.trim(u8, hline[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(hname, "content-disposition")) {
                part.name = extractParam(hval, "name") orelse "";
                part.filename = extractParam(hval, "filename") orelse "";
            } else if (std.ascii.eqlIgnoreCase(hname, "content-type")) {
                part.content_type = hval;
            }
        }
        if (count >= out.len) return error.TooManyParts;
        out[count] = part;
        count += 1;

        pos += next + delim.len;
        if (pos + 2 <= body.len and body[pos] == '-' and body[pos + 1] == '-') break;
        if (pos < body.len and body[pos] == '\r') pos += 1;
        if (pos < body.len and body[pos] == '\n') pos += 1;
    }
    return count;
}

/// Extract a name or filename parameter from Content-Disposition.
fn extractParam(header_val: []const u8, param: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < header_val.len) {
        if (i + param.len < header_val.len and
            std.ascii.eqlIgnoreCase(header_val[i .. i + param.len], param) and
            header_val[i + param.len] == '=')
        {
            var val = header_val[i + param.len + 1 ..];
            if (val.len > 0 and val[0] == '"') {
                val = val[1..];
                const end = std.mem.indexOfScalar(u8, val, '"') orelse val.len;
                return val[0..end];
            }
            const end = std.mem.indexOfAny(u8, val, " \t;") orelse val.len;
            return val[0..end];
        }
        i += 1;
    }
    return null;
}

test "extractBoundary reads the boundary parameter" {
    const ct = "multipart/form-data; boundary=----WebKit123";
    try std.testing.expectEqualStrings("----WebKit123", extractBoundary(ct).?);
}

test "extractBoundary reads a quoted boundary" {
    const ct = "multipart/form-data; boundary=\"my boundary\"";
    try std.testing.expectEqualStrings("my boundary", extractBoundary(ct).?);
}

test "parse decodes two parts" {
    const boundary = "BOUND";
    const body =
        "--BOUND\r\n" ++
        "Content-Disposition: form-data; name=\"field1\"\r\n" ++
        "\r\n" ++
        "hello world\r\n" ++
        "--BOUND\r\n" ++
        "Content-Disposition: form-data; name=\"file\"; filename=\"test.txt\"\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "file content\r\n" ++
        "--BOUND--\r\n";
    var parts: [32]Part = undefined;
    const n = try parse(body, boundary, &parts);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("field1", parts[0].name);
    try std.testing.expectEqualStrings("hello world", parts[0].data);
    try std.testing.expectEqualStrings("file", parts[1].name);
    try std.testing.expectEqualStrings("test.txt", parts[1].filename);
    try std.testing.expectEqualStrings("text/plain", parts[1].content_type);
    try std.testing.expectEqualStrings("file content", parts[1].data);
}

test "parse rejects an empty boundary" {
    var parts: [4]Part = undefined;
    try std.testing.expectError(error.MissingBoundary, parse("body", "", &parts));
}

const StreamCollector = struct {
    name: []const u8 = "",
    filename: []const u8 = "",
    bytes: std.ArrayList(u8) = .empty,
    completed: bool = false,

    fn handle(raw: ?*anyopaque, event: StreamEvent) anyerror!void {
        const self: *StreamCollector = @ptrCast(@alignCast(raw.?));
        switch (event) {
            .part_begin => |part| {
                self.name = part.name;
                self.filename = part.filename;
            },
            .part_data => |data| try self.bytes.appendSlice(std.testing.allocator, data),
            .part_end => {},
            .complete => self.completed = true,
        }
    }
};

test "stream parser handles boundaries split between chunks" {
    var parser = try StreamParser.init(std.testing.allocator, "BOUND");
    defer parser.deinit();
    var collector = StreamCollector{};
    defer collector.bytes.deinit(std.testing.allocator);
    const body = "--BOUND\r\nContent-Disposition: form-data; name=\"upload\"; filename=\"a.txt\"\r\nContent-Type: text/plain\r\n\r\nhello multipart\r\n--BOUND--\r\n";
    for (body, 0..) |_, i| try parser.feed(body[i .. i + 1], i + 1 == body.len, &collector, StreamCollector.handle);
    try std.testing.expect(collector.completed);
    try std.testing.expectEqualStrings("upload", collector.name);
    try std.testing.expectEqualStrings("a.txt", collector.filename);
    try std.testing.expectEqualStrings("hello multipart", collector.bytes.items);
}
