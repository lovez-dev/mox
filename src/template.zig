//! Optional compile-time HTML templates with concrete model types.
const std = @import("std");
const syntax = @import("template/syntax.zig");
const html = @import("template/html.zig");
const model = @import("template/model.zig");
const runtime = @import("template/runtime.zig");
pub const Source = syntax.Source;
pub const Limits = runtime.Limits;
pub const Url = runtime.Url;
pub const SafeHtml = runtime.SafeHtml;
pub const Error = runtime.Error;
pub const Diagnostic = runtime.Diagnostic;
pub const Entry = struct { path: []const u8, Model: type };

/// Every registered entry is checked when Bundle is evaluated, even if its
/// renderer is never called. Sources are immutable compile-time constants.
pub fn Bundle(comptime sources: []const Source, comptime entries: []const Entry) type {
    @setEvalBranchQuota(10_000_000);
    comptime {
        var bytes: usize = 0;
        if (sources.len > 1024 or entries.len > 1024) @compileError("too many templates");
        for (sources, 0..) |source, i| {
            syntax.validatePath(source.path);
            if (source.text.len > 1024 * 1024) @compileError("template source exceeds 1 MiB");
            bytes += source.text.len;
            if (bytes > 8 * 1024 * 1024) @compileError("template source graph exceeds 8 MiB");
            if (!std.unicode.utf8ValidateSlice(source.text)) @compileError("template source must be UTF-8");
            for (sources[0..i]) |other| if (syntax.eq(source.path, other.path)) @compileError("duplicate template source");
        }
        for (entries, 0..) |entry, i| {
            for (entries[0..i]) |other| if (syntax.eq(entry.path, other.path)) @compileError("duplicate template entry");
            _ = compile(sources, entry.path, entry.Model);
        }
    }
    return struct {
        pub fn get(comptime path: []const u8) type {
            inline for (entries) |entry| if (comptime syntax.eq(entry.path, path)) return compile(sources, path, entry.Model);
            @compileError("unregistered template entry: " ++ path);
        }
    };
}

pub fn Template(comptime source: []const u8, comptime Model: type) type {
    return Bundle(&.{.{ .path = "inline.html", .text = source }}, &.{.{ .path = "inline.html", .Model = Model }}).get("inline.html");
}

fn compile(comptime sources: []const Source, comptime path: []const u8, comptime Model: type) type {
    @setEvalBranchQuota(10_000_000);
    const source = comptime syntax.expand(sources, path, &.{});
    comptime {
        var state: html.State = .{};
        var nodes: usize = 0;
        validate(sources, source, model.Root(Model), &state, &.{path}, &nodes, 0, true);
        if (!state.boundary() or state.depth != 0) @compileError("template must be a complete balanced HTML fragment: " ++ path);
    }
    return struct {
        /// No heap allocation. On failure discard any prefix written to buffer.
        pub fn renderInto(buffer: []u8, value: Model, limits: Limits) ![]u8 {
            var budget: runtime.Budget = .{ .limits = limits };
            var sink: runtime.Buffer = .{ .bytes = buffer, .limit = limits.max_output_bytes };
            try render(sources, source, model.Root(Model){ .value = value }, &sink, &budget, &.{path}, source, 0);
            return buffer[0..sink.len];
        }
        /// Caller frees the result. Model data must be unchanged during both
        /// passes; work, input and iteration budgets are cumulative across them.
        pub fn renderAlloc(allocator: std.mem.Allocator, value: Model, limits: Limits) ![]u8 {
            var budget: runtime.Budget = .{ .limits = limits };
            var count: runtime.Buffer = .{ .limit = limits.max_output_bytes };
            const env: model.Root(Model) = .{ .value = value };
            try render(sources, source, env, &count, &budget, &.{path}, source, 0);
            budget.at(.{ .path = path, .phase = .allocation });
            const result = try allocator.alloc(u8, count.len);
            errdefer allocator.free(result);
            var sink: runtime.Buffer = .{ .bytes = result, .limit = limits.max_output_bytes };
            try render(sources, source, env, &sink, &budget, &.{path}, source, 0);
            if (sink.len != result.len) return error.ModelChanged;
            return result;
        }
        /// Synchronous writer with writeAll. A failure may leave externally
        /// visible partial output; this is not a resumable HTTP stream.
        pub fn renderTo(writer: anytype, value: Model, limits: Limits) !void {
            var budget: runtime.Budget = .{ .limits = limits };
            var sink: runtime.Writer(@TypeOf(writer)) = .{ .target = writer, .limit = limits.max_output_bytes };
            try render(sources, source, model.Root(Model){ .value = value }, &sink, &budget, &.{path}, source, 0);
        }
    };
}

fn validate(comptime sources: []const Source, comptime source: []const u8, comptime E: type, state: *html.State, comptime chain: []const []const u8, nodes: *usize, depth: usize, blocks_allowed: bool) void {
    if (depth >= 64) @compileError("template control nesting exceeds 64");
    var cursor: usize = 0;
    while (cursor < source.len) {
        const node = syntax.next(source, cursor);
        nodes.* += 1;
        if (nodes.* > 200_000) @compileError("template graph exceeds 200000 operations");
        switch (node.kind) {
            .text => state.feed(node.text),
            .comment => {},
            .value => {
                const context = state.interpolation();
                const T = model.Type(E, node.text);
                if (!runtime.scalar(T)) @compileError("expression '" ++ node.text ++ "' has type " ++ @typeName(T) ++ ": unsupported interpolation type");
                if (context == .url and T != Url) @compileError("URL attributes require template.Url: " ++ node.text);
            },
            .safe_html => {
                if (!state.boundary()) @compileError("SafeHtml requires an HTML text boundary");
                if (model.Type(E, node.text) != SafeHtml) @compileError("raw interpolation requires template.SafeHtml: " ++ node.text);
            },
            .attr => {
                const attr = syntax.attribute(node.text);
                state.booleanAttribute(attr.name);
                if (model.Type(E, attr.condition) != bool) @compileError("boolean attribute condition must be bool");
            },
            .condition, .loop, .block => {
                if (node.kind == .block and !blocks_allowed) @compileError("blocks cannot be nested inside control blocks or other blocks");
                if (!state.boundary()) @compileError("control blocks require an HTML text boundary");
                const Body = switch (node.kind) {
                    .condition => model.narrowed(E, node.text),
                    .loop => blk: {
                        const loop = syntax.loop(node.text);
                        break :blk model.LoopEnv(E, loop.binding, model.Element(model.Type(E, loop.expression)));
                    },
                    else => E,
                };
                var branch = state.*;
                branch.floor = branch.depth;
                validate(sources, node.body, Body, &branch, chain, nodes, depth + 1, false);
                if (!branch.same(state.*)) @compileError("block must preserve its HTML context and element stack");
                branch = state.*;
                branch.floor = branch.depth;
                validate(sources, node.alternative, E, &branch, chain, nodes, depth + 1, false);
                if (!branch.same(state.*)) @compileError("else must preserve its HTML context and element stack");
            },
            .include => {
                if (!state.boundary()) @compileError("includes require an HTML text boundary");
                const ref = syntax.include(node.text);
                const child = syntax.expand(sources, ref.path, chain);
                var branch = state.*;
                branch.floor = branch.depth;
                validate(sources, child, model.Root(model.Type(E, ref.rest)), &branch, chain ++ &[_][]const u8{ref.path}, nodes, depth + 1, true);
                if (!branch.same(state.*)) @compileError("included template must be a balanced HTML fragment");
            },
            else => @compileError("unexpected template directive"),
        }
        cursor = node.next;
    }
}

fn render(comptime sources: []const Source, comptime source: []const u8, env: anytype, sink: anytype, budget: *runtime.Budget, comptime chain: []const []const u8, comptime origin: []const u8, comptime base: usize) anyerror!void {
    @setEvalBranchQuota(10_000_000);
    comptime var cursor: usize = 0;
    inline while (cursor < source.len) {
        const node = comptime syntax.next(source, cursor);
        budget.at(comptime location(sources, chain[chain.len - 1], origin, base + cursor));
        try budget.step();
        switch (comptime node.kind) {
            .text => try sink.writeAll(node.text),
            .comment => {},
            .value => try runtime.emit(sink, budget, try model.eval(env, node.text, budget)),
            .safe_html => try runtime.emitHtml(sink, budget, try model.eval(env, node.text, budget)),
            .attr => {
                const attr = comptime syntax.attribute(node.text);
                if (try model.eval(env, attr.condition, budget)) try sink.writeAll(" " ++ attr.name ++ " ");
            },
            .condition => {
                const value = try model.eval(env, node.text, budget);
                if (model.truth(value)) {
                    const child: model.narrowed(@TypeOf(env), node.text) = if (@typeInfo(@TypeOf(value)) == .optional) .{ .parent = env, .value = value.? } else env;
                    try render(sources, node.body, child, sink, budget, chain, origin, base + node.body_offset);
                } else try render(sources, node.alternative, env, sink, budget, chain, origin, base + node.alternative_offset);
            },
            .loop => {
                const loop = comptime syntax.loop(node.text);
                const items = try model.eval(env, loop.expression, budget);
                for (items, 0..) |item, i| {
                    try budget.iteration();
                    const child: model.LoopEnv(@TypeOf(env), loop.binding, @TypeOf(item)) = .{ .parent = .{ .parent = env, .value = item }, .value = .{ .index = i, .first = i == 0, .last = i + 1 == items.len } };
                    try render(sources, node.body, child, sink, budget, chain, origin, base + node.body_offset);
                }
                if (items.len == 0) try render(sources, node.alternative, env, sink, budget, chain, origin, base + node.alternative_offset);
            },
            .block => try render(sources, node.body, env, sink, budget, chain, origin, base + node.body_offset),
            .include => {
                const ref = comptime syntax.include(node.text);
                const value = try model.eval(env, ref.rest, budget);
                const child_source = comptime syntax.expand(sources, ref.path, chain);
                try render(sources, child_source, model.Root(@TypeOf(value)){ .value = value }, sink, budget, chain ++ &[_][]const u8{ref.path}, child_source, 0);
            },
            else => unreachable,
        }
        cursor = node.next;
    }
}

fn location(comptime sources: []const Source, comptime path: []const u8, comptime source: []const u8, comptime offset: usize) Diagnostic {
    var line: usize = 1;
    var column: usize = 1;
    for (source[0..offset]) |c| {
        if (c == '\n') {
            line += 1;
            column = 1;
        } else column += 1;
    }
    return .{ .path = path, .line = line, .column = column, .expanded_layout = !syntax.eq(source, syntax.find(sources, path)) };
}

test {
    _ = @import("template/tests.zig");
}
