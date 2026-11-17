//! Shared backend capabilities, statistics and execution protocol aliases.

const t = @import("../types.zig");
const execution = @import("../core/execution.zig");

pub const Request = execution.Request;
pub const Event = execution.Event;

pub const Capabilities = struct {
    native_files: bool = false,
    file_workers: bool = false,
    registered_buffers: bool = false,
    multishot: bool = false,
    zero_copy: bool = false,
};

pub const NativeStats = struct {
    submissions: u64 = 0,
    completions: u64 = 0,
    polls: u64 = 0,
    wakeups: u64 = 0,
    worker_jobs: u64 = 0,
    workers: u32 = 0,
    cancellations: u64 = 0,
    native_cqes: u64 = 0,
    /// Active io_uring table capacity, retained file references and SQE usage.
    fixed_file_capacity: u32 = 0,
    registered_files: u32 = 0,
    fixed_file_submissions: u64 = 0,
    kernel_mapped_bytes: usize = 0,
    shared_executor: bool = false,
};

pub const CloseResult = struct { closed: bool = true, pending: bool = false, native_error: i32 = 0 };

pub const performWork = execution.performWork;

/// File closes need worker records even when every ordinary operation slot is occupied.
pub fn workerCapacity(options: t.Options) @import("../error.zig").Error!u32 {
    const count = @addWithOverflow(options.operations, options.resources);
    if (count[1] != 0) return error.InvalidOptions;
    return count[0];
}
