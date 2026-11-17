//! kqueue uses the shared readiness engine and its own BSD/Darwin bindings.

pub const Driver = @import("readiness.zig").Driver(@import("native/kqueue.zig"));
