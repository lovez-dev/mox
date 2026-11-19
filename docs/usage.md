# Usage

## Routes and middleware

Define `Config.routes` using HTTP methods and paths. Literal segments take priority over `:name` parameters, followed by a trailing `*path` wildcard. Wildcard captures include the leading slash. `Context.param` and `query` return encoded text; their `Decoded` variants allocate decoded values with `ctx.gpa` and reject invalid percent escapes.

`group(prefix, routes)` prefixes routes, and `routes(.{ group_a, group_b })` joins groups at compile time. Wrap handlers with `compose(.{ middleware_a, middleware_b }, handler)`; the first middleware runs outermost. Built-ins cover CORS, logging, header checks, rate limits, request IDs, body limits, and cache headers. Authentication and authorization remain application responsibilities.

A GET route also handles HEAD when no explicit HEAD route is selected. The response body is suppressed for HEAD. Unmatched paths use `Config.not_found`; handler errors use `Config.error_handler`.

## Bodies and streams

Ordinary handlers read `ctx.body`. `Config.max_body_size` limits received bodies, including decoded chunked bodies. Chunked request bodies are buffered before dispatch.

For Content-Length uploads, set a route's `on_body`, optionally with `body_stream_init` and `body_stream_deinit`. Each segment is valid only during its callback; the final callback has `final = true`. The normal route handler runs after body consumption. Use the incremental multipart parser when uploads must not be accumulated by the application.

Return `Response.stream` for demand-driven chunked output. Each `next` call writes into a bounded `StreamWriter` and must produce bytes or call `finish()`. The next call waits for the previous output to drain. Allocate stream state with `ctx.gpa` or keep it valid until `close` runs. `close` reports completion, failure, or cancellation and releases application resources; the framework subsequently reclaims the request arena.

For blocking database, password, or filesystem calls in a complete handler, set `Config.blocking_handlers = true` and choose a finite `max_inflight_requests`, such as 128. Handlers then share the existing I/O worker pool and may overlap across requests. Body-stream, response-stream, and SSE callbacks remain on the loop. `ctx.peer` provides the accepted socket address independently of forwarded headers.

## WebSocket and SSE

Return `Response.upgrade(handler)` for WebSocket. The server validates the upgrade and client frames, reassembles fragmented messages, checks text UTF-8, and automatically replies to ping. Handle `sendText` and `sendBinary` errors; the bounded output queue can return `QueueFull`. Connection handles and message slices must remain within the callback.

Use `Response.upgradeBlocking(state, handler)` when a complete WebSocket message needs blocking application work:

```zig
fn messageWork(_: ?*anyopaque, arena: std.mem.Allocator, message: mox.WsMessage) ![]const u8 {
    return arena.dupe(u8, message.data);
}

fn websocket(_: *mox.Context) !mox.Response {
    return mox.Response.upgradeBlocking(null, messageWork);
}
```

The callback receives stable reassembled input and returns one text reply. Use valid UTF-8 for the reply; other input on that connection waits for completion. Do not retain the input/arena or use a `WsConn` from the worker. Connection state can be allocated with `ctx.gpa`; callback errors close with 1011. Upgraded WebSockets use `max_websocket_connections` (default 256) independently of ordinary request capacity.

Return `Response.sse(handler)` for event streams. `writer.send(event, data)` copies an event; multiline data is encoded as separate data fields. Event names must not contain CR or LF. Returning false, or calling `writer.close()`, finishes the stream after queued output. When the handler returns true without sending, `setTick(ms)` schedules another call; zero disables timer-driven pumping.

## Static and embedded files

Register `staticDir("public")` on a route such as `/static/*path`, or return `Response{ .file_path = "public/index.html" }` directly. The runtime checks `Config.assets` first and falls back to disk. File paths are application-controlled; do not pass arbitrary client input as `file_path`. `staticDir` rejects parent traversal, but is not a sandbox against filesystem links.

Attach a generated assets module in the consumer's `build.zig`:

```zig
const assets = @import("mox").embed(b, .{
    .directory = b.path("assets"),
});
exe.root_module.addImport("assets", assets);
```

At runtime, initialize an immutable view and keep it alive while serving:

```zig
const assets = try mox.io.fs.EmbeddedFs.init(@import("assets").image);
try mox.serve(.{
    .gpa = allocator,
    .address = mox.io.types.Address.loopback(8080),
    .routes = app_routes,
    .assets = &assets,
});
```

Embedded paths are relative to the selected directory. Use matching paths in `Response.file_path` or in the prefix passed to `staticDir`.

## HTML templates

Use concrete model types with compile-time templates. Rendering has no template parsing or filesystem access on the request path:

```zig
const Page = mox.Template("<h1>{{ title }}</h1>", struct { title: []const u8 });

fn home(ctx: *mox.Context) !mox.Response {
    const body = try Page.renderAlloc(ctx.gpa, .{ .title = "Home" }, .{ .max_output_bytes = 64 * 1024 });
    return .{ .body = body, .content_type = "text/html; charset=utf-8" };
}
```

For file-based layouts, includes, loops and registered page models, see [templates](templates.md). Build the complete server example with `zig build example-templates`. Data is escaped according to a conservative HTML subset; URL attributes require `mox.template.Url`. Dynamic script/style content and raw HTML strings are rejected.

The model and referenced bytes remain valid and unchanged until rendering returns. With `ctx.gpa`, the framework releases the response body after transmission. Rendering runs synchronously on the server loop; use endpoint-specific limits and move expensive report generation to application-managed background work.

## Proxying

`proxyRoute(method, path, options)` forwards to a fixed-IP HTTP upstream. Set `ProxyOptions.address`, `timeout_ms`, and `max_response_bytes`. Responses are bounded and buffered, rather than relayed as an unbounded stream. DNS resolution, HTTPS upstreams, HTTP/2, and CONNECT tunneling are outside this API. Deploy behind a TLS terminator when HTTPS is required.

## Shutdown and concurrency

`serve` blocks its calling thread until shutdown and I/O cleanup finish. A call runs one event loop; it does not automatically distribute HTTP connections over all CPU cores. By default, handlers, stream callbacks, WebSocket callbacks, and SSE callbacks run on that loop and must return promptly. Enable `blocking_handlers` for complete HTTP handlers, or return `upgradeBlocking` for worker WebSocket message callbacks. These paths reuse the I/O worker pool; synchronize shared mutable application state.

Keep a `ServerControl` alive until `serve` returns. Another thread may call `shutdown()` to stop admitting requests and allow active work to finish within `shutdown_timeout_ms`, or `close()` to cancel immediately. Cleanup still waits until the I/O backend has released references and running worker callbacks have returned. Queued work is cancelled where possible; running callbacks must finish their own bounded blocking calls. Commands are sticky; create a fresh control for each server invocation. The library installs no process signal handlers.

`Config.ready` runs on the loop once the listener is bound, with its actual address. Port zero selects an ephemeral port. The callback must not block; use it to notify another thread.

See [API contracts](api.md) for limits and data lifetimes.
