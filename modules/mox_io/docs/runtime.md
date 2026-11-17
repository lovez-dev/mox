# Multi-owner Runtime

`mox_io.DefaultRuntime` owns one OS thread and one independent Loop per configured
owner. `mox_io.Runtime(Backend)` selects an explicit backend.

## Configuration

```zig
const Runtime = mox_io.DefaultRuntime;
var runtime: Runtime = undefined;
try runtime.init(allocator, .{
    .threads = 0,
    .queue_capacity = 256,
    .completion_batch = 64,
    .loop = .{ .file_threads = 0, .inbox = 0 },
});
```

Zero threads selects the detected logical CPU count, with a maximum of 1024
owners. An explicit nonzero count overrides detection. Linux detection respects
the calling thread's affinity (up to 8192 CPU IDs). Windows counts active
processor groups and respects process affinity on a single-group system.
macOS uses `hw.logicalcpu`; FreeBSD uses `hw.ncpu`. CPU quotas and all forms of
CPU-set restrictions are not inferred. Native detection failures remain errors.

No CPU pinning or scheduler-priority changes are installed. The OS chooses where
threads run; Windows processor-group policy can constrain placement, especially
on older systems with more than 64 logical CPUs. An owner per logical CPU enables
parallelism when enough independent work exists; it does not guarantee 100% CPU
utilization or proportional throughput gains.

Each owner has its own fixed Loop pools, task inbox and completion buffer. Queue
capacity must be a nonzero power of two; completion batch must be nonzero.
`memoryRequired` reports Runtime control backing only. Each running Loop adds
`Loop.memoryRequired(options.loop)` backing. Native mappings, stacks and caller
buffers remain outside those figures. `stats().memory` aggregates Runtime and
Loop backing through a serialized allocation provider. The injected allocator
does not need to handle simultaneous calls from these owners, but other callers
using that allocator must still obey its thread-safety rules.

Blocking file workers default to zero to avoid creating extra worker pools per
CPU. Enable `loop.file_threads` explicitly or supply `loop.file_executor` with a
shared executor sized for all owner reservations. The caller owns that executor;
it must outlive the Runtime. DNS, pipes and generic blocking work need enabled
workers. Runtime owner threads and blocking-worker threads have different roles.

## Application callbacks

```zig
try runtime.start(.{
    .context = &application,
    .start = onStart,       // Optional, Error!void.
    .complete = onComplete, // Required, receives a batch of terminal results.
    .stop = onStop,         // Optional, void.
});

const owner = try runtime.post(.{ .context = &request, .run = beginRequest });
try runtime.postTo(owner, .{ .context = &control, .run = updateRequest });

// Later, after the application decides to stop:
runtime.shutdown();
try runtime.join();
try runtime.deinit();
```

`init`, `start`, `join` and `deinit` belong to the management thread that called
`init`. Keep the Runtime at a stable address. `start` returns after every native
Loop is initialized. No application callback runs before that native barrier.
Start hooks then run asynchronously on their owners, before those owners execute
tasks or dispatch completions. Thus a start-hook failure is reported by `join`,
and may occur before or after `start` returns. Native initialization or thread
creation failure joins every started thread before `start` returns an error.
A Runtime is single-use; after joining, deinitialize it and initialize a new one.

The callback shapes use `Runtime.Worker`:

```zig
fn onStart(context: ?*anyopaque, worker: *Runtime.Worker) mox_io.Error!void;
fn onComplete(context: ?*anyopaque, worker: *Runtime.Worker,
              results: []const mox_io.types.Completion) void;
fn onStop(context: ?*anyopaque, worker: *Runtime.Worker) void;
fn beginRequest(context: ?*anyopaque, worker: *Runtime.Worker) void;
```

Use `worker.index` for per-owner state and `worker.loop()` for owner-local I/O.
Callbacks are serial within an owner and concurrent across owners. Keep them
short; blocking a callback stalls that owner's I/O. `worker.fail(error)` records
an application failure and requests shutdown. Application state must tolerate
partial initialization: admitted tasks still execute even if a start hook fails.
Completions must be dispatched to matching Stream, Dial, Group, pipe, filesystem
or process objects, exactly as when driving a Loop directly. Completion slices
are valid only during the callback.

`post` and `postTo` are thread-safe after successful `start`. Task values are
copied into bounded queues; keep task contexts valid until their callbacks
return. `post` tries queues in round-robin order and returns its chosen owner;
it tries other owners if a queue is full. `postTo` preserves explicit affinity
and returns QueueFull when that owner's queue is full. A synchronous rejection
admits no callback. Backpressure never creates hidden allocations or unbounded
queues. Task and completion batches are bounded to preserve I/O progress.

Handles and operation IDs remain Loop-scoped. After admission, existing work
does not migrate or get stolen. Use `postTo` for connection/session follow-ups;
use `post` for independent work that can start on any owner. The Runtime does
not automatically distribute a single listener or existing connection across
owners. Listener sharding or accepted-socket dispatch requires an explicit
application/backend policy; do not copy a Handle into another Loop. No managed
socket-transfer API is introduced here.

Do not retain Worker/Loop pointers for external cross-thread control. Use Runtime
admission instead; it protects backend lifetime while owners shut down. Avoid
direct external `Loop.post` calls to a managed Loop. Use Loop statistics only
inside owner callbacks; use `runtime.stats()` for a safe aggregate snapshot.

## Shutdown and failures

`shutdown` is thread-safe and idempotent. It seals Runtime admission, wakes all
owners, and lets every accepted task execute. Once all in-flight producers
retire and an owner's task queue empties, that owner's stop hook runs, followed
by Loop shutdown and completion draining. Native Loops are destroyed on their
owner threads. Synchronization prevents shutdown from waking a destroyed
backend. There are no periodic idle polls or hidden timer ticks.

Stop hooks can release callback gates, close external pipe writers or terminate
children so native work can return. They run **before** terminal draining; do not
free outstanding I/O buffers or pending wrapper objects there. Runtime shutdown
does not interrupt arbitrary callbacks or blocking worker operations, kill child
processes automatically, or close caller-owned directory/pipe objects. Ordinary
Loop completion and resource cleanup rules continue to apply.

`join` waits for shutdown; it does not initiate it. An application callback may
call `worker.runtime().shutdown()` when its workload finishes, or the management
thread may call `shutdown` explicitly. Never join from an owner callback:
management methods report WrongThread. `join` is repeatable and returns the
first recorded runtime error after all owners exit. `failure` provides owner,
stage and cause. A failed application/native completion still goes through the
completion hook; it is not automatically a Runtime failure.

`deinit` returns Busy before owners are joined, and refuses to free backing
still referenced by native work that failed to finish cleanup. Join external
producers and end all Runtime method calls before deinitializing. `stats` and `failure` are safe during
execution but cannot race with deinitialization or be used afterward. Runtime
statistics are an approximate concurrent snapshot, not an atomic global instant.

## Example

```sh
zig build runtime             # One owner per detected logical CPU.
zig build runtime -- 4        # Four owners.
zig build runtime-build      # Install the consumer executable.
```

The example submits one task per owner, routes timer completions, and shuts down
when they all finish. It prints distinct native thread IDs to demonstrate thread
assignment and lifecycle. See [development](development.md) for lifecycle tests
and the separate Runtime scaling benchmark.
