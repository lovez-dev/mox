//! Multipart/form-data 解析器。
//!
//! RFC 7578 子集实现：解析 `multipart/form-data` 请求体，
//! 返回各 `Part` 的 name / filename / content-type / data 字段。
//! 所有切片均指向传入缓冲区，不分配堆内存（内联的 boundary 比较除外）。
const std = @import("std");

pub const Part = struct {
    /// `Content-Disposition` 里的 `name` 参数。
    name: []const u8 = "",
    /// `Content-Disposition` 里的 `filename` 参数（无则为空）。
    filename: []const u8 = "",
    /// 该 Part 的 Content-Type（无则为空，表示 text/plain）。
    content_type: []const u8 = "",
    /// 原始二进制数据，指向原始 body 切片。
    data: []const u8 = "",
};

pub const ParseError = error{
    MissingBoundary,
    InvalidBoundary,
    TruncatedBody,
    TooManyParts,
};

pub const max_parts = 32;

/// 从 Content-Type 头里提取 boundary 参数值。
/// 输入示例：`multipart/form-data; boundary=----WebKitFormBoundary7MA4`
pub fn extractBoundary(content_type: []const u8) ?[]const u8 {
    const kw = "boundary=";
    const idx = std.mem.indexOf(u8, content_type, kw) orelse return null;
    var val = content_type[idx + kw.len ..];
    if (val.len > 0 and val[0] == '"') {
        val = val[1..];
        if (std.mem.indexOfScalar(u8, val, '"')) |end| val = val[0..end];
    } else {
        // 无引号：到空白或分号截止
        if (std.mem.indexOfAny(u8, val, " \t;")) |end| val = val[0..end];
    }
    return if (val.len > 0) val else null;
}

/// 解析 `body`，以 `boundary` 为分隔符，把每个 Part 写入 `out[0..return_value]`。
/// 返回实际 Part 数量。
pub fn parse(
    body: []const u8,
    boundary: []const u8,
    out: []Part,
) ParseError!usize {
    if (boundary.len == 0) return error.MissingBoundary;
    // RFC: 实际分隔符是 "--" ++ boundary
    var delim_buf: [128]u8 = undefined;
    if (boundary.len + 2 > delim_buf.len) return error.InvalidBoundary;
    delim_buf[0] = '-';
    delim_buf[1] = '-';
    @memcpy(delim_buf[2 .. 2 + boundary.len], boundary);
    const delim = delim_buf[0 .. 2 + boundary.len];

    var pos: usize = 0;
    var count: usize = 0;

    // 跳过第一个分隔符行
    pos = std.mem.indexOf(u8, body, delim) orelse return error.TruncatedBody;
    pos += delim.len;
    // 跳过可能的 CRLF 或 "--"（结尾标记）
    if (pos + 2 <= body.len and body[pos] == '-' and body[pos + 1] == '-') return 0;
    if (pos < body.len and body[pos] == '\r') pos += 1;
    if (pos < body.len and body[pos] == '\n') pos += 1;

    while (pos < body.len) {
        // 找下一个分隔符
        const next = std.mem.indexOf(u8, body[pos..], delim) orelse return error.TruncatedBody;
        const part_raw = body[pos .. pos + next];

        // 在 part_raw 里找头部与数据的分界（\r\n\r\n）
        const header_end = std.mem.indexOf(u8, part_raw, "\r\n\r\n") orelse
            return error.TruncatedBody;
        const headers_block = part_raw[0..header_end];
        // 数据从 "\r\n\r\n" 之后开始，到 part 末尾之前去掉 "\r\n"
        var data = part_raw[header_end + 4 ..];
        if (std.mem.endsWith(u8, data, "\r\n")) data = data[0 .. data.len - 2];

        var part = Part{ .data = data };
        // 解析头部
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
        // 结尾标记 "--" 或跳 CRLF
        if (pos + 2 <= body.len and body[pos] == '-' and body[pos + 1] == '-') break;
        if (pos < body.len and body[pos] == '\r') pos += 1;
        if (pos < body.len and body[pos] == '\n') pos += 1;
    }
    return count;
}

/// 从 `Content-Disposition` 值里提取 `name=` 或 `filename=` 参数。
fn extractParam(header_val: []const u8, param: []const u8) ?[]const u8 {
    // 格式：name="value" 或 name=value
    var i: usize = 0;
    while (i < header_val.len) {
        // 找到参数名
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

// ---- 测试 ------------------------------------------------------------------
test "extractBoundary 解析 boundary 参数" {
    const ct = "multipart/form-data; boundary=----WebKit123";
    try std.testing.expectEqualStrings("----WebKit123", extractBoundary(ct).?);
}

test "extractBoundary 带引号的 boundary" {
    const ct = "multipart/form-data; boundary=\"my boundary\"";
    try std.testing.expectEqualStrings("my boundary", extractBoundary(ct).?);
}

test "parse 解析两个 Part" {
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

test "parse 空 boundary 返回 MissingBoundary" {
    var parts: [4]Part = undefined;
    try std.testing.expectError(error.MissingBoundary, parse("body", "", &parts));
}
