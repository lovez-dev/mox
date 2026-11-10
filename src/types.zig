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
};
