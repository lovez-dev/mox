# Filesystem, networking, groups and processes

All asynchronous APIs return Loop operation IDs and use the terminal completion
protocol. Paths and hostnames are caller-managed, NUL-terminated UTF-8 slices. Request
objects, paths, argument lists and buffers must remain stable through terminal
delivery. All ordinary methods and `complete()` calls belong to the Loop owner.

## Blocking work

`loop.work(task, options)` submits a `types.Work` callback to the bounded file
executor. `loop.workOn(file, task, options)` additionally retains a file handle
through retirement and passes its native handle to the callback. Callback return
values appear in `Completion.bytes`; they are not added to network/file byte
counters. Optional `native_error` points at callback-owned native error storage.

These operations require `file_threads > 0` or a shared file executor. When no
executor is available, the admitted operation completes with `BackendUnavailable`.
They use the same pools, deadlines, statistics, cancellation and shutdown rules
as other operations. Queued cancellation skips work. Running callbacks cannot be
forcibly stopped: terminal delivery waits for the callback to return. Cancellation
does not undo filesystem changes, process creation or pipe transfers.

## Native filesystem

```zig
var request: mox_io.fs.Native.Request = .{
    .action = .{ .make_dir = .{ .path = "data" } },
};
const id = try request.submit(&loop, .{});
// Dispatch the matching Loop completion to request.complete(result).
```

Actions are `make_dir`, `delete_file`, `remove_dir`, `rename`, `set_size`,
`set_permissions`, `open_dir`, `read_dir` and `close_dir`. Resize and permissions
require `Request.handle`, a file from the same Loop; other actions reject it.
Await preceding writes before resizing or renaming when ordering matters.
POSIX permissions are supported; Windows reports `BackendUnavailable` for that
action rather than approximating POSIX modes. Rename replaces an existing file
where the OS supports it; cross-filesystem moves and Windows directory replacement
are not emulated. Directory removal is nonrecursive.

`Directory` owns a native enumeration handle. Open it with `open_dir`, repeatedly
submit `read_dir` with a caller name buffer, then submit `close_dir`. A successful
read sets `Request.entry`, or null at EOF. Dot entries are skipped. Unknown and
symbolic-link kinds are `other`. A short name buffer reports `Capacity` and permits
retrying that entry with a larger buffer. Feed every completion to the request
before reusing it or the directory. A canceled running open can still create a
directory handle: inspect and close it after retirement. Loop shutdown does not
automatically close separately owned directory streams.

## DNS and hostname connections

```zig
var addresses: [16]mox_io.types.Address = undefined;
var resolve: mox_io.net.Resolve = .{
    .hostname = "example.com", .port = 443, .output = &addresses,
};
_ = try resolve.submit(&loop, .{});
// After resolve.complete(result), inspect status, count and truncated.
```

Resolution uses system `getaddrinfo` on a worker, honors system host/resolver
configuration, deduplicates returned addresses, and supports optional IPv4/IPv6
filtering. Output capacity is explicit; `truncated` reports omitted addresses.
The system resolver may allocate internally; its allocations are outside the
library tracker. No resolver cache or Happy Eyeballs algorithm is provided.

`net.Dial(LoopType).init(&loop, hostname, port, addresses)` combines resolution
and sequential connection attempts. Call `start(options)`, then feed every Loop
result to `try dial.complete(result)`. When `ready()`, inspect `result`; on success
`takeHandle()` returns the TCP handle; the caller must close it. `cancel()`
retires the current stage and closes failed/canceled connections. Keep driving
the Loop until ready. DNS, connect and close stages have distinct operation IDs;
Dial is not a single group member. The absolute deadline is reused across stages.

`socketOption`/`getSocketOption` support keepalive, address reuse, port reuse and
send/receive buffer sizes. Port reuse reports `BackendUnavailable` on Windows;
Windows address reuse semantics differ from POSIX. Buffer sizes are OS-adjusted.
Use `openTcp`, configure options, then `listenOn` to set options before binding.
`shutdownSocket(handle, .write)` half-closes TCP while retaining the reverse
direction; `.read` and `.both` are also available. Shutdown does not close the
handle. Typed Tcp/Udp adapters expose option methods too.

## Operation groups

```zig
var entries: [8]mox_io.GroupEntry = undefined;
var group = mox_io.Group(LoopType).init(&loop, &entries, .all);
try group.add(id);
group.seal();
// Feed consumed results to group.complete(result), or use group.poll().
```

`.all` becomes ready after every member completes. `.any` becomes ready after
the first terminal result, including failure or cancellation; `winner` identifies
that entry. `cancelRemaining()` requests cancellation for outstanding members.
Race losers still require completion dispatch before releasing their buffers or
resetting the group. An empty sealed all-group is ready; an empty any-group is not.
The caller remains responsible for completing and cleaning up member operations.
Groups never discard unrelated completions. IDs must come from the group's Loop; IDs do not encode Loop identity.
Seal before dispatching results and feed each consumed result to all relevant
groups. `reset(mode)` requires all member results to have been observed.

## Pipes and child processes

`Pipe.init()` creates noninheritable anonymous endpoints. `Pipe.Transfer` uses
one endpoint for a single worker read or write; keep it open until completion. Transfers can be
short. Read EOF is `Transfer.eof` with an `.ok` completion and zero bytes. Empty
buffers complete without a syscall. Feed results to `Transfer.complete()` before
reusing or closing the endpoint. Broken writes report failure without changing
the process-wide SIGPIPE policy.

Pipe transfers currently use blocking workers on every backend. A blocked read,
write or child wait occupies a worker; provision enough workers for cooperating
operations or separate their executors. In particular, queuing a read and then a
write to the same pipe with one worker can deadlock. A running blocked transfer
cannot be canceled immediately. The peer must make progress or close its end.

`process.Child.spawn(options)` is a synchronous setup call. `process.Spawn` moves
creation to a worker. Options take an argv list, optional working directory and
optional pipe ends for stdin/stdout/stderr. The environment is inherited. POSIX
uses `posix_spawnp`; Windows constructs a quoted command line for CRT parsing.
Programs with their own command parsing, including cmd.exe, can use the explicit
`windows_command_line` option; this is passed as provided and is not shell-escaped.
No shell is inserted by the library.

POSIX pipe descriptors are close-on-exec. macOS pipe setup is serialized against
library process creation; unrelated application spawn code must coordinate its
own descriptor inheritance. Existing externally inheritable POSIX descriptors
remain the application's responsibility. Windows duplicates selected standard
handles and restricts inheritance with a process attribute handle list.

After creation, close the parent's copies of child-side pipe ends so EOF can
arrive. Keep those ends open until async `Spawn.complete()`; a canceled running
spawn can still return a child that the caller must wait for and clean up.

`child.wait(&loop, options)` runs a bounded-polling wait callback on a worker and
records `termination` as an exit code or POSIX signal. Feed its completion to
`child.complete()`. `kill()` explicitly terminates the direct child; it does not
kill a process tree. Canceling a wait does not terminate a child and can delay
terminal delivery until child exit. Call kill when that behavior is needed, then
keep driving the Loop. If queued cancellation skipped the wait, submit another
wait to reap the child. `deinit()` requires a reaped child and no outstanding
completion. Child mutexes and referenced objects must not move while active.

Loop shutdown cancels admitted work but does not implicitly terminate external
children or close caller-managed pipe/directory objects. Coordinate their
shutdown before deinitializing the Loop. These modules implement no signal
watcher, arbitrary Unix socket API or coroutine runtime.
