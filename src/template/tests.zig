const std = @import("std");
const t = @import("../template.zig");

test "typed interpolation and optional narrowing" {
    const User = struct { name: []const u8 };
    const Page = t.Template("<h1>{{ title }}</h1>{% if user %}<p>{{ user.name }}</p>{% else %}<p>Guest</p>{% endif %}", struct { title: []const u8, user: ?User });
    const result = try Page.renderAlloc(std.testing.allocator, .{ .title = "<Home>", .user = .{ .name = "A&B" } }, .{});
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<h1>&lt;Home&gt;</h1><p>A&amp;B</p>", result);
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("<h1>T</h1><p>Guest</p>", try Page.renderInto(&buffer, .{ .title = "T", .user = null }, .{}));
}

test "loops includes layouts URL attributes and expressions" {
    const Item = struct { title: []const u8, url: t.Url };
    const Data = struct { title: []const u8, items: []const Item, disabled: bool, count: u32 };
    const views = t.Bundle(&.{
        .{ .path = "base.html", .text = "<main><h1>{{ title }}</h1>{% block content %}<p>Default</p>{% endblock %}</main>" },
        .{ .path = "item.html", .text = "<li><a href=\"{{ url }}\">{{ title }}</a></li>" },
        .{ .path = "home.html", .text = "{% extends \"base.html\" %}{% block content %}<ul>{% for item in items %}{% include \"item.html\" with item %}{% else %}<li>Empty</li>{% endfor %}</ul><input {% attr disabled when disabled %}>{% if not disabled and count > 0 %}<p>Ready</p>{% endif %}{% endblock %}" },
    }, &.{.{ .path = "home.html", .Model = Data }});
    var buffer: [512]u8 = undefined;
    const items = [_]Item{.{ .title = "A&B", .url = try t.Url.init("/a?b=1&c=2") }};
    try std.testing.expectEqualStrings("<main><h1>Home</h1><ul><li><a href=\"/a?b=1&amp;c=2\">A&amp;B</a></li></ul><input ><p>Ready</p></main>", try views.get("home.html").renderInto(&buffer, .{ .title = "Home", .items = &items, .disabled = false, .count = 1 }, .{}));
}

test "runtime text URL and budget validation" {
    const Page = t.Template("{{ text }}", struct { text: []const u8 });
    var buffer: [16]u8 = undefined;
    try std.testing.expectError(error.InvalidText, Page.renderInto(&buffer, .{ .text = "\xff" }, .{}));
    try std.testing.expectError(error.InvalidText, Page.renderInto(&buffer, .{ .text = "\x00" }, .{}));
    try std.testing.expectError(error.OutputLimitExceeded, Page.renderInto(&buffer, .{ .text = "&&" }, .{ .max_output_bytes = 5 }));
    try std.testing.expectError(error.BufferTooSmall, Page.renderInto(buffer[0..1], .{ .text = "abc" }, .{}));
    try std.testing.expectError(error.InputLimitExceeded, Page.renderAlloc(std.testing.allocator, .{ .text = "abc" }, .{ .max_input_bytes = 5 }));
    try std.testing.expectError(error.WorkLimitExceeded, Page.renderInto(&buffer, .{ .text = "abc" }, .{ .max_work = 0 }));
    for ([_][]const u8{ "javascript:alert(1)", "//host/path", "https://", "a\\b", " /path", "https://user@host" }) |url| try std.testing.expectError(error.InvalidUrl, t.Url.init(url));
    const Link = t.Template("<a href='{{ url }}'>x</a>", struct { url: t.Url });
    try std.testing.expectError(error.InvalidUrl, Link.renderInto(&buffer, .{ .url = .{ .bytes = "javascript:alert(1)" } }, .{}));
}

test "empty loops consume cumulative iteration budget" {
    const Page = t.Template("{% for item in items %}{% endfor %}", struct { items: []const u32 });
    const items = [_]u32{ 1, 2, 3 };
    try std.testing.expectError(error.IterationLimitExceeded, Page.renderAlloc(std.testing.allocator, .{ .items = &items }, .{ .max_iterations = 5 }));
}

test "all sinks agree and writer failures propagate" {
    const Data = struct { text: []const u8, count: i64, enabled: bool, amount: f64 };
    const Page = t.Template("<p title='{{ text }}'>{{ text }} {{ count }} {{ enabled }} {{ amount }}</p>", Data);
    const value: Data = .{ .text = "\"'&<>", .count = -123, .enabled = true, .amount = 1.5 };
    var buffer: [512]u8 = undefined;
    const direct = try Page.renderInto(&buffer, value, .{});
    const allocated = try Page.renderAlloc(std.testing.allocator, value, .{});
    defer std.testing.allocator.free(allocated);
    try std.testing.expectEqualStrings(direct, allocated);
    var bytes: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try Page.renderTo(&writer, value, .{});
    try std.testing.expectEqualStrings(direct, writer.buffered());
    var short: [8]u8 = undefined;
    var failing = std.Io.Writer.fixed(&short);
    try std.testing.expectError(error.WriteFailed, Page.renderTo(&failing, value, .{}));
    try std.testing.expectError(error.InvalidNumber, Page.renderInto(&buffer, .{ .text = "", .count = 0, .enabled = false, .amount = std.math.inf(f64) }, .{}));
}

test "allocation is exact and failures release output" {
    const Page = t.Template("<p>{{ value }}</p>", struct { value: []const u8 });
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const result = try Page.renderAlloc(allocator.allocator(), .{ .value = "&" }, .{});
    try std.testing.expectEqual(@as(usize, 1), allocator.allocations);
    try std.testing.expectEqual(result.len, allocator.allocated_bytes);
    allocator.allocator().free(result);
    try std.testing.expectError(error.OutOfMemory, Page.renderAlloc(std.testing.failing_allocator, .{ .value = "ok" }, .{}));
    // The second pass exceeds the cumulative input cap after allocating output.
    try std.testing.expectError(error.InputLimitExceeded, Page.renderAlloc(allocator.allocator(), .{ .value = "abc" }, .{ .max_input_bytes = 5 }));
    try std.testing.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
}

test "nested loops shadow bindings and expose metadata" {
    const Row = struct { cells: []const u32 };
    const Page = t.Template("{% for item in rows %}{{ loop.index }}:{% for item in item.cells %}{{ item }}{% if loop.last %}!{% endif %}{% else %}empty{% endfor %}{% endfor %}", struct { rows: []const Row });
    const cells = [_]u32{ 7, 8 };
    const rows = [_]Row{ .{ .cells = &cells }, .{ .cells = &.{} } };
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("0:78!1:empty", try Page.renderInto(&buffer, .{ .rows = &rows }, .{}));
}

test "short circuiting and optional paths" {
    const Data = struct { user: ?struct { age: u32 }, a: []const u8, b: []const u8 };
    const Page = t.Template("{% if false and a == b %}bad{% endif %}{% if true or a == b %}yes{% endif %}{% if user %}{% if user.age >= 18 %}adult{% endif %}{% endif %}", Data);
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("yesadult", try Page.renderInto(&buffer, .{ .user = .{ .age = 20 }, .a = "large", .b = "text" }, .{ .max_input_bytes = 0 }));
}

test "plain raw literals RCDATA and template comments" {
    const Page = t.Template("{# hidden #}<script>const x = 1;</script><style>p{color:red}</style><title>{{ text }}</title><textarea>{{ text }}</textarea><!-- comment -->", struct { text: []const u8 });
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("<script>const x = 1;</script><style>p{color:red}</style><title>&lt;/title&gt;</title><textarea>&lt;/title&gt;</textarea><!-- comment -->", try Page.renderInto(&buffer, .{ .text = "</title>" }, .{}));
}

test "byte corpus rejects invalid UTF-8 and escapes markup across sinks" {
    const Page = t.Template("{{ text }}", struct { text: []const u8 });
    var buffer: [16]u8 = undefined;
    for (0..256) |n| {
        const text = [_]u8{@intCast(n)};
        if (n >= 128 or (n < 32 and n != 9 and n != 10 and n != 13) or n == 127) {
            try std.testing.expectError(error.InvalidText, Page.renderInto(&buffer, .{ .text = &text }, .{}));
        } else {
            const direct = try Page.renderInto(&buffer, .{ .text = &text }, .{});
            const allocated = try Page.renderAlloc(std.testing.allocator, .{ .text = &text }, .{});
            defer std.testing.allocator.free(allocated);
            try std.testing.expectEqualStrings(direct, allocated);
            try std.testing.expect(std.mem.indexOfAny(u8, direct, "<>\"'") == null);
        }
    }
    try std.testing.expectEqualStrings("\xe2\x82\xac", try Page.renderInto(&buffer, .{ .text = "\xe2\x82\xac" }, .{}));
}

test "cancellation rejects rendering before output" {
    var flag = std.atomic.Value(bool).init(true);
    const Page = t.Template("<p>hello</p>", struct {});
    var buffer: [32]u8 = undefined;
    try std.testing.expectError(error.Cancelled, Page.renderInto(&buffer, .{}, .{ .cancelled = &flag }));
}

test "runtime diagnostics point to nested source positions without model data" {
    const Page = t.Template("<p>ok</p>\n{% if enabled %}\n{{ value }}{% endif %}", struct { enabled: bool, value: []const u8 });
    var diagnostic: t.Diagnostic = .{};
    var buffer: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidText, Page.renderInto(&buffer, .{ .enabled = true, .value = "\xff" }, .{ .diagnostic = &diagnostic }));
    try std.testing.expectEqualStrings("inline.html", diagnostic.path);
    try std.testing.expectEqual(@as(usize, 3), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
    try std.testing.expect(!diagnostic.expanded_layout);
    try std.testing.expectError(error.OutOfMemory, Page.renderAlloc(std.testing.failing_allocator, .{ .enabled = false, .value = "" }, .{ .diagnostic = &diagnostic }));
    try std.testing.expectEqual(.allocation, diagnostic.phase);
}

test "multibyte text validation covers malformed and boundary codepoints" {
    const Page = t.Template("{{ value }}", struct { value: []const u8 });
    var buffer: [32]u8 = undefined;
    for ([_][]const u8{ "\xc0\xaf", "\xe0\x80\xaf", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xe2\x82", "\xf0\x9f\x92" }) |text| {
        try std.testing.expectError(error.InvalidText, Page.renderInto(&buffer, .{ .value = text }, .{}));
    }
    for ([_][]const u8{ "\xc2\x80", "\xe0\xa0\x80", "\xe2\x80\xa8", "\xf4\x8f\xbf\xbf" }) |text| {
        try std.testing.expectEqualStrings(text, try Page.renderInto(&buffer, .{ .value = text }, .{}));
    }
    const Compare = t.Template("{% if a == b %}yes{% endif %}", struct { a: []const u8, b: []const u8 });
    try std.testing.expectError(error.InvalidText, Compare.renderInto(&buffer, .{ .a = "\xff", .b = "\xff" }, .{}));
}

test "escaping and forbidden bytes at vector and scan block boundaries" {
    const Page = t.Template("{{ value }}", struct { value: []const u8 });
    var text: [273]u8 = undefined;
    var buffer: [2048]u8 = undefined;
    var expected: [2048]u8 = undefined;
    const positions = [_]usize{ 0, 1, 14, 15, 16, 17, 30, 31, 32, 33, 254, 255, 256, 257, 271, 272 };
    for (positions) |position| {
        for (0..128) |byte| {
            @memset(&text, 'a');
            text[position] = @intCast(byte);
            if ((byte < 32 and byte != 9 and byte != 10 and byte != 13) or byte == 127) {
                try std.testing.expectError(error.InvalidText, Page.renderInto(&buffer, .{ .value = &text }, .{}));
                continue;
            }
            const replacement: []const u8 = switch (byte) {
                '&' => "&amp;",
                '<' => "&lt;",
                '>' => "&gt;",
                '"' => "&quot;",
                '\'' => "&#39;",
                else => text[position..][0..1],
            };
            var reference = std.Io.Writer.fixed(&expected);
            try reference.writeAll(text[0..position]);
            try reference.writeAll(replacement);
            try reference.writeAll(text[position + 1 ..]);
            try std.testing.expectEqualStrings(reference.buffered(), try Page.renderInto(&buffer, .{ .value = &text }, .{}));
        }
    }
    // Valid UTF-8 can straddle a vector boundary; it is not markup or a control.
    for ([_]usize{ 13, 14, 15, 253, 254, 255 }) |position| {
        @memset(&text, 'a');
        @memcpy(text[position..][0..4], "\xf0\x9f\x92\xa1");
        try std.testing.expectEqualStrings(&text, try Page.renderInto(&buffer, .{ .value = &text }, .{}));
        text[position + 1] = 0xff;
        try std.testing.expectError(error.InvalidText, Page.renderInto(&buffer, .{ .value = &text }, .{}));
    }
}

test "dense escaping agrees across allocation and writer sinks" {
    const Page = t.Template("{{ value }}", struct { value: []const u8 });
    var text: [257]u8 = @splat('&');
    var expected: [257 * 5]u8 = undefined;
    for (0..text.len) |i| @memcpy(expected[i * 5 ..][0..5], "&amp;");
    var output: [257 * 5]u8 = undefined;
    try std.testing.expectEqualStrings(&expected, try Page.renderInto(&output, .{ .value = &text }, .{}));
    const allocated = try Page.renderAlloc(std.testing.allocator, .{ .value = &text }, .{});
    defer std.testing.allocator.free(allocated);
    try std.testing.expectEqualStrings(&expected, allocated);
    var writer = std.Io.Writer.fixed(&output);
    try Page.renderTo(&writer, .{ .value = &text }, .{});
    try std.testing.expectEqualStrings(&expected, writer.buffered());
    try std.testing.expectError(error.OutputLimitExceeded, Page.renderInto(&output, .{ .value = &text }, .{ .max_output_bytes = expected.len - 1 }));
}

test "cancellation is polled while scanning a long clean run after an escape" {
    const Page = t.Template("{{ value }}", struct { value: []const u8 });
    const Writer = struct {
        flag: *std.atomic.Value(bool),
        written: usize = 0,
        pub fn writeAll(self: *@This(), bytes: []const u8) !void {
            self.written += bytes.len;
            self.flag.store(true, .release);
        }
    };
    var text: [1024]u8 = @splat('a');
    text[0] = '&';
    var flag = std.atomic.Value(bool).init(false);
    var writer: Writer = .{ .flag = &flag };
    try std.testing.expectError(error.Cancelled, Page.renderTo(&writer, .{ .value = &text }, .{ .cancelled = &flag }));
    try std.testing.expectEqual(@as(usize, 5), writer.written);
}
