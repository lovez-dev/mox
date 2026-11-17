# API contracts

The supported import is `@import("mox")`. `mox.io` exposes the integrated `mox_io` module, and `mox.http` exposes the HTTP codec. Internal source paths are not stable entry points.

## HTML templates

`mox.Template(source, Model)` compiles an inline template. `mox.template.Bundle` registers a fixed set of source/model entries; the build helper exposes the same entry lookup through `views.get(path)`. Entries provide `renderInto(buffer, model, limits)`, `renderAlloc(allocator, model, limits)`, and synchronous `renderTo(writer, model, limits)`. `mox.TemplateLimits` aliases `mox.template.Limits`. Checked URL values use `mox.template.Url`.

The caller keeps model data valid and unchanged for the complete call. Caller-buffer output remains in that buffer; allocated output is released with the supplied allocator after its consumer finishes. With `ctx.gpa`, the framework releases output after response transmission. Limits apply per call, with cumulative input/work/iteration counters across both allocation passes. See [template contracts](templates.md) for context restrictions, diagnostics, cancellation, and partial-output behavior.

## Server configuration

`serve(Config) !void` initializes the listener, runs the loop, and returns after resources retire. Initialization errors propagate to the caller. Per-connection transport failures close the affected connection.

| Field | Meaning |
| --- | --- |
| `gpa` | Allocator for framework and request storage; it must remain usable until return. |
| `address` | `mox.io.types.Address`; use `loopback`, `ipv4`, or `ipv6`. |
| `backend` | `default`, `epoll`, `uring`, `kqueue`, or `iocp`; unsupported selections fail. |
| `routes` | Immutable route definitions and referenced strings; keep them valid until return. |
| `assets` | Optional immutable `EmbeddedFs` view; keep both view and image valid until return. |
| `control` | Optional cross-thread shutdown control; keep it valid until return. |
| `ready` | Optional listener notification; invoked once on the loop thread. |
| `on_request_complete` | Optional observation sink; receives callback-scoped data. |

Defaults select IOCP on Windows, epoll on Linux, and kqueue on supported BSD/macOS systems. Select `uring` explicitly on Linux; kernel and execution-environment support are required.

`max_connections` bounds open client connections. `max_inflight_requests` bounds admitted requests, and `max_requests_per_second` applies a fixed one-second admission window. WebSocket and SSE connections retain an in-flight slot for their session. Zero disables either request-admission limit.

`max_body_size` bounds request bodies; zero removes that specific limit. `max_memory_bytes` bounds dynamic framework/request storage, excluding kernel buffers and loop infrastructure; zero disables the budget. Disabling a limit does not remove other limits or allocator failures. `ws_max_message_size` and `ws_max_queue_size` bound WebSocket messages and queued output.

`idle_timeout_ms` controls idle HTTP connections, `request_timeout_ms` bounds a request from its first received bytes through response transmission, and `shutdown_timeout_ms` bounds the graceful drain period. HTTP deadlines end at WebSocket/SSE upgrade; sessions remain until disconnect, application close, or server shutdown. Zero disables the first two timers and makes graceful shutdown cancel immediately for the last. Timer expiry cancels work; it does not permit freeing memory still referenced by an outstanding I/O operation. A blocking application callback cannot be preempted by these timers.

## Request and response data

`Handler` is `*const fn (*Context) anyerror!Response`. Context, request headers, parameters, and request body slices are temporary and must not escape their documented callback/request lifetime. Copy data into application-managed storage before retaining it.

`ctx.gpa` is a request arena. Allocations remain valid through response transmission and stream cleanup, then the framework reclaims them. `ctx.json(T)` returns `std.json.Parsed(T)`; deinitializing it is safe, and the arena also reclaims its storage at request completion.

A response's body, content type, and header arrays and values must remain valid until transmission completes. Use literals, application-managed storage, or `ctx.gpa`. Returning a slice into a handler's stack is invalid. `file_path` is copied before asynchronous file work. `withJson` accepts serialized JSON; `problem` and `setCookieHeader` allocate using the supplied allocator.

`Response.stream` takes precedence over `file_path` and `body`. `Stream.next` receives a bounded writer and must produce data or finish. `Stream.close(state, end)` runs exactly once for an accepted stream, including failure and cancellation. HEAD does not invoke `next`. Never retain a writer or its output buffer.

`BodyChunkHandler` receives temporary segments and a final flag. Pair initialization with deinitialization to release external upload resources on completion, handler error, or disconnect. An early disconnect does not fabricate a successful final segment.

## Rate limiting middleware

`rateLimit(options)` uses monotonic fixed windows. A bucket starts at its first request and resets when the elapsed time reaches `window_ms`. Requests beyond `max_requests` receive 429 with a `Retry-After` header.

Identical compile-time options share counters across handlers and server threads in the process. By default requests share one bucket. Enable `trust_proxy_headers` only behind a proxy that overwrites incoming forwarding headers; it selects buckets from `X-Real-IP`, then `X-Forwarded-For`. The table holds 1024 buckets and replaces the oldest window when full. Counters are synchronized, and the next handler runs after the lock is released. Separate processes require an external counter for a shared limit.

## Sessions and observation

WebSocket `WsConn` is callback-scoped and cannot be used across threads. Sending copies bytes into the connection queue and reports invalid UTF-8, message limits, closed state, allocation failure, or queue saturation. An accepted send does not mean the peer has received it. Message data is temporary and mutable only during the callback.

`SseWriter` is callback-scoped. Sends copy data into runtime-managed output; its void API does not acknowledge peer delivery. Use the server's resource limits and keep each callback's output bounded.

`RequestEvent` contains a bounded path without the query string. All slices are valid only during `on_request_complete`; copy them if needed later. Completion means framework transmission finished, not that the peer application consumed the response. `jsonAccessLog` emits synchronously, so a slow logging destination can delay the loop.

`getMetrics()` reads process-wide atomic counters independently; its snapshot is not transactional. `metricsHandler` serializes that snapshot as JSON. Multiple servers contribute to the same counters.

## HTTP boundaries and limitations

The codec rejects ambiguous Content-Length/Transfer-Encoding combinations, duplicate framing headers, malformed chunk framing, and unsupported expectations. `parseWithLimit` and `parseHeadWithLimit` use a literal body limit; unlike Config, zero there means no nonempty body is allowed. Input slices must remain valid while using a parsed request.

HTTP/1.1 keep-alive and sequential pipelined requests are supported. Pipelined responses preserve request order. HTTP/2, HTTP/3, TLS, request decompression, automatic DNS, and transparent retry are not supplied by the framework.

HTTP/1.0 supports fixed-length responses; chunked response streams and SSE require HTTP/1.1 and otherwise return 505. Plain informational handler responses are rejected; WebSocket upgrades supply their own validated handshake. A server-initiated WebSocket close waits up to five seconds for peer confirmation before closing the transport.

See [usage](usage.md) for composition and [architecture](architecture.md) for cleanup ordering.
