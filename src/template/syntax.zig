//! Bounded compile-time syntax and layout expansion; no source-language evaluation.
const std = @import("std");
pub const Source = struct { path: []const u8, text: []const u8 };
pub const Kind = enum { text, value, safe_html, comment, condition, loop, include, attr, block, extends, end, alternative };
pub const Node = struct {
    kind: Kind,
    text: []const u8,
    body: []const u8 = "",
    alternative: []const u8 = "",
    next: usize,
    offset: usize,
    body_offset: usize = 0,
    alternative_offset: usize = 0,
};
pub fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
}
pub fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn token(source: []const u8, at: usize) Node {
    var i = at;
    while (i + 1 < source.len) : (i += 1) {
        if (source[i] == '{' and (source[i + 1] == '{' or source[i + 1] == '%' or source[i + 1] == '#')) break;
    }
    if (i + 1 >= source.len) i = source.len;
    if (i != at) return .{ .kind = .text, .text = source[at..i], .next = i, .offset = at };
    if (std.mem.startsWith(u8, source[at..], "{{{")) {
        const end = std.mem.indexOfPos(u8, source, at + 3, "}}}") orelse @compileError("unterminated safe HTML interpolation");
        const expression = trim(source[at + 3 .. end]);
        if (expression.len == 0) @compileError("empty safe HTML interpolation");
        return .{ .kind = .safe_html, .text = expression, .next = end + 3, .offset = at };
    }
    const marker = source[at + 1];
    const close = switch (marker) {
        '{' => "}}",
        '%' => "%}",
        '#' => "#}",
        else => unreachable,
    };
    const end = std.mem.indexOfPos(u8, source, at + 2, close) orelse @compileError("unterminated template token");
    const text = trim(source[at + 2 .. end]);
    var node: Node = .{ .kind = .text, .text = text, .next = end + 2, .offset = at };
    if (marker == '#') {
        node.kind = .comment;
        return node;
    }
    if (marker == '{') {
        if (text.len == 0) @compileError("empty interpolation");
        node.kind = .value;
        return node;
    }
    if (eq(text, "else")) {
        node.kind = .alternative;
        return node;
    }
    if (eq(text, "endif") or eq(text, "endfor") or eq(text, "endblock")) {
        node.kind = .end;
        return node;
    }
    const prefixes = .{ "if ", "for ", "include ", "attr ", "block ", "extends " };
    const kinds = [_]Kind{ .condition, .loop, .include, .attr, .block, .extends };
    inline for (prefixes, kinds) |prefix, kind| {
        if (std.mem.startsWith(u8, text, prefix)) {
            node.kind = kind;
            node.text = trim(text[prefix.len..]);
            return node;
        }
    }
    @compileError("unknown template directive: " ++ text);
}

pub fn next(source: []const u8, at: usize) Node {
    return nextDepth(source, at, 0);
}

fn nextDepth(source: []const u8, at: usize, depth: usize) Node {
    if (depth >= 64) @compileError("template control nesting exceeds 64");
    var node = token(source, at);
    if (node.kind != .condition and node.kind != .loop and node.kind != .block) return node;
    const end_tag = switch (node.kind) {
        .condition => "endif",
        .loop => "endfor",
        .block => "endblock",
        else => unreachable,
    };
    const begin = node.next;
    var cursor = begin;
    var split: ?Node = null;
    while (cursor < source.len) {
        const child = nextDepth(source, cursor, depth + 1);
        if (child.kind == .alternative) {
            if (split != null or node.kind == .block) @compileError("unexpected or duplicate else");
            split = child;
        } else if (child.kind == .end) {
            if (!eq(child.text, end_tag)) @compileError("mismatched template end directive");
            node.body = source[begin..if (split) |s| s.offset else cursor];
            node.body_offset = begin;
            if (split) |s| {
                node.alternative = source[s.next..cursor];
                node.alternative_offset = s.next;
            }
            node.next = child.next;
            return node;
        }
        cursor = child.next;
    }
    @compileError("unterminated template block");
}

pub const Reference = struct { path: []const u8, rest: []const u8 };
pub fn reference(text: []const u8) Reference {
    if (text.len < 2 or text[0] != '"') @compileError("template paths must be double-quoted literals");
    const end = std.mem.indexOfScalarPos(u8, text, 1, '"') orelse @compileError("unterminated template path");
    const path = text[1..end];
    validatePath(path);
    return .{ .path = path, .rest = trim(text[end + 1 ..]) };
}
pub fn validatePath(path: []const u8) void {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfAny(u8, path, "\\:\x00\r\n") != null) @compileError("invalid template path");
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len == 0 or eq(part, ".") or eq(part, "..")) @compileError("invalid template path component");
}
pub fn find(sources: []const Source, path: []const u8) []const u8 {
    for (sources) |source| if (eq(source.path, path)) return source.text;
    @compileError("unknown template: " ++ path);
}
pub fn name(text: []const u8) void {
    if (text.len == 0 or (!std.ascii.isAlphabetic(text[0]) and text[0] != '_')) @compileError("invalid identifier: " ++ text);
    for (text) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') @compileError("invalid identifier: " ++ text);
}
pub const Loop = struct { binding: []const u8, expression: []const u8 };
pub fn loop(text: []const u8) Loop {
    const split = std.mem.indexOf(u8, text, " in ") orelse @compileError("for requires 'name in collection'");
    const binding = trim(text[0..split]);
    name(binding);
    if (eq(binding, "loop")) @compileError("loop is a reserved binding");
    return .{ .binding = binding, .expression = trim(text[split + 4 ..]) };
}
pub fn include(text: []const u8) Reference {
    var ref = reference(text);
    if (!std.mem.startsWith(u8, ref.rest, "with ")) @compileError("include requires an explicit model: with value");
    ref.rest = trim(ref.rest[5..]);
    return ref;
}
pub const Attribute = struct { name: []const u8, condition: []const u8 };
pub fn attribute(text: []const u8) Attribute {
    const split = std.mem.indexOf(u8, text, " when ") orelse @compileError("attr requires 'name when condition'");
    return .{ .name = trim(text[0..split]), .condition = trim(text[split + 6 ..]) };
}

const Override = struct { name: []const u8, body: []const u8 };

/// Layout bodies are substituted before context/type validation. The expanded
/// source is bounded independently of original file sizes.
pub fn expand(sources: []const Source, path: []const u8, chain: []const []const u8) []const u8 {
    if (chain.len >= 32) @compileError("template dependency depth exceeds 32");
    for (chain) |parent| if (eq(path, parent)) @compileError("template dependency cycle: " ++ path);
    const source = find(sources, path);
    var cursor: usize = 0;
    var parent: ?[]const u8 = null;
    var overrides: []const Override = &.{};
    var ordinary = false;
    while (cursor < source.len) {
        const node = next(source, cursor);
        switch (node.kind) {
            .extends => {
                if (parent != null or overrides.len != 0 or ordinary) @compileError("extends must be the first directive");
                const ref = reference(node.text);
                if (ref.rest.len != 0) @compileError("unexpected text after layout path");
                parent = ref.path;
            },
            .block => {
                name(node.text);
                for (overrides) |item| if (eq(item.name, node.text)) @compileError("duplicate layout block: " ++ node.text);
                overrides = overrides ++ &[_]Override{.{ .name = node.text, .body = node.body }};
            },
            .comment => {},
            .text => {
                if (trim(node.text).len != 0) ordinary = true;
            },
            else => ordinary = true,
        }
        cursor = node.next;
    }
    if (parent) |parent_path| {
        if (ordinary) @compileError("layout children may only contain extends, blocks, comments and whitespace");
        const base = expand(sources, parent_path, chain ++ &[_][]const u8{path});
        return substitute(base, overrides, true);
    }
    return source;
}

fn substitute(source: []const u8, overrides: []const Override, require_all: bool) []const u8 {
    var used: [128]bool = @splat(false);
    if (overrides.len > used.len) @compileError("too many layout blocks");
    var result: []const u8 = "";
    var cursor: usize = 0;
    while (cursor < source.len) {
        const node = next(source, cursor);
        if (node.kind == .block) {
            var body = node.body;
            for (overrides, 0..) |item, i| {
                if (eq(item.name, node.text)) {
                    body = item.body;
                    used[i] = true;
                }
            }
            // Retain block boundaries for independent HTML context checks and
            // for another child in a multi-level layout chain.
            result = result ++ "{% block " ++ node.text ++ " %}" ++ body ++ "{% endblock %}";
        } else {
            result = result ++ source[cursor..node.next];
        }
        if (result.len > 1024 * 1024) @compileError("expanded template exceeds 1 MiB");
        cursor = node.next;
    }
    if (require_all) for (overrides, 0..) |item, i| {
        if (!used[i]) @compileError("unknown layout block: " ++ item.name);
    };
    return result;
}
