//! 平台后端选择：**编译期**决定用哪个后端实现。
//!
//! 纪律：本模块只做一件事 —— 按目标 OS 选后端。它**不导出任何类型**，
//! 只导出一个模块别名。这样想用平台原语的模块（`loop.zig` / `net.zig`）
//! 依赖的是这个薄模块，而不是门面 `mox_io.zig`，从而避免反向依赖。
//!
//! 平台对应：
//!
//! | OS | 后端 | 模型 |
//! |---|---|---|
//! | Linux | `backends/linux.zig`（默认 io_uring，失败回落 epoll） | 完成 / 就绪 |
//! | macOS / *BSD | `backends/kqueue.zig` | 就绪 |
//! | Windows | `backends/windows.zig`（IOCP） | 完成 |
//!
//! Linux 的运行时回落逻辑在 `backends/linux.zig` 里，不在这里。

const builtin = @import("builtin");

pub const platform = switch (builtin.os.tag) {
    .windows => @import("backends/windows.zig"),
    .linux => @import("backends/linux.zig"),
    .macos, .ios, .tvos, .watchos, .visionos, .freebsd => @import("backends/kqueue.zig"),
    else => @compileError("mox_io: no backend for this target yet"),
};
