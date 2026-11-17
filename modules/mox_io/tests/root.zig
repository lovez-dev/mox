//! Test entry point for contracts, filesystems and backend integration.

const mox_io = @import("mox_io");

comptime {
    _ = @import("contract/api.zig");
    _ = @import("contract/lifecycle.zig");
    _ = @import("contract/executor.zig");
    _ = @import("contract/concurrency.zig");
    _ = @import("contract/adapters.zig");
    _ = @import("contract/socket_address.zig");
    _ = @import("contract/memory.zig");
    _ = @import("fs/memory.zig");
    _ = @import("fs/embedded.zig");
    _ = @import("fs/pack.zig");
    _ = @import("fs/generated.zig");
    _ = @import("integration/native.zig").Suite(mox_io.DefaultBackend);
    _ = @import("integration/extensions.zig").Suite(mox_io.DefaultBackend);
    _ = @import("integration/application.zig").Suite(mox_io.DefaultBackend);
    _ = @import("integration/runtime.zig").Suite(mox_io.DefaultBackend);
    if (@import("builtin").os.tag == .linux) _ = @import("integration/uring_fixed_files.zig");
    if (@import("builtin").os.tag == .linux) _ = @import("integration/native.zig").Suite(mox_io.backends.Uring);
    if (@import("builtin").os.tag == .linux) _ = @import("integration/extensions.zig").Suite(mox_io.backends.Uring);
    if (@import("builtin").os.tag == .linux) _ = @import("integration/application.zig").Suite(mox_io.backends.Uring);
    if (@import("builtin").os.tag == .linux) _ = @import("integration/runtime.zig").Suite(mox_io.backends.Uring);
}
