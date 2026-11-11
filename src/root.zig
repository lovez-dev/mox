//! mox —— 基于自有 `mox_io` 抽象构建的 Zig Web 框架。
//!
//! 公开 API 从不点名具体 I/O 后端。调用方传入
//! `mox_io.Io`；Linux 上是 io_uring，BSD 上是 kqueue，Windows 上是 IOCP，
//! 均由 `platform` 在编译期选定。新增后端 = 填一个 `VTable`，
//! 对这里完全不可见。

pub const types = @import("types.zig");
pub const server = @import("server.zig");
pub const router = @import("router.zig");
pub const middleware = @import("middleware.zig");

pub const serve = server.serve;
pub const serveWith = server.serveWith;
pub const MountHook = server.MountHook;
pub const Config = types.Config;
pub const Context = types.Context;
pub const Response = types.Response;
pub const Handler = types.Handler;

pub const Route = router.Route;
pub const Router = router.Router;
pub const Params = router.Params;

pub const compose = middleware.compose;
pub const Middleware = middleware.Middleware;
pub const cors = middleware.cors;
pub const CorsOptions = middleware.CorsOptions;
pub const logging = middleware.logging;
pub const requireHeader = middleware.requireHeader;
pub const Header = types.Header;
pub const ErrorHandler = types.ErrorHandler;
pub const group = types.group;
pub const routes = types.routes;

test {
    @import("std").testing.refAllDecls(@This());
}
