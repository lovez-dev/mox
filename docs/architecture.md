# Architecture

mox separates protocol parsing and application dispatch from transport execution. mox_io supplies socket/file operations and platform backends; the framework does not maintain a second epoll, io_uring, kqueue, or IOCP implementation.

## Request path

A server constructs its router and fixed-capacity loop, binds a listener, then accepts up to its connection limit. Socket completions advance connection state. The HTTP parser establishes one unambiguous request boundary before dispatch. Content-Length consumers can process segments incrementally; ordinary and chunked bodies are buffered within configured limits.

The router resolves methods and path parameters, then invokes the composed handler. Response state retains the request arena while asynchronous sends, file operations, stream producers, or session callbacks can still reference it. Persistent HTTP connections reset request state only after the previous response completes; pipelined bytes remain for the next request.

## Backpressure and bounded state

At the connection limit, acceptance pauses and the kernel backlog holds incoming connections. Request admission, memory budgets, message limits, and bounded output queues constrain different resources. Socket completion drives the next stream-production call, so application producers do not outrun transmission. Handlers execute on the loop by default and must return promptly there. `blocking_handlers` dispatches complete request handlers to the existing mox_io worker pool; queued and running work remains subject to request admission and fixed loop capacity. The loop alone publishes responses, updates observations, and submits transport work. An allocator lock protects the shared dynamic-memory budget across the loop and workers.

WebSocket parsing and fragmentation state remain separate from transport submission. Upgraded connections have a dedicated admission counter and release their ordinary HTTP request slots. `upgradeBlocking` copies each reassembled data message into an arena and runs one message callback at a time off the loop; its reply is copied into the output queue before that arena is released. SSE events and HTTP chunks are encoded into caller-managed buffers before submission. File work uses mox_io's file execution path; proxying uses a separate upstream connection with an explicit response bound.

## Cancellation and release

Successfully submitted operations retain their input/output buffers until the terminal completion is consumed. Closing a connection requests cancellation, then waits for pending operation and close completions before releasing the connection and its storage. Submission failure creates no future completion and must be cleaned up locally.

Graceful shutdown stops accepting and stops admitting new keep-alive requests. Active requests can drain until the configured deadline; forced shutdown cancels them. The deadline ends application draining, while backend cleanup can take longer. A connection is never freed merely because a shutdown timeout expired. Worker operation IDs are cancelled with their connection. Queued callbacks can be skipped, but a running callback must return before its completion releases request storage. If it returns a stream after cancellation, that stream still receives its one cancellation close hook.

## Module responsibilities

`http.zig`, `router.zig`, and `multipart.zig` implement independent codecs and dispatch. `types.zig` defines public handlers and data contracts. `middleware.zig` composes request policies. `server/` handles completion-driven connection lifecycles and response sessions; `websocket/protocol.zig` validates frame syntax and UTF-8. `root.zig` is the public runtime import, and `build.zig` exports the library, asset embedding helper, and optional template build helper.

One `serve` call has one loop thread. Enabling `blocking_handlers` reuses backend workers rather than constructing a second application pool. Application callbacks may then overlap across requests and must synchronize shared mutable state. Body-stream, stream-producer, ordinary WebSocket, and SSE callbacks still execute on the loop; worker WebSocket callbacks are selected separately through `upgradeBlocking`.

## HTML templates

The optional `template` API is independent of HTTP and transport execution. The build helper discovers application HTML files and tracks their contents and directory membership. Zig compile-time evaluation resolves layouts/includes, validates model field types and HTML contexts, and specializes rendering for concrete model types. Rendering performs direct field access without runtime parsing, filesystem reads, dynamic maps, or a shared cache.

Each call maintains its own budgets and output state. UTF-8 validation precedes escaping; safe runs are scanned in 16-byte vectors that also detect forbidden controls. Cancellation is polled between bounded scan blocks. This optimization preserves the same input and output contracts across all sinks. `renderAlloc` shares budgets across its sizing and emission passes, allocating exact output storage once; `renderInto` uses caller memory. See [templates](templates.md) for the supported HTML subset, failure behavior, and lifetimes.
