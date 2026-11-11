//! 领域模型：框架各处共享的请求 / 响应 / 处理器 / 配置类型。
//!
//! 单独成文件是为了切断 `router`/`middleware` 对 `server` 的反向依赖：
//! 这里只依赖 `std` 与 `http.zig`，因此任何层都能安全 import，不产生环。

const std = @import("std");
const http = @import("http.zig");

/// 单次请求捕获到的路径参数。值是指向
/// 请求目标的切片，故仅在本次请求期间有效。
pub const Params = struct {
    items: [max]Item = undefined,
    len: usize = 0,

    pub const max = 8;
    pub const Item = struct { name: []const u8, value: []const u8 };

    pub fn get(self: *const Params, name: []const u8) ?[]const u8 {
        for (self.items[0..self.len]) |item| {
            if (std.mem.eql(u8, item.name, name)) return item.value;
        }
        return null;
    }

    /// 由路由器在匹配时写入捕获值。
    pub fn push(self: *Params, name: []const u8, value: []const u8) bool {
        if (self.len == max) return false;
        self.items[self.len] = .{ .name = name, .value = value };
        self.len += 1;
        return true;
    }
};

/// 处理器的返回值。`body` 是借用的，必须存活到
/// 响应写出完毕为止。
pub const Response = struct {
    status: std.http.Status = .ok,
    body: []const u8 = "",
    content_type: []const u8 = "text/plain; charset=utf-8",
    /// 设置后，文件内容在 `Work` 池线程读取并作为 body 发送，
    /// 此时忽略 `body`。路径会被复制，故该切片
    /// 无需活过处理器调用。
    file_path: []const u8 = "",
    /// `file_path` 由处理器堆分配时置位（由 mox 释放）。
    file_path_owned: bool = false,
};

/// 交给每个处理器与中间件的单次请求状态，仅在
/// 调用期间有效——调用结束后 `request` 与 `params` 即销毁。
pub const Context = struct {
    gpa: std.mem.Allocator,
    request: *const http.Request,
    /// 捕获到的路径参数，仅在本次请求期间有效。
    params: *const Params,

    pub fn param(self: *const Context, name: []const u8) ?[]const u8 {
        return self.params.get(name);
    }
};

pub const Handler = *const fn (*Context) anyerror!Response;

pub const Route = struct {
    method: std.http.Method,
    path: []const u8,
    handler: Handler,
};

pub const Config = struct {
    gpa: std.mem.Allocator,
    address: std.Io.net.IpAddress,
    routes: []const Route,

    /// 并发连接上限。达到上限后不再 `accept`，新连接在内核 listen backlog
    /// 里排队（形成天然背压），而不是无限制地吃内存 / fd。默认 1024。
    max_connections: usize = 1024,

    /// 空闲超时（毫秒）：一个已建立的连接在两次请求之间允许的最长静默时间。
    /// 超时即关闭，防止半开连接 / 慢速攻击长期占用资源。0 表示不设超时。
    /// 默认 60s。
    idle_timeout_ms: u32 = 60_000,

    /// `accept` 失败（典型是 EMFILE / ENFILE，fd 耗尽）后的退避毫秒数。
    /// **不能立即重试**：失败→立即重试会在错误持续期间把 CPU 打满。
    /// 默认 50ms。
    accept_backoff_ms: u32 = 50,

    /// 优雅停机的总预算（毫秒）。停机时先关掉在飞连接、再等它们的完成包
    /// 回来，超过这个时间仍未收尾就放弃等待直接返回。默认 5s。
    shutdown_timeout_ms: u32 = 5_000,
};
