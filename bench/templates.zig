//! Equal-output buffered template measurements. The handwritten reference checks
//! text and output bounds but does not implement the engine's work/input budgets.
const std = @import("std");
const mox = @import("mox");
const zlap = @import("zlap");

const Data = struct { title: []const u8, items: []const []const u8 };
const Page = mox.Template("<h1>{{ title }}</h1><ul>{% for item in items %}<li>{{ item }}</li>{% endfor %}</ul>", Data);
const Workload = enum { mixed_short, long_ascii, escape_dense, utf8 };
const output_capacity = 128 * 1024;
var items: [16][]const u8 = undefined;
var data: Data = .{ .title = "Items & descriptions", .items = &items };

pub fn main(init: std.process.Init) !void {
    const config: zlap.Config = .{ .batch_size = 1000, .sample_count = 20, .rounds = 3, .min_sample_ns = 5_000_000, .allocator = init.gpa, .count_allocations = true };
    var payload: [1024]u8 = undefined;
    for (std.meta.tags(Workload)) |workload| {
        configure(workload, &payload);
        var expected: [output_capacity]u8 = undefined;
        var actual: [output_capacity]u8 = undefined;
        const reference = try handwritten(&expected);
        if (!std.mem.eql(u8, reference, try Page.renderInto(&actual, data, .{}))) return error.OutputMismatch;
        const allocated = try Page.renderAlloc(init.gpa, data, .{});
        defer init.gpa.free(allocated);
        if (!std.mem.eql(u8, reference, allocated)) return error.OutputMismatch;
        std.debug.print("Workload: {s}; output: {d} bytes\n", .{ @tagName(workload), reference.len });
        const reference_result = try zlap.runConfigured(init.io, config, manual);
        reference_result.print("Handwritten checked HTML / caller buffer");
        const into_result = try zlap.runConfigured(init.io, config, into);
        into_result.print("Template renderInto / caller buffer");
        const alloc_result = try zlap.runConfigured(init.io, config, alloc);
        alloc_result.print("Template renderAlloc / two passes");
    }
}

fn configure(workload: Workload, payload: *[1024]u8) void {
    switch (workload) {
        .mixed_short => {
            const samples = [_][]const u8{ "plain text", "<&\"'>", "a longer item with a normal description", "\xe2\x82\xac" };
            for (&items, 0..) |*item, i| item.* = samples[i % samples.len];
            return;
        },
        .long_ascii => @memset(payload, 'a'),
        .escape_dense => {
            const markup = "<&\"'>";
            for (payload, 0..) |*byte, i| byte.* = markup[i % markup.len];
        },
        .utf8 => for (0..payload.len / 4) |i| {
            @memcpy(payload[i * 4 ..][0..4], "\xf0\x9f\x92\xa1");
        },
    }
    for (&items) |*item| item.* = payload;
}

fn manual(_: std.mem.Allocator, operations: usize) !void {
    var buffer: [output_capacity]u8 = undefined;
    for (0..operations) |_| {
        std.mem.doNotOptimizeAway(&data);
        std.mem.doNotOptimizeAway(try handwritten(&buffer));
        std.mem.doNotOptimizeAway(&buffer);
    }
}
fn into(_: std.mem.Allocator, operations: usize) !void {
    var buffer: [output_capacity]u8 = undefined;
    for (0..operations) |_| {
        std.mem.doNotOptimizeAway(&data);
        std.mem.doNotOptimizeAway(try Page.renderInto(&buffer, data, .{}));
        std.mem.doNotOptimizeAway(&buffer);
    }
}
fn alloc(gpa: std.mem.Allocator, operations: usize) !void {
    for (0..operations) |_| {
        std.mem.doNotOptimizeAway(&data);
        const output = try Page.renderAlloc(gpa, data, .{});
        std.mem.doNotOptimizeAway(output);
        gpa.free(output);
    }
}

fn handwritten(buffer: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeAll("<h1>");
    try escaped(&writer, data.title);
    try writer.writeAll("</h1><ul>");
    for (data.items) |item| {
        try writer.writeAll("<li>");
        try escaped(&writer, item);
        try writer.writeAll("</li>");
    }
    try writer.writeAll("</ul>");
    return writer.buffered();
}
fn escaped(writer: *std.Io.Writer, text: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidText;
    var start: usize = 0;
    for (text, 0..) |c, i| {
        if ((c < 32 and c != 9 and c != 10 and c != 13) or c == 127) return error.InvalidText;
        const replacement: []const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => continue,
        };
        try writer.writeAll(text[start..i]);
        try writer.writeAll(replacement);
        start = i + 1;
    }
    try writer.writeAll(text[start..]);
}
