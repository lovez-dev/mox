# Development

## Build and test

Use the toolchain version in `build.zig.zon` and CI. Build commands accept
`-Doptimize=debug`, `safe`, `fast`, or `small`; the default is `debug`. Debug and
safe retain runtime safety checks. Tests use the default runner and `std.testing`.

```sh
zig build check test stress -Doptimize=safe --summary all
zig build test-build --summary all
zig build examples
zig build test -Dtest-filter="shared allocation"
zig build check -Dtarget=aarch64-linux-gnu
```

The default build compiles the library API without running tests. `check` verifies
formatting and compiles test, stress, example, and benchmark roots as objects;
cross checks need no target SDK or linker. `test` runs the ordinary suite and
`stress` runs bounded traffic/cancellation scenarios after it. `test-build` runs
embed command and downstream consumer tests, including failed-output preservation
and cache invalidation for edited, added, removed, and generated inputs.

CI runs native Windows, Linux, and macOS tests and examples, including build tests
once per platform. It separately cross-compiles additional architectures/FreeBSD
and runs Linux x86_64 TSan. Cross-compilation establishes code-generation coverage,
not native runtime behavior. FreeBSD native execution remains unverified.

Tests use ephemeral loopback ports, fixtures under `out/`, or temporary directories
managed and cleaned by the test runner. Examples run with generated cache fixtures.
Do not run separate suites concurrently in one checkout: ordinary, stress, and
soak steps are ordered, but separate invocations can conflict. io_uring tests skip
when required features are unavailable; resource/probe errors fail. Symbolic-link
tests skip when the host denies link creation.

For public API changes, run `check test stress test-build` and the consumer
examples. Signature contracts cover Loop, Stream, and selected wrappers; they do
not establish a binary ABI guarantee. Add regressions for changed behavior and
use soak/TSan when changing concurrent lifecycle code.

## ThreadSanitizer

On native Linux x86_64:

```sh
zig build test stress -Dsanitize-thread=true --summary all
```

This instruments the test roots and a private library module using LLVM and
the compiler's TSan runtime. The exported module retains its ordinary settings.
TSan does not instrument handwritten assembly or kernel buffer accesses and does
not replace ASan, MSan, or C UBSan. Native safety checks remain useful separately.

## Timed lifecycle tests

```sh
zig build soak -Doptimize=safe -Dsoak-seconds=60
zig build soak -Doptimize=safe -Dsanitize-thread=true -Dsoak-seconds=60
zig build soak -Dtest-filter=soak -Dsoak-seconds=30
```

Duration is per scenario. Every iteration finishes, so wall time can exceed the
requested duration; zero seconds runs one iteration. Linux adds io_uring scenarios
when supported. Ordinary and bounded stress suites run first. Filtering applies
to the ordinary and soak roots, while bounded stress remains full. Use an
unfiltered run when validating a release.

Scenarios repeatedly initialize, exercise, and retire framed TCP services, child
pipelines, independent Runtime Loops, inbox producers, and sustained connections.
They check payloads, terminal results, allocation accounting, and shutdown. Bounded
stress additionally exercises cancellation races, partial reads, generation reuse,
and frequent connection replacement. Worker regressions occupy workers to verify
capacity rejection, timer progress, queued deadlines, and `Busy` cleanup.

On Linux/Windows, timed scenarios compare FD/handle counts after each lifecycle
with a warmed baseline. The Windows Runtime check excludes Event handles, which
socket providers may cache; other handle types and total peaks remain tracked.
These checks do not establish RSS stability or detect every OS allocation.

## Benchmark commands

```sh
zig build bench -Doptimize=fast
zig build bench-build -Doptimize=fast
zig build runtime-bench-build -Doptimize=fast
```

`bench` reruns the measurement and writes `out/bench/benchmark.csv`. The build-only
steps install `mox-io-bench` and `mox-io-runtime-bench` in `zig-out/bin/`, with
`.exe` on Windows. Save raw runs, environment details, logs, and comparisons under
`out/`; do not commit measurement results to documentation.

Record compiler version, target, CPU, kernel, optimization, power settings, and
virtualization. Run repeated measurements without competing workloads and compare
distributions. Results describe the measured environment and workload; remote
networks, storage, deadlines, and application handlers need representative tests.

## Loop throughput workload

One Loop sends a payload from each client to its connected peer and waits for both
terminal results. Each connection carries one payload per batch; TCP_NODELAY is
enabled at both ends. Payloads are 64, 4096, and 65536 bytes, with 1, 8, and 32
connections, 32 warmup batches, a 64-event batch, and disabled file workers.
Measured transfers range from 512 to 16384 depending on payload. The default
backend runs, plus io_uring when its probe succeeds.

Setup, buffer allocation, warmup, final data comparison, CSV formatting, and
teardown are excluded. Timing includes admission, submission, polling,
full-transfer continuation, and terminal status/count validation. Provider
allocation calls must remain unchanged during measurement, including benchmark
buffers. Loop backing statistics exclude those caller buffers.

| CSV field | Meaning |
| --- | --- |
| `backend`, `optimize` | Driver and optimization tag |
| `payload_bytes`, `connections`, `transfers` | Payload, concurrency, measured transfers |
| `duration_ns` | Elapsed monotonic time |
| `mib_per_second` | Received payload counted once, using 1048576 bytes per MiB |
| `mean_ns_per_transfer` | Elapsed time divided by payload transfers; not request latency |
| `steady_allocations` | Provider allocation calls during measurement; must be zero |
| `native_polls` | Backend polls, including calls without kernel waits |
| `native_submissions`, `native_completions` | Native request counters |
| `loop_requested_bytes`, `loop_reserved_bytes` | Logical and provider-rounded live backing |
| `kernel_mapped_bytes` | Live io_uring mappings |

Each payload transfer produces send and receive results. Measure request latency
percentiles with a separate request/reply workload.

## Runtime scaling workload

Run the installed Runtime benchmark with owner count, payload bytes, and rounds
per owner. Zero owners selects detected logical CPUs. For example:

```sh
zig-out/bin/mox-io-runtime-bench 4 4096 10000
```

On Windows use `zig-out/bin/mox-io-runtime-bench.exe`. Each owner holds one TCP
pair and drives full request/reply rounds inside a task, posting receive before
send. Owners warm up for 128 rounds and synchronize at a start barrier. Timing
ends at the slowest owner; setup and teardown are excluded. Payloads, completion
status/counts, distinct thread IDs, and zero steady Loop allocation are checked.

Total work grows with owner count: this is weak scaling, not fixed-work completion
time. Throughput counts request and response bytes. Speedup compares aggregate
rounds/s against a fresh one-owner run; efficiency divides speedup by owner count.
There is no CPU pinning, and the management thread yields while waiting, adding
scheduling pressure. The workload does not measure task-dispatch throughput,
shared listeners, or remote traffic.
