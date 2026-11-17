# Architecture

## Loop thread and memory layout

Each Loop runs on one thread with a compile-time backend. Submission validates identity, resource kind, connection state, direction exclusion, offset range, and capacity before admission.

The independent allocator module wraps an injected provider with tracking. An overflow-checked layout obtains one aligned backing allocation. A fixed arena partitions it into hot operation metadata, caller-managed requests, results, resource slots, deadlines, FIFOs, inbox cells, and native storage.

~~~text
build.zig              Library exports, tools and verification targets
build.zig.zon          Package identity and dependency manifest
build/                 Public embed build helper and input tracking
tools/                 Host-side resource image packer
src/
  mox_io.zig         Public module
  loop.zig             Admission, resource lifecycle, statistics
  types.zig            Public value aliases and typed Loop options
  error.zig            Library errors
  stats.zig            Owner-side snapshots
  mem/                 Allocator, tracking, pages, arena, layout
  core/                Operations, resources, timers, queues, inbox
    values.zig         Portable identities and completion values
    execution.zig      Request/Event execution contract
  backend/             Completion drivers, readiness engine, bounded workers
    native/            Request/Event adapters and epoll/kqueue poller state
  os/                  System primitives without backend dependencies
    abi/               Authoritative Windows, POSIX, Linux and io_uring ABI
    linux/             Linux file opening, eventfd wakeups and ring management
    bsd/               Darwin/FreeBSD file opening
    windows/           Windows file opening
    socket_address.zig Platform socket address codecs
  fs/                  Public facade, value types, executor and filesystems
  net/                 Addresses, TCP and UDP adapters
  io/                  Completion-oriented stream adapter
  process.zig          Owned children, selective stdio and worker-backed waits
  time/                Monotonic clock
  sync/                Native mutex, condition and thread wrappers
  runtime/             Multi-owner Runtime and CPU discovery
  bootstrap/           Optional entry points, panic and compiler helpers
  text/                Shared allocation-free UTF-8 scalar decoding
  fmt/                 Caller-buffer integer formatting
tests/
  contract/            Lifecycle and worker invariants
  integration/         Real backend I/O
  root.zig             Native test imports
  stress.zig           Bounded stress tests
  support/             Deterministic backend
  fs/                  Memory, image and packing contracts
  build.zig            Embed command and downstream build regressions
examples/              Runnable programs
bench/                 Repeatable measurements
docs/                  Usage, architecture, semantics and testing guides
~~~

Native declarations and layout types live in `os/abi/`. Platform primitives use
those declarations without importing completion scheduling types. Adapters in
`backend/native/` translate native results into Request/Event values; epoll and
kqueue share the readiness engine. io_uring uses independent Linux file helpers,
without depending on the epoll poller. OS and backend selection remain comptime.
Both Linux backends share eventfd signaling/draining and the synchronous
close-result adapter; their registration, rearming and retirement protocols remain
backend-specific. Linux syscall numbers and argument packing live in the ABI layer.

`core/values.zig` and `core/execution.zig` hold portable value and execution
contracts without importing the public configuration facade or executor.
`types.zig` reexports those values and contains the typed Options.file_executor
pointer. The executor imports the lower-level contracts to keep the dependency
graph acyclic. Public type identities are shared through aliases.

`fs/root.zig` exposes the filesystem API; `fs/types.zig` contains only portable
values. Native and virtual paths share UTF-8 decoding while retaining separate
validation policies. Socket drivers, listeners and DNS share the platform address
codec. Optional bootstrap helpers remain available through `mox_io.runtime`.

The completion FIFO holds operation capacity plus resource capacity. Each resource reserves its close result. Backend close requests and worker records also include resource capacity.

Operation and resource generations are separate. Neither wraps; exhausted slots retire permanently.

## Submission and retirement

~~~mermaid
flowchart LR
    Caller["Caller-owned buffers"] --> Admission["Loop admission"]
    Admission --> Pools["Fixed pools"]
    Pools --> Batch["Bounded submission batch"]
    Batch --> Native["Compile-time native backend"]
    Native --> Retirement["Native retirement"]
    Retirement --> Results["Reserved completion FIFO"]
    Results --> Caller
    Producers["Producer threads"] --> Inbox["Bounded MPSC inbox"]
    Inbox --> Admission
    Batch --> Workers["Optional file executor"]
    Workers --> Retirement
~~~

Requests and contexts stay pinned. An operation retains its slot through terminal result consumption. Full transfers advance slices and file offsets only after native retirement, then resubmit through the bounded queue.

Network endpoints permit one active operation per direction. Files use explicit offsets and support concurrency. The stream adapter serializes file cursor operations while keeping TCP read/write independent.

Per-resource links make close proportional to that resource's pending work. Completion unlinks in constant time. Indexed deadlines insert and remove in logarithmic time.

## Scheduling

A pump drains a bounded inbox batch, expires deadlines, retries due closes, submits a bounded batch, chooses the earliest wait deadline, and harvests native events.

Native batches are consumed before referenced resource slots can be recycled. The readiness FIFO has at most one node per resource; detach removes it before reuse. New requests always attempt their nonblocking syscall first.

Inbox cells use sequence numbers with release/acquire publication. Before waiting, the owner clears the wake flag and rechecks the head. The admission gate pins producers through native wake calls. Sealing preserves accepted commands while rejecting new ones.

IOCP bounds unconsumed wake packets. eventfd and EVFILT_USER coalesce natively. Worker completions wake on empty-to-nonempty transitions.

## File executors

Workers own fixed path scratch. A shared executor reserves each Loop's job span at attachment; accepted work cannot exhaust completion storage.

Queued cancellation skips the syscall. Running cancellation waits for return. Shared wake calls hold the client lock, preventing detachment from destroying their target.

File closes use resource reservations. A canceled open with a returned handle remains in retirement until its hidden handle closes.

## Performance

The hot path uses no growing allocation, global I/O lock, coroutine frame, or mandatory backend vtable. Payloads remain in caller-managed buffers. Native batches amortize kernel transitions.

Use `DefaultRuntime` to manage one Loop per owner thread, or manage application
threads explicitly. Runtime task admission uses bounded per-owner inboxes and
round-robin selection, while existing I/O stays on its original owner. Native
I/O completion handling has no shared global I/O lock. Runtime shutdown seals
producers, drains accepted tasks and native results, and destroys Loops on their
owners. See [Runtime](runtime.md) for configuration and lifetime rules.

Choose capacities from measured high-water marks. Share file workers across many
Loops; disable them for network-only Loops. Configure TCP_NODELAY when measuring
small-message latency.

Throughput depends on the kernel, CPU, buffers, and concurrency. Benchmark the intended target and workload.

Memory and embedded filesystems use direct synchronous operations. Their data lifetimes, allocation behavior and image layout are documented in [filesystems](filesystems.md).

Portable work uses existing bounded workers and operation slots. Native filesystem
commands, DNS, pipes and child waits are completion adapters over this path;
separately owned directory, pipe and child objects remain the caller's responsibility.
Operation groups observe completed IDs without consuming unrelated results.
See [operations](operations.md) for lifecycle and cancellation details.
