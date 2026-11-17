//! Compilation failures exercise schema validation without calling a renderer.
const std = @import("std");
const Case = struct { name: []const u8, source: []const u8, model: []const u8 = "struct { value: []const u8 }", diagnostic: []const u8 };

pub fn add(b: *std.Build, mox: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, step: *std.Build.Step) void {
    const cases = [_]Case{
        .{ .name = "chained-comparison", .source = "{% if true == false == false %}x{% endif %}", .diagnostic = "chained comparisons are unsupported" },
        .{ .name = "close-parent", .source = "<div>{% if true %}</div><div>{% endif %}</div>", .diagnostic = "unbalanced HTML closing tag" },
        .{ .name = "nested-block", .source = "{% if true %}{% block content %}x{% endblock %}{% endif %}", .diagnostic = "blocks cannot be nested inside control blocks or other blocks" },
        .{ .name = "boolean-attribute-value", .source = "<input disabled=\"{{ value }}\">", .model = "struct { value: bool }", .diagnostic = "dynamic attribute is outside the supported safe attribute subset" },
        .{ .name = "missing-field", .source = "{{ missing }}", .diagnostic = "missing field" },
        .{ .name = "optional-value", .source = "{{ value }}", .model = "struct { value: ?u32 }", .diagnostic = "unsupported interpolation type" },
        .{ .name = "string-condition", .source = "{% if value %}x{% endif %}", .diagnostic = "conditions require a boolean or optional" },
        .{ .name = "string-loop", .source = "{% for item in value %}{{ item }}{% endfor %}", .diagnostic = "text is not a loop collection" },
        .{ .name = "url-string", .source = "<a href=\"{{ value }}\">x</a>", .diagnostic = "URL attributes require template.Url: value" },
        .{ .name = "url-prefix", .source = "<a href=\"/{{ value }}\">x</a>", .diagnostic = "URL interpolation must occupy the complete attribute value" },
        .{ .name = "url-suffix", .source = "<a href=\"{{ value }}/\">x</a>", .model = "struct { value: t.Url }", .diagnostic = "URL interpolation must occupy the complete attribute value" },
        .{ .name = "script", .source = "<script>{{ value }}</script>", .diagnostic = "dynamic script/style content is forbidden" },
        .{ .name = "script-double-escape", .source = "<script><!--<script></script>{{ value }}</script>", .diagnostic = "literal '<' in raw text/RCDATA is unsupported unless it closes the element" },
        .{ .name = "style", .source = "<style>{{ value }}</style>", .diagnostic = "dynamic script/style content is forbidden" },
        .{ .name = "event", .source = "<button onclick=\"{{ value }}\">x</button>", .diagnostic = "dynamic attribute is outside the supported safe attribute subset" },
        .{ .name = "srcdoc", .source = "<iframe srcdoc=\"{{ value }}\"></iframe>", .diagnostic = "dynamic attribute is outside the supported safe attribute subset" },
        .{ .name = "srcset", .source = "<img srcset=\"{{ value }}\">", .diagnostic = "dynamic attribute is outside the supported safe attribute subset" },
        .{ .name = "unquoted", .source = "<p id={{ value }}>x</p>", .diagnostic = "interpolation requires HTML text or a quoted attribute" },
        .{ .name = "attribute-name", .source = "<p {{ value }}>x</p>", .diagnostic = "interpolation requires HTML text or a quoted attribute" },
        .{ .name = "tag-name", .source = "<{{ value }}></x>", .diagnostic = "interpolation requires HTML text or a quoted attribute" },
        .{ .name = "comment", .source = "<!-- {{ value }} -->", .diagnostic = "HTML comments must be literal and complete" },
        .{ .name = "abrupt-comment", .source = "<!--><script>{{ value }}</script>-->", .diagnostic = "HTML comments must be literal and complete" },
        .{ .name = "rcdata-close", .source = "<title></tit{{ value }}le><script>{{ value }}</script></title>", .diagnostic = "literal '<' in raw text/RCDATA is unsupported unless it closes the element" },
        .{ .name = "foreign-content", .source = "<svg><text>{{ value }}</text></svg>", .diagnostic = "unsupported HTML element (foreign content and parser-changing elements are forbidden)" },
        .{ .name = "branch-stack", .source = "{% if value %}<p>{% endif %}", .model = "struct { value: bool }", .diagnostic = "block must preserve its HTML context and element stack" },
        .{ .name = "loop-stack", .source = "{% for item in value %}<p>{% endfor %}", .model = "struct { value: []const u32 }", .diagnostic = "block must preserve its HTML context and element stack" },
        .{ .name = "attribute-condition", .source = "<input {% attr disabled when value %}>", .diagnostic = "boolean attribute condition must be bool" },
        .{ .name = "unclosed", .source = "<p>{{ value }}", .diagnostic = "template must be a complete balanced HTML fragment: inline.html" },
        .{ .name = "duplicate-else", .source = "{% if true %}{% else %}{% else %}{% endif %}", .diagnostic = "unexpected or duplicate else" },
        .{ .name = "mismatched-end", .source = "{% if true %}{% endfor %}", .diagnostic = "mismatched template end directive" },
        .{ .name = "path-traversal", .source = "{% include \"../secret.html\" with value %}", .diagnostic = "invalid template path component" },
        .{ .name = "expression-injection", .source = "{{ @import(\"std\") }}", .diagnostic = "invalid identifier: @import(\"std\")" },
    };
    var previous: ?*std.Build.Step = null;
    for (cases) |case| {
        const source = b.fmt("const t = @import(\"mox\").template;\ncomptime {{ _ = t.Template(\"{f}\", {s}); }}\n", .{ std.zig.fmtString(case.source), case.model });
        previous = negative(b, mox, target, optimize, step, previous, case.name, source, case.diagnostic);
    }
    const graphs = [_]struct { name: []const u8, source: []const u8, diagnostic: []const u8 }{
        .{ .name = "unused-entry", .source = "comptime { _ = t.Bundle(&.{.{ .path = \"unused.html\", .text = \"{{ missing }}\" }}, &.{.{ .path = \"unused.html\", .Model = struct {} }}); }", .diagnostic = "missing field" },
        .{ .name = "include-cycle", .source = "comptime { _ = t.Bundle(&.{.{ .path = \"a.html\", .text = \"{% include \\\"a.html\\\" with value %}\" }}, &.{.{ .path = \"a.html\", .Model = struct { value: u32 } }}); }", .diagnostic = "template dependency cycle: a.html" },
        .{ .name = "layout-cycle", .source = "comptime { _ = t.Bundle(&.{.{ .path = \"a.html\", .text = \"{% extends \\\"a.html\\\" %}\" }}, &.{.{ .path = \"a.html\", .Model = struct {} }}); }", .diagnostic = "template dependency cycle: a.html" },
        .{ .name = "unknown-override", .source = "comptime { _ = t.Bundle(&.{.{ .path = \"a.html\", .text = \"{% extends \\\"b.html\\\" %}{% block missing %}x{% endblock %}\" }, .{ .path = \"b.html\", .text = \"{% block content %}{% endblock %}\" }}, &.{.{ .path = \"a.html\", .Model = struct {} }}); }", .diagnostic = "unknown layout block: missing" },
    };
    for (graphs) |case| previous = negative(b, mox, target, optimize, step, previous, case.name, b.fmt("const t = @import(\"mox\").template;\n{s}\n", .{case.source}), case.diagnostic);
}

fn negative(b: *std.Build, mox: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, step: *std.Build.Step, previous: ?*std.Build.Step, name: []const u8, source: []const u8, diagnostic: []const u8) *std.Build.Step {
    const module = b.createModule(.{ .root_source_file = b.addWriteFiles().add(b.fmt("{s}.zig", .{name}), source), .target = target, .optimize = optimize });
    module.addImport("mox", mox);
    const object = b.addObject(.{ .name = b.fmt("reject-template-{s}", .{name}), .root_module = module });
    object.expect_errors = .{ .contains = diagnostic };
    // Bound compiler memory when the surrounding project also builds in parallel.
    if (previous) |dependency| object.step.dependOn(dependency);
    step.dependOn(&object.step);
    return &object.step;
}
