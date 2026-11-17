//! Public I/O values and Loop configuration.

const values = @import("core/values.zig");

pub const Address = values.Address;
pub const FileOpenOptions = values.FileOpenOptions;
pub const FileInfo = values.FileInfo;
pub const none = values.none;
pub const invalid_native = values.invalid_native;
pub const Handle = values.Handle;
pub const OpId = values.OpId;
pub const invalid_handle = values.invalid_handle;
pub const ResourceKind = values.ResourceKind;
pub const Kind = values.Kind;
pub const Work = values.Work;
pub const Status = values.Status;
pub const Connection = values.Connection;
pub const SubmitOptions = values.SubmitOptions;
pub const Wait = values.Wait;
pub const CancelResult = values.CancelResult;
pub const CloseMode = values.CloseMode;
pub const Completion = values.Completion;

/// Fixed capacities are chosen at initialization and never grow implicitly.
pub const Options = struct {
    operations: u32 = 1024,
    resources: u32 = 256,
    events: u32 = 64,
    inbox: u32 = 256,
    file_threads: u32 = 2,
    /// When set, the executor owns worker memory and reserves this Loop's job records.
    file_executor: ?*@import("fs/executor.zig") = null,
    path_capacity: u32 = 4096,
    /// io_uring only: register resource descriptors; unsupported kernels fall back.
    uring_fixed_files: bool = false,
};
