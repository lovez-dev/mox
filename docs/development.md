# Development

Use the toolchain version declared by the package and CI. Dependencies are pinned in `build.zig.zon`; update revisions and package hashes together.

## Build and test

```sh
zig build check
zig build test
zig build test-package
zig build example
```

`check` checks formatting and compiles the library, tests, examples, WebSocket fixture, and benchmarks. `test` executes protocol, template, task board, and server integration tests, including expected template compilation failures. `test-package` exercises a separate consuming build, embedded assets, and file-based templates. `example` installs the basic server; `run` starts it. `example-templates` installs the HTML template server. `example-board` builds the in-memory task board, and `run-board` starts it on loopback.

Choose a supported backend explicitly for integration tests:

```sh
zig build test -Dbackend=epoll
zig build test -Dbackend=uring
```

IOCP requires Windows, kqueue requires a supported BSD/macOS host, and epoll/io_uring require Linux. Compile checks for another target do not verify runtime behavior. Some sandboxes disable io_uring even on a recent Linux kernel. CI distinguishes host execution from cross compilation.

On Linux with Docker and Python 3, run the selected Autobahn WebSocket protocol cases:

```sh
sh tests/autobahn/run.sh
```

The runner uses a pinned x86_64 container image and a statically linked musl test server, avoiding a dependency on the container's older glibc. The fixture sets a 16 MiB WebSocket message limit and a 32 MiB output queue for the suite's large-message cases; normal server defaults remain 1 MiB and 4 MiB. Reports and logs are generated under `out/autobahn/` and removed on exit, including failure or interruption. CI runs this suite separately from the native integration tests.

Use `zig fmt` for formatting. Add regression coverage for parser boundaries, cancellation, partial transfers, connection shutdown, and callback cleanup when changing those paths. Use public server APIs for integration tests instead of depending on private transport layouts.

## Benchmarks

```sh
zig build bench -Doptimize=ReleaseFast
```

The benchmark uses [zlap](https://github.com/lovez-dev/zlap) for HTTP parsing, routing, and serialization workloads. Results are written under `out/bench/`; they describe those workloads rather than whole-server network throughput.

`zig build bench-templates -Doptimize=fast` compares equal-output HTML rendering with a checked handwritten baseline. It prints repeated timing and allocation measurements without saving a report. See [templates](templates.md#verification-and-measurement) for workload scope and differences in resource limits.

For end-to-end measurements, run an external HTTP client against the example or a representative application. Keep the host, backend, compiler options, payloads, connection count, warmup, and duration fixed between comparisons. Validate response bytes and failures, repeat runs, and report variability. Keep client CPU saturation and loopback behavior separate from server/backend cost.

## Artifacts and packaging

Temporary experiments, generated test files, logs, and benchmark reports belong in ignored `out/`. Tool caches and installation outputs retain their standard directories. Keep committed fixtures small and deterministic.

Package exports use a whitelist. Verify the downstream build after changing dependencies, public exports, or the embed helper. Synchronize usage and lifecycle documentation when public behavior changes. Long-term documentation belongs here; measured results and one-off investigation notes belong in `out/`.
