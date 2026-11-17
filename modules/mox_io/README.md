# mox_io

The internal asynchronous I/O, runtime, filesystem, networking, memory, and
backend layer used by mox. The public module is imported as `mox_io` by the
mox build graph and is re-exported as `mox.io` for application code.

## Architecture

- `src/mox_io.zig` is the public API root.
- `src/backend` selects the platform event backend.
- `src/core`, `src/runtime`, and `src/io` implement operation ownership and
  completion flow.
- `src/fs` provides native, memory, and embedded filesystems.
- `build/embed.zig` and `tools/embed.zig` provide deterministic asset images.
- `tests` contains API, lifecycle, filesystem, backend, and integration
  contracts.

The implementation has no external package dependencies. Keep submitted
buffers valid until completion and use the reported ownership and lifecycle
contracts in `docs/api.md` and `docs/architecture.md` when extending it.

The root mox build exposes the IO verification through `zig build check` and
`zig build test`; the IO-specific examples and benchmarks remain available as
source under this directory for focused development.
