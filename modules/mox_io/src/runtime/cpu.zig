//! Logical CPU discovery with platform affinity and processor-group handling.

const posix_abi = @import("../os/abi/posix.zig");
const win_abi = @import("../os/abi/windows.zig");
const builtin = @import("builtin");
const Error = @import("../error.zig").Error;

const Win = win_abi;
const Posix = posix_abi;

/// Linux respects the calling thread's affinity; Windows counts processor groups.
pub fn count() Error!u32 {
    switch (builtin.os.tag) {
        .windows => {
            const active = Win.GetActiveProcessorCount(0xffff);
            if (active == 0) return error.NativeFailure;
            // A single affinity mask describes only one Windows processor group.
            if (Win.GetActiveProcessorGroupCount() == 1) {
                var process_mask: usize = 0;
                var system_mask: usize = 0;
                if (Win.GetProcessAffinityMask(Win.GetCurrentProcess(), &process_mask, &system_mask) != 0 and process_mask != 0)
                    return @intCast(@popCount(process_mask));
            }
            return active;
        },
        .linux => {
            // Fixed storage supports 8192 CPU IDs on the supported 64-bit targets.
            var mask: [128]usize = @splat(0);
            if (Posix.sched_getaffinity(0, @sizeOf(@TypeOf(mask)), &mask) != 0) return error.NativeFailure;
            var result: u32 = 0;
            for (mask) |word| result += @popCount(word);
            return if (result == 0) error.NativeFailure else result;
        },
        .macos, .freebsd => {
            var result: u32 = 0;
            var length: usize = @sizeOf(u32);
            const name = if (builtin.os.tag == .macos) "hw.logicalcpu" else "hw.ncpu";
            if (Posix.sysctlbyname(name, &result, &length, null, 0) != 0 or length != @sizeOf(u32) or result == 0)
                return error.NativeFailure;
            return result;
        },
        else => return error.BackendUnavailable,
    }
}
