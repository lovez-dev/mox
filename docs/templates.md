# HTML templates

Templates are optional, application-controlled sources compiled into immutable render functions. Request values may be hostile. Template authors and application code are trusted; this is not a sandbox for user-supplied templates. The runtime has no filesystem access, parser, string-keyed field lookup, global cache or lock.

## Files and models

Export concrete model structs from a model module. The module must not import the generated views module:

```zig
const mox = @import("mox");
pub const Item = struct { title: []const u8, url: mox.template.Url };
pub const Home = struct { title: []const u8, items: []const Item };
```

Attach templates in `build.zig` using the same mox module imported by the models and application:

```zig
const mox_module = dep.module("mox");
const models = b.createModule(.{
    .root_source_file = b.path("src/view_models.zig"),
    .target = target,
    .optimize = optimize,
});
models.addImport("mox", mox_module);
const views = @import("mox").templates(b, .{
    .directory = b.path("views"),
    .models = models,
    .mox = mox_module,
    .entries = &.{.{ .path = "home.html", .model = "Home" }},
});
exe.root_module.addImport("views", views);
```

The helper discovers `.html` files recursively. Directory membership and file contents participate in Zig's build graph, including new or removed nested files. Filesystem links are rejected. Sources must exist when configuring the build; generated directories are not supported. Paths use `/`, are relative to the template root, and cannot contain parent traversal or absolute paths. Discovery is deterministic and limited to 4,096 directory entries, 1,024 templates and 32 directory levels.

Parsing, layout expansion, HTML checking and concrete field validation execute at Zig compile time. No host-generated executable is run during cross compilation. Importing the generated module validates every registered entry and its reachable components, including entries whose rendering function is never called. Development changes require rebuilding/restarting. Production binaries contain the immutable templates.

For inline templates use `mox.Template(source, Model)`. For custom build integrations use `mox.template.Bundle(sources, entries)`, where sources have `path` and `text`, and entries have `path` and a `Model` type. `Bundle.get(path)` and `views.get(path)` accept compile-time registered names.

## Syntax

```html
{% extends "layouts/base.html" %}
{% block content %}
<h1>{{ title }}</h1>
<ul>
{% for item in items %}
  {% include "components/item.html" with item %}
{% else %}
  <li>No items.</li>
{% endfor %}
</ul>
{% endblock %}
```

A base layout declares `{% block content %}default content{% endblock %}`. Children may contain only one initial `extends`, named blocks, comments and whitespace. Unknown or duplicate overrides and dependency cycles are rejected. Blocks must be declared outside control blocks; nested block declarations are unsupported. A component receives exactly the model passed after `with`, without merging parent bindings. Its markup must be balanced.

| Construct | Behavior |
| --- | --- |
| `{{ field.path }}` | Escape text, booleans, integers up to 128 bits and finite floats up to 64 bits. Missing fields and unsupported types fail compilation. |
| `{{{ fragment }}}` | Emit an explicitly trusted `mox.template.SafeHtml` only at an HTML text boundary; ordinary strings are rejected. |
| `{% if value %}…{% else %}…{% endif %}` | Accept a boolean or optional. A standalone optional path is available as its payload in the true branch. Other implicit truthiness is rejected. |
| `{% for item in items %}…{% else %}…{% endfor %}` | Iterate arrays or slices. Byte strings are not collections. The else body runs only for zero items. |
| `loop.index`, `loop.first`, `loop.last` | Metadata for the innermost loop; index starts at zero. Nested bindings shadow parent bindings. |
| `{% attr disabled when disabled %}` | Emit an allowlisted boolean attribute only when the expression is true. Place this after whitespace in an opening tag. |
| `{# comment #}` | Remove a template comment. Other literal whitespace is preserved. |

Expressions support field paths, `true`, `false`, decimal signed 64-bit literals, double-quoted string literals, `not`, `and`, `or`, and `== != < > <= >=`. Binary operators require surrounding spaces and are ignored inside quoted strings. String contents are literal bytes with no escape-sequence processing or embedded double quotes. Precedence is `or`, `and`, comparisons, then `not`; boolean operations short-circuit. Comparisons accept integers, same-type floats, boolean equality, or text equality. Parentheses, chained comparisons, indexing, callbacks, arbitrary source-language expressions and implicit optional defaults are unsupported. Compute formatting, localization, authorization and complex expressions in application code.

## HTML and URL safety

The context checker accepts a conservative HTML subset with quoted attribute values, explicitly balanced elements, and complete fragments at every condition, loop, include and block boundary. Both conditional branches must preserve their entry context. It does not emulate browser error recovery or validate every HTML content-model rule.

All scalar output escapes `&`, `<`, `>`, quotes and apostrophes. Text must be valid UTF-8, with no NUL, DEL or control bytes except tab, CR and LF. `title` and `textarea` interpolation is escaped as text. Ordinary strings and `{{ value }}` always use escaping.

For balanced markup from a checked template or a renderer that escapes untrusted source, wrap it with `mox.template.SafeHtml.fromTrusted(bytes)` and use `{{{ fragment }}}`. This is an explicit application trust boundary: it does not sanitize HTML, validate element balance, or reject scripts. Keep the bytes valid and unchanged throughout rendering. Runtime UTF-8/control-byte validation, input/output/work budgets, and cancellation still apply. Raw interpolation is rejected in attributes, comments, tag names, script/style, and title/textarea contexts.

Dynamic ordinary attributes are limited to `id`, `class`, `title`, `alt`, `name`, `value`, `placeholder`, `role`, `lang`, `dir`, `width`, `height`, `colspan`, `rowspan`, `tabindex`, `min`, `max`, `step`, `pattern`, `for`, `datetime`, `download`, `aria-*`, and `data-*`. Attribute values remain data; JavaScript that later interprets them must apply its own appropriate validation.

Dynamic `href`, `src`, `action`, `formaction`, `poster` and `cite` must contain exactly one complete `mox.template.Url`. Literal prefixes/suffixes and multiple interpolations are rejected:

```zig
const url = try mox.template.Url.init("/items?sort=name&limit=20");
```

URLs allow HTTP, HTTPS and relative/query/fragment references. Empty values, protocol-relative URLs, other schemes, backslashes, whitespace/control bytes and HTTP userinfo are rejected. URL validation runs again during rendering, even for directly initialized structs. The validator does not copy bytes, percent-encode components, resolve hosts, authorize destinations or guarantee same-origin navigation. Apply application policies before passing URLs to templates, especially for script/resource sources and redirects. Static URLs and script literals remain the template author's responsibility.

Dynamic tag names, attribute names, unquoted values, comments, doctypes, event handlers, CSS, `srcdoc`, `srcset`, refresh content and script bodies are forbidden. SVG, MathML, custom elements and parser-changing elements such as `noscript`, `template`, `plaintext` and `xmp` are rejected, including literal forms. Use external static assets for these cases. Raw script/style content must be entirely literal; a literal `<` is unsupported except for the element's closing tag, avoiding script escaped-state ambiguities. The same restriction applies to literal `<` in title/textarea; use `&lt;` there. HTML comments cannot contain `<`, `>` or `-` in their body. JSON bootstrap output is not provided; serve JSON separately.

## Output, memory and concurrency

| Method | Allocation and failure contract |
| --- | --- |
| `Page.renderInto(buffer, model, limits)` | No heap allocation. Returns a slice of caller memory. Discard any written prefix after failure. |
| `Page.renderAlloc(allocator, model, limits)` | Validate/count, allocate exactly the output length, then emit. One output allocation for nonempty success. Frees it if emission fails; caller frees successful output with the same allocator. |
| `Page.renderTo(writer, model, limits)` | A synchronous writer with `writeAll`. Propagates writer errors. Output already written cannot be rolled back. |

The model and every referenced byte must remain valid and unchanged throughout the call, including both allocation passes. Concurrent mutation is forbidden. Templates are immutable and can be shared across threads; counters and scratch buffers are per invocation. The caller supplies an allocator/writer suitable for its thread usage.

Return buffered HTML through the existing mox response:

```zig
const body = try views.get("home.html").renderAlloc(ctx.gpa, page, .{
    .max_output_bytes = 256 * 1024,
});
return .{ .body = body, .content_type = "text/html; charset=utf-8" };
```

The framework releases `ctx.gpa` after sending and cleanup. Do not free the body early or return a slice of a handler's stack buffer. Synchronous rendering consumes the event loop's CPU time. `renderTo` is not a resumable `mox.Stream`; asynchronous/cooperative streaming is not implemented.

## Limits and failures

Default limits are 1 MiB output, 8 MiB cumulative dynamic input, 100,000 loop iterations and 1,000,000 work units. Both passes of `renderAlloc` share the input, iteration and work counters. Every executed operation and expression consumes work; string visits are additionally charged in 64-byte units. Empty-output loops still consume iteration budget. Output limits apply to the final output size, not twice its length.

An optional `cancelled: ?*const std.atomic.Value(bool)` flag is polled at operations and during output scans. Keep it valid throughout rendering. Cancellation is cooperative: UTF-8 and URL validation scans finish before the next poll, and an event-loop disconnect cannot interrupt a synchronous handler on that same loop. Limits bound deterministic work rather than elapsed time.

Compilation limits sources to 1 MiB per file, 8 MiB in the source set, 1 MiB per expanded layout, 32 dependency levels, 64 control/HTML levels and 200,000 validated operations per entry. Zig also imposes a compile-time evaluation quota. Large templates and heavily repeated components increase compilation cost and code size.

Errors include invalid text/URL/number, output/input/work/iteration limits, cancellation, insufficient buffer, allocator failure and writer failure. Pass caller storage through `limits.diagnostic` to capture a `mox.template.Diagnostic` on failure without allocations or model data. It identifies the template path, one-based line/column and render/allocation phase. Allocation failures have zero line/column. Layout positions refer to expanded source and set `expanded_layout`; they are not mapped back to the original parent/override file. Do not share diagnostic storage between concurrent renders. Compile errors use Zig diagnostics and instantiation traces. Keep render failures out of public responses and use a simple independent fallback error page.

## Verification and measurement

`zig build test` includes rendering regressions, HTTP integration and expected compilation failures. `zig build test-template-errors` runs only the negative syntax/schema/context cases. `zig build test-package` builds and runs a downstream consumer using discovered template files. `zig build check` compiles the example and benchmark without running target executables.

Run `zig build bench-templates -Doptimize=fast` for repeated equal-output comparisons of a handwritten checked renderer, `renderInto`, and `renderAlloc`. Workloads cover mixed short strings, long ASCII text, dense escaping, and multibyte UTF-8 with 16 list items each. The benchmark checks byte equality before timing and reports cumulative requested allocation bytes. The handwritten baseline validates/escapes text and bounds output, but does not provide the engine's work/input/iteration limits. Two-pass allocation is a memory predictability choice and must not be assumed faster than a supplied buffer. Record measurements only in ignored `out/` when needed, and remove temporary reports after use. No general throughput or latency guarantee follows from this microbenchmark.
