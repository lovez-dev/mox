//! Separate HTTP codec and route lookup costs; server I/O is not measured here.

const std = @import("std");
const mox = @import("mox");
const zlap = @import("zlap");

var router: mox.Router = undefined;

pub fn main(init: std.process.Init) !void {
    // Route construction is startup work and stays outside the measured batches.
    router = try mox.Router.init(init.gpa, &.{
        .{ .method = .GET, .path = "/", .handler = handler },
        .{ .method = .GET, .path = "/users/:id", .handler = handler },
        .{ .method = .GET, .path = "/assets/*path", .handler = handler },
    });
    defer router.deinit();
    const config: zlap.Config = .{
        .batch_size = 2000,
        .sample_count = 20,
        .rounds = 3,
        .min_sample_ns = 5_000_000,
        .allocator = init.gpa,
        .count_allocations = true,
    };
    const parse_result = try zlap.runConfigured(init.io, config, parse);
    parse_result.print("HTTP request parsing");
    const route_result = try zlap.runConfigured(init.io, config, route);
    route_result.print("Route matching");
    const serialize_result = try zlap.runConfigured(init.io, config, serialize);
    serialize_result.print("HTTP response serialization");
}

fn handler(_: *mox.Context) !mox.Response {
    return .{ .body = "ok" };
}

fn parse(_: std.mem.Allocator, operations: usize) !void {
    var input: []const u8 = "GET /users/42?view=full HTTP/1.1\r\nHost: localhost\r\nAccept: application/json\r\nConnection: keep-alive\r\n\r\n";
    for (0..operations) |_| {
        std.mem.doNotOptimizeAway(&input);
        const result = mox.http.parse(input);
        if (result != .request) return error.InvalidRequest;
        std.mem.doNotOptimizeAway(result.request);
    }
}

fn route(_: std.mem.Allocator, operations: usize) !void {
    var path: []const u8 = "/users/42";
    for (0..operations) |_| {
        std.mem.doNotOptimizeAway(&path);
        var params: mox.Params = .{};
        const matched = router.match(.GET, path, &params) orelse return error.RouteNotFound;
        std.mem.doNotOptimizeAway(matched);
        std.mem.doNotOptimizeAway(params);
    }
}

fn serialize(_: std.mem.Allocator, operations: usize) !void {
    var storage: [1024]u8 = undefined;
    for (0..operations) |_| {
        const output = try mox.http.serialize(.{ .body = "{\"ok\":true}", .content_type = "application/json" }, true, false, &storage);
        std.mem.doNotOptimizeAway(output);
        std.mem.doNotOptimizeAway(&storage);
    }
}
