//! Shared HTTP field and chunk syntax for origin and upstream message validation.

const std = @import("std");

pub const Field = struct { name: []const u8, value: []const u8 };

pub fn isToken(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |c| {
        if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) == null) return false;
    }
    return true;
}

pub fn validValue(bytes: []const u8) bool {
    for (bytes) |c| if ((c < 0x20 and c != '\t') or c == 0x7f) return false;
    return true;
}

pub fn field(line: []const u8) ?Field {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const name = line[0..colon];
    if (!isToken(name) or !validValue(line[colon + 1 ..])) return null;
    return .{ .name = name, .value = std.mem.trim(u8, line[colon + 1 ..], " \t") };
}

pub fn validHost(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        if (c <= 0x20 or c >= 0x7f or std.mem.indexOfScalar(u8, ",/\\@?#", c) != null) return false;
    }
    return true;
}

pub fn decimal(value: []const u8) ?usize {
    if (value.len == 0) return null;
    for (value) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(usize, value, 10) catch null;
}

pub fn chunkSize(line: []const u8) ?usize {
    var pos: usize = 0;
    while (pos < line.len and std.ascii.isHex(line[pos])) : (pos += 1) {}
    if (pos == 0) return null;
    const size = std.fmt.parseInt(usize, line[0..pos], 16) catch return null;
    while (pos < line.len) {
        while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) : (pos += 1) {}
        if (pos == line.len or line[pos] != ';') return null;
        pos += 1;
        while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) : (pos += 1) {}
        const name = pos;
        while (pos < line.len and isToken(line[pos..][0..1])) : (pos += 1) {}
        if (pos == name) return null;
        var equal = pos;
        while (equal < line.len and (line[equal] == ' ' or line[equal] == '\t')) : (equal += 1) {}
        if (equal == line.len or line[equal] != '=') continue;
        pos = equal + 1;
        while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) : (pos += 1) {}
        if (pos == line.len) return null;
        if (line[pos] == '"') {
            pos += 1;
            while (true) {
                if (pos == line.len) return null;
                const c = line[pos];
                pos += 1;
                if (c == '"') break;
                if (c == '\\') {
                    if (pos == line.len or !validValue(line[pos..][0..1])) return null;
                    pos += 1;
                } else if (!validValue(&.{c})) return null;
            }
        } else {
            const value = pos;
            while (pos < line.len and isToken(line[pos..][0..1])) : (pos += 1) {}
            if (pos == value) return null;
        }
    }
    return size;
}

/// Request trailers must not change authentication or representation interpretation.
pub fn forbiddenTrailer(name: []const u8, direction: enum { request, response }) bool {
    for ([_][]const u8{ "content-length", "transfer-encoding", "connection", "trailer" }) |reserved| {
        if (std.ascii.eqlIgnoreCase(name, reserved)) return true;
    }
    if (direction == .request) {
        for ([_][]const u8{ "host", "expect", "authorization", "proxy-authorization", "cookie", "content-encoding", "content-type", "content-range" }) |reserved| {
            if (std.ascii.eqlIgnoreCase(name, reserved)) return true;
        }
    }
    return false;
}
