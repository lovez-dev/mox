//! Linux io_uring kernel ABI records.

pub const Sqe = extern struct {
    opcode: u8 = 0,
    flags: u8 = 0,
    priority: u16 = 0,
    fd: i32 = -1,
    offset: u64 = 0,
    address: u64 = 0,
    length: u32 = 0,
    operation_flags: u32 = 0,
    user_data: u64 = 0,
    buffer_index: u16 = 0,
    personality: u16 = 0,
    splice_fd: i32 = 0,
    address3: u64 = 0,
    reserved: u64 = 0,
};

pub const Cqe = extern struct { user_data: u64, result: i32, flags: u32 };

pub const SqOffsets = extern struct { head: u32 = 0, tail: u32 = 0, mask: u32 = 0, entries: u32 = 0, flags: u32 = 0, dropped: u32 = 0, array: u32 = 0, reserved: u32 = 0, user_address: u64 = 0 };

pub const CqOffsets = extern struct { head: u32 = 0, tail: u32 = 0, mask: u32 = 0, entries: u32 = 0, overflow: u32 = 0, completions: u32 = 0, flags: u32 = 0, reserved: u32 = 0, user_address: u64 = 0 };

pub const Parameters = extern struct {
    sq_entries: u32 = 0,
    cq_entries: u32 = 0,
    flags: u32 = 0,
    cpu: u32 = 0,
    idle: u32 = 0,
    features: u32 = 0,
    worker_fd: u32 = 0,
    reserved: [3]u32 = @splat(0),
    sq: SqOffsets = .{},
    cq: CqOffsets = .{},
};

pub const ProbeOp = extern struct { opcode: u8 = 0, reserved: u8 = 0, flags: u16 = 0, reserved2: u32 = 0 };

pub const Probe = extern struct { last: u8 = 0, length: u8 = 0, reserved: u16 = 0, reserved2: [3]u32 = @splat(0), operations: [64]ProbeOp = @splat(.{}) };

pub const Timespec = extern struct { seconds: i64, nanoseconds: i64 };

pub const WaitArguments = extern struct { signal_mask: u64 = 0, signal_mask_size: u32 = 0, reserved: u32 = 0, timeout: u64 = 0 };

pub const FilesUpdate = extern struct { offset: u32, reserved: u32 = 0, descriptors: u64 };
pub const register_files: u32 = 2;
pub const register_files_update: u32 = 6;
pub const sqe_fixed_file: u8 = 1;

comptime {
    if (@sizeOf(Sqe) != 64 or @offsetOf(Sqe, "user_data") != 32 or
        @sizeOf(Cqe) != 16 or @sizeOf(SqOffsets) != 40 or @sizeOf(CqOffsets) != 40 or
        @sizeOf(Parameters) != 120 or @offsetOf(Parameters, "sq") != 40 or
        @offsetOf(Parameters, "cq") != 80 or @sizeOf(ProbeOp) != 8 or
        @sizeOf(Probe) != 528 or @sizeOf(Timespec) != 16 or @sizeOf(WaitArguments) != 24 or
        @sizeOf(FilesUpdate) != 16 or @offsetOf(FilesUpdate, "descriptors") != 8)
    {
        @compileError("io_uring ABI layout mismatch");
    }
}
