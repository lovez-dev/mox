# mox

HTTP/1.1 routing, middleware, streaming, WebSocket, SSE, static files, and an integrated asynchronous I/O runtime.

## Installation

Add mox to your project:

```sh
zig fetch --save=mox git+https://github.com/lovez-dev/mox.git#main
```

In `build.zig`, attach the module to your executable:

```zig
const dep = b.dependency("mox", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("mox", dep.module("mox"));
```

## Usage

```zig
const std = @import("std");
const mox = @import("mox");

fn hello(_: *mox.Context) !mox.Response {
    return .{ .body = "hello\n" };
}

pub fn main() !void {
    try mox.serve(.{
        .gpa = std.heap.page_allocator,
        .address = mox.io.types.Address.loopback(8080),
        .routes = &.{.{ .method = .GET, .path = "/", .handler = hello }},
    });
}
```

For handlers that perform blocking work, enable `Config.blocking_handlers` and set `max_inflight_requests` to bound admitted work. WebSocket message callbacks can opt into workers with `Response.upgradeBlocking`.

Run the included example with `zig build run`. The integrated `mox_io` module is available as `mox.io`, `mox.mox_io`, and `dep.module("mox_io")`; see [usage](docs/usage.md) for embedding assets, templates, and shutdown, and [API contracts](docs/api.md) for memory and callback lifetimes.

## Testing

```sh
zig build check
zig build test
zig build test-package
zig build bench -Doptimize=ReleaseFast
```

Benchmark output goes to `out/bench/`. See [development](docs/development.md) for backend selection and verification.

## License

[MIT](LICENSE).
