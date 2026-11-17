# Usage

## Import and configure

Add the dependency and module import as shown in the [README](../README.md).
The package declares its required system libraries. Applications choose their
own entry point, panic handler, and compiler runtime; the optional bootstrap
helpers used by some examples are not required.

`DefaultLoop` selects IOCP on Windows, epoll on Linux, and kqueue on macOS/FreeBSD.
To choose a backend explicitly, use `mox_io.Loop(mox_io.backends.Uring)`, for
example. Probe io_uring with `try mox_io.backends.Uring.probe()` before selecting
it; see [backends](backends.md) for requirements and optional fixed files.

Initialize a Loop at a stable address with a `mox_io.mem.Allocator` and explicit
capacities. `operations` bounds pending operations and results, `resources` bounds
files and sockets, and `inbox` bounds cross-thread commands. Capacities do not grow
automatically. `PageAllocator.allocator()` is a native page-backed provider;
tracking providers can wrap application allocators.

Set `file_threads = 0` for network-only workloads. DNS, pipes, generic blocking
work, and filesystem commands need workers; use `file_threads` or a shared
`file_executor` as described in [operations](operations.md). A shared executor
must remain alive until every attached Loop has been deinitialized.

## Submit, dispatch, and close

1. Create or open resources on the Loop thread. Submit operations such as
   `accept`, `connect`, `recv`, `send`, `read`, or `write` with caller-managed buffers.
2. Save the returned operation IDs or application tags. A submission error admits
   no operation; handle `Capacity` and `QueueFull` as explicit backpressure.
3. Call `poll()` with a completion buffer and a wait policy: `.none`, `.forever`,
   or `.{ .until = deadline }`. Deadlines use monotonic nanoseconds. A poll may
   return zero, so continue driving the Loop while work remains.
4. Check each result's status and byte count, including partial progress on errors
   and EOF. Forward adapter results to their matching `complete()` methods.
5. Keep input paths, contexts, and buffers valid until terminal delivery. Close
   resources and consume their close results before releasing associated state.

Use `Stream.readExact()` and `writeAll()` for full transfers. Raw I/O methods can
return short counts. Independent file offsets permit concurrent file operations;
stream cursor operations are serialized. Wait for preceding writes before syncing.
See [API and lifecycle](api.md) for precise completion and cancellation rules.

For shutdown, seal cross-thread admission, join external producers, and continue
polling until accepted commands, operations, resources, and results are drained.
`deinit()` returns `Busy` if work still references Loop storage. Cancellation does not
interrupt arbitrary blocking callbacks or automatically terminate child processes.

## Run examples

```sh
zig build tcp
zig build file
zig build inbox
zig build runtime -- 4
zig build framed_service -- 9000 1
zig build pipeline
```

The [TCP example](../examples/tcp.zig) includes socket setup, submission, adapter
dispatch, and cleanup. [File I/O](../examples/file.zig) uses explicit offsets;
[inbox](../examples/inbox.zig) posts work from another thread.

The framed service accepts a two-byte big-endian length from 1 to 4096 and replies
with the body XORed with `0x5a`. It serves the requested number of clients; port
zero prints the assigned port. The pipeline example runs the system `sort` program
with redirected pipes. Both use ordinary application entry points.

## Multiple threads and statistics

One Loop runs on one thread. Use `DefaultRuntime` to manage multiple independent
Loops: `threads = 0` selects the detected logical CPU count, while a nonzero value
sets an explicit count. `post()` distributes independent tasks and `postTo()`
routes work to a specific Loop. Existing connections do not migrate automatically.
See [Runtime](runtime.md) for callbacks, startup, and shutdown.

`loop.stats()` reports memory, operation/resource occupancy, and native counters
on the Loop thread. `runtime.stats()` provides a concurrent aggregate snapshot.
These figures do not measure process RSS or every kernel allocation. Size pools
from observed high-water marks and handle capacity rejection explicitly.

## Memory and embedded filesystems

Attach an asset directory from the application's `build.zig`:

```zig
exe.root_module.addImport("assets", @import("mox_io").embed(b, .{
    .directory = b.path("assets"),
}));
```

Open `@import("assets").image` using `mox_io.fs.EmbeddedFs.init()`. The helper
builds the packer for the host and tracks nested content and directory changes.
Writable memory files use `MemoryFs`; both filesystems operate synchronously.
See [filesystems](filesystems.md) for limits, image format, and data validity.

The [standalone embed example](../examples/embed/build.zig) consumes the package
through a dependency. Run `zig build run` from `examples/embed/`.
