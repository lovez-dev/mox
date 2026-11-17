//! Loop occupancy, allocation accounting and cumulative I/O counters.

const Memory = @import("mem/tracking.zig").Stats;
const Native = @import("backend/common.zig").NativeStats;

/// Live occupancy is exact; cumulative owner-side counters saturate on overflow.
pub const Stats = struct {
    memory: Memory,
    native: Native,
    inbox: @import("core/inbox.zig").Stats,

    active_operations: u32,
    operation_high_water: u32,
    active_resources: u32,
    resource_high_water: u32,
    completions_queued: usize,
    completion_high_water: usize,
    timers_active: u32,

    submissions: u64,
    completed: u64,
    canceled: u64,
    timed_out: u64,
    failed: u64,
    capacity_rejections: u64,

    bytes_read: u64,
    bytes_written: u64,

    close_failures: u64,
    close_retries: u64,
    closes_pending_retry: u32,
    last_close_error: i32,
};
