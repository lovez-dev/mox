# Public API and lifecycle

## Supported surface

The package is named mox-io; its module is `mox_io`. Import the public module
rather than paths into `src/`. Supported interfaces include Loop, Runtime, value
types, errors, statistics, allocators, Stream/Tcp/Udp, filesystems, Resolve, Dial,
Group, Pipe, process objects, and the build-time embed helper.

Documented configuration and result fields are supported. Internal Loop/backend
fields, native ABI declarations, `backend_common`, Queue, Layout, compiler helpers,
and custom-backend protocols are implementation or experimental interfaces.
Their export does not promise stability. Do not mutate pending object fields.

Within the 0.2.x series, patch updates preserve documented signatures, default
capacities, resource cleanup responsibilities, completion counts, and cancellation
behavior. Additions, fixes, and diagnostic counters are allowed. Minor versions
may add enum values; source breaks require a minor-version bump and migration
instructions. No C ABI, binary layout, or compiler-version compatibility is
promised. See [Runtime](runtime.md) for its additional lifecycle rules.

## Admission and identity

A successful operation submission returns an OpId and admits exactly one terminal
Completion. A synchronous library error admits none. Fixed capacities never grow
implicitly; `Capacity` is backpressure. Poll returns up to the output capacity,
can return zero on a wake or spurious readiness, and retains unconsumed results.

Handles and IDs belong to one Loop. Both index and generation must match. IDs
expire when their terminal result is consumed; stale IDs cannot affect reused
slots. Copying a handle does not create an independently managed resource.

Socket creation, bind/listen, adoption, address queries, options, and synchronous
open are setup calls on the Loop thread. Use asynchronous open during operation.
Adopted Windows files must support overlapped I/O. Accept/open reserve a resource
before submission: success returns `accepted`/`opened`, and failure releases the
reservation.

## Buffers and completion

Keep paths, task contexts, and buffers valid until terminal delivery. Do not free
them, change pending write data, or reuse pending read storage. Objects referenced
by native work or mutexes must stay at stable addresses. A native event means
native access has ended; consuming the public result recycles the operation slot.

Single transfers can succeed with short counts. Full-transfer helpers continue
after each native completion and accumulate progress. EOF, cancellation, and
failure preserve partial byte counts. A nonempty full transfer that succeeds
without progress reports `NoProgress`.

Empty stream/file buffers complete locally. Empty UDP payloads are real messages;
datagram truncation sets `truncated` and counts bytes actually copied.

Pass wrapper results to the matching `complete()` method before reading outputs,
reusing requests, or closing referenced objects. `Stream.complete()` advances
file cursors by partial progress even on EOF/cancellation; explicit-offset calls
have no shared cursor. `Group.ready` in any-mode does not retire losing members:
cancel and drain them. Dial can use several stage IDs and must keep receiving
results until ready, including failed-connection closes.

## Cancellation and deadlines

Cancel requests termination, not rollback. It is idempotent while pending; the
first reason wins. An already queued result stays unchanged and cancellation
returns `already_completed`. Late native outcomes preserve bytes while the
requested cancellation reason wins. io_uring waits for both primary and cancel
CQEs before reusing a context.

Deadlines are absolute monotonic nanoseconds. They request cancellation when due
without bounding completion latency. Running blocking syscalls, DNS, pipe I/O,
and process waits can outlive a deadline. A running spawn/open can still create a
resource that must be closed. Standalone timers use operation capacity but no
resource or native request; success is `ok` with `invalid_handle`.

## Close and shutdown

Close rejects new operations on that resource. Drain mode preserves accepted work;
cancel mode cancels dependent operations. Native close starts after those
operations finish using the resource, and its result follows their terminal
results. Close storage is reserved independently of operation occupancy.

Enabled IOCP/epoll/kqueue workers perform file close; io_uring uses a close SQE.
With workers disabled, IOCP/readiness backends close synchronously. A close failure
that retains the handle schedules another attempt after 1 ms. Each polling pass
processes a bounded retry batch; total attempts and shutdown time have no fixed
limit. Statistics expose attempts and the last error. Keep the resource and its backing storage until
release. Failed/canceled opens that returned a native handle retain their
operation until that hidden handle closes, then emit only the open result.

`stop()` rejects I/O while preserving control and result delivery. `shutdown()`
also seals posts and cancels resources, opens, and timers. It attempts every
resource despite close failures; accepted inbox tasks still execute. Shutdown
does not kill arbitrary callbacks or children, or close caller-managed directory
streams and pipe endpoints. Arrange peer closure, callback release, or child
termination when needed for progress.

Seal the inbox before joining producers. Keep the Loop alive through all `post()`
calls, including rejected ones. Drain accepted commands, native work, resources,
and queued results before deinitializing; `deinit()` reports `Busy` while they
remain. Shared executors must outlive attached Loops.

## Threads and persistence

Ordinary Loop calls and snapshots run on its thread; `post()` is the cross-thread
admission interface. Posted contexts remain valid until execution. Invalid
control commands increment `inbox.errors`. Runtime supplies its own thread-safe
admission and statistics APIs; see [Runtime](runtime.md).

Wait for preceding writes before `sync()`. Independent file submissions can
execute out of order; submission order is not a durability barrier.

## Memory statistics

Requested and provider-rounded backing differ from RSS. Occupancy includes slots
retaining queued results. Caller buffers, kernel resources, and system stacks
are excluded; io_uring mappings are reported separately. Shared executor backing
is counted by its tracker; a shared tracking provider can aggregate library blocks.

Keep tracking providers at stable addresses until their allocations are freed.
Unsynchronized trackers require external serialization; the shared tracker
serializes provider calls and snapshots. Allocation counters do not measure all
OS allocation activity.

## Platform boundaries

IOCP targets Windows, epoll/io_uring target Linux, and kqueue targets macOS/FreeBSD.
FreeBSD native execution remains unverified. Portable completion behavior does not
remove platform differences in permissions, socket reuse, and OS error codes.
Unsupported behavior reports `BackendUnavailable`.

Linux defaults to epoll; selecting io_uring does not silently fall back to epoll.
See [backends](backends.md) for probes, configuration, and native limitations, and
[development](development.md) for API and lifecycle checks.
