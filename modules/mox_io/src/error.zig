//! Shared errors returned by library operations and lifecycle checks.

pub const Error = error{
    OutOfMemory,
    InvalidAlignment,
    SizeOverflow,
    InvalidOptions,
    Capacity,
    StaleHandle,
    StaleOperation,
    Closing,
    DirectionBusy,
    InvalidResource,
    InvalidState,
    QueueFull,
    WrongThread,
    Busy,
    NativeFailure,
    BackendUnavailable,
    NoProgress,
};
