//! Bounded in-memory task storage shared by the demo and comparison adapters.
//! Replies use the caller's arena; snapshots detach all data before serialization.
const std = @import("std");
const mox = @import("mox");

pub const Endpoint = enum { home, script, stylesheet, health, list, detail, create, update, delete };
pub const Reply = struct {
    status: std.http.Status = .ok,
    content_type: []const u8 = "application/json; charset=utf-8",
    body: []const u8,
};
pub const Task = struct { id: u32, title: []const u8, done: bool };
const capacity = 64;
const title_capacity = 160;
const Stored = struct {
    id: u32 = 0,
    title: [title_capacity]u8 = undefined,
    len: usize = 0,
    done: bool = false,

    fn view(self: *const Stored) Task {
        return .{ .id = self.id, .title = self.title[0..self.len], .done = self.done };
    }
};
const Page = mox.Template(@embedFile("index.html"), struct { tasks: []const Task, total: usize });

pub const App = struct {
    items: [capacity]Stored = undefined,
    len: usize = 0,
    next_id: u32 = 1,
    locked: std.atomic.Value(bool) = .init(false),

    pub fn init() App {
        var self: App = .{};
        for (0..16) |index| {
            var title: [title_capacity]u8 = undefined;
            const text = std.fmt.bufPrint(&title, "Task {d:0>2}", .{index + 1}) catch unreachable;
            self.append(text, index % 3 == 0);
        }
        return self;
    }

    fn lock(self: *App) void {
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    fn unlock(self: *App) void {
        self.locked.store(false, .release);
    }

    fn append(self: *App, title: []const u8, done: bool) void {
        const item = &self.items[self.len];
        item.* = .{ .id = self.next_id, .len = title.len, .done = done };
        @memcpy(item.title[0..title.len], title);
        self.len += 1;
        self.next_id += 1;
    }

    fn indexOf(self: *const App, id: u32) ?usize {
        for (self.items[0..self.len], 0..) |item, index| if (item.id == id) return index;
        return null;
    }

    /// Calls may overlap. Inputs need only remain valid until this call returns.
    /// The caller keeps reply bytes alive through HTTP transmission.
    pub fn handle(self: *App, allocator: std.mem.Allocator, endpoint: Endpoint, raw_id: ?[]const u8, body: []const u8, content_type: ?[]const u8) !Reply {
        switch (endpoint) {
            .health => return .{ .body = "{\"status\":\"ok\"}" },
            .script => return .{ .body = @embedFile("board.js"), .content_type = "text/javascript; charset=utf-8" },
            .stylesheet => return .{ .body = @embedFile("board.css"), .content_type = "text/css; charset=utf-8" },
            .home, .list => {
                var snapshot: [capacity]Stored = undefined;
                self.lock();
                const count = self.len;
                @memcpy(snapshot[0..count], self.items[0..count]);
                self.unlock();
                var tasks: [capacity]Task = undefined;
                for (snapshot[0..count], 0..) |*item, index| tasks[index] = item.view();
                if (endpoint == .home) return .{
                    .body = try Page.renderAlloc(allocator, .{ .tasks = tasks[0..count], .total = count }, .{ .max_output_bytes = 64 * 1024 }),
                    .content_type = "text/html; charset=utf-8",
                };
                return json(allocator, .ok, .{ .tasks = tasks[0..count], .total = count });
            },
            else => {},
        }
        const id: u32 = if (endpoint != .create) blk: {
            const value = std.fmt.parseInt(u32, raw_id orelse "", 10) catch return failure(.bad_request, "Invalid task ID");
            if (value == 0) return failure(.bad_request, "Invalid task ID");
            break :blk value;
        } else 0;
        if (endpoint == .create or endpoint == .update) {
            const media_type = std.mem.trim(u8, std.mem.sliceTo(content_type orelse "", ';'), " \t");
            if (!std.ascii.eqlIgnoreCase(media_type, "application/json")) return failure(.unsupported_media_type, "Expected application/json");
            if (body.len > 2048) return failure(.payload_too_large, "Request body is too large");
        }
        switch (endpoint) {
            .create => {
                const Input = struct { title: []const u8 };
                const parsed = std.json.parseFromSlice(Input, allocator, body, .{}) catch |err| return parseFailure(err);
                defer parsed.deinit();
                const title = checkedTitle(parsed.value.title) orelse return failure(.bad_request, "Title must contain 1 to 160 UTF-8 bytes without controls");
                self.lock();
                if (self.len == capacity or self.next_id == std.math.maxInt(u32)) {
                    self.unlock();
                    return failure(.conflict, "Task capacity reached");
                }
                self.append(title, false);
                var snapshot = self.items[self.len - 1];
                self.unlock();
                return json(allocator, .created, snapshot.view());
            },
            .update => {
                const Input = struct { title: ?[]const u8 = null, done: ?bool = null };
                const parsed = std.json.parseFromSlice(Input, allocator, body, .{}) catch |err| return parseFailure(err);
                defer parsed.deinit();
                const input = parsed.value;
                if (input.title == null and input.done == null) return failure(.bad_request, "Supply title or done");
                const title = if (input.title) |value| checkedTitle(value) orelse return failure(.bad_request, "Invalid title") else null;
                self.lock();
                const index = self.indexOf(id) orelse {
                    self.unlock();
                    return failure(.not_found, "Task not found");
                };
                const item = &self.items[index];
                if (title) |text| {
                    @memcpy(item.title[0..text.len], text);
                    item.len = text.len;
                }
                if (input.done) |done| item.done = done;
                var snapshot = item.*;
                self.unlock();
                return json(allocator, .ok, snapshot.view());
            },
            .detail, .delete => {
                self.lock();
                const index = self.indexOf(id) orelse {
                    self.unlock();
                    return failure(.not_found, "Task not found");
                };
                var snapshot = self.items[index];
                if (endpoint == .delete) {
                    std.mem.copyForwards(Stored, self.items[index .. self.len - 1], self.items[index + 1 .. self.len]);
                    self.len -= 1;
                }
                self.unlock();
                if (endpoint == .delete) return .{ .status = .no_content, .body = "" };
                return json(allocator, .ok, snapshot.view());
            },
            else => unreachable,
        }
    }
};

fn checkedTitle(value: []const u8) ?[]const u8 {
    const text = std.mem.trim(u8, value, " \t\r\n");
    if (text.len == 0 or text.len > title_capacity or !std.unicode.utf8ValidateSlice(text)) return null;
    for (text) |byte| if (byte < 0x20 or byte == 0x7f) return null;
    return text;
}

fn json(allocator: std.mem.Allocator, status: std.http.Status, value: anytype) !Reply {
    return .{ .status = status, .body = try std.json.Stringify.valueAlloc(allocator, value, .{}) };
}

fn failure(status: std.http.Status, comptime message: []const u8) Reply {
    return .{ .status = status, .body = "{\"error\":\"" ++ message ++ "\"}" };
}

fn parseFailure(err: anyerror) error{OutOfMemory}!Reply {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return failure(.bad_request, "Invalid JSON object");
}

test "task lifecycle, detached snapshots, and bounded storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var app = App.init();
    const created = try app.handle(allocator, .create, null, "{\"title\":\"  New task  \"}", "application/json");
    try std.testing.expectEqual(.created, created.status);
    try std.testing.expectEqualStrings("{\"id\":17,\"title\":\"New task\",\"done\":false}", created.body);
    const updated = try app.handle(allocator, .update, "17", "{\"done\":true}", "application/json; charset=utf-8");
    try std.testing.expectEqualStrings("{\"id\":17,\"title\":\"New task\",\"done\":true}", updated.body);
    try std.testing.expectEqual(.no_content, (try app.handle(allocator, .delete, "17", "", null)).status);
    try std.testing.expectEqual(.not_found, (try app.handle(allocator, .detail, "17", "", null)).status);
    try std.testing.expect(std.mem.endsWith(u8, created.body, "false}"));
    for (0..48) |_| try std.testing.expectEqual(.created, (try app.handle(allocator, .create, null, "{\"title\":\"x\"}", "application/json")).status);
    try std.testing.expectEqual(.conflict, (try app.handle(allocator, .create, null, "{\"title\":\"x\"}", "application/json")).status);
}

test "invalid JSON, fields, identifiers, media types, and titles are rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var app = App.init();
    for ([_][]const u8{ "{}", "[]", "{", "{\"title\":1}", "{\"title\":\"\"}", "{\"title\":\"  \"}", "{\"title\":\"x\",\"extra\":1}", "{\"title\":\"a\\u0000b\"}" }) |body| {
        try std.testing.expectEqual(.bad_request, (try app.handle(allocator, .create, null, body, "application/json")).status);
    }
    for ([_][]const u8{ "0", "abc", "4294967296" }) |id| try std.testing.expectEqual(.bad_request, (try app.handle(allocator, .detail, id, "", null)).status);
    try std.testing.expectEqual(.unsupported_media_type, (try app.handle(allocator, .create, null, "{}", "text/plain")).status);
    try std.testing.expectEqual(.bad_request, (try app.handle(allocator, .update, "1", "{}", "application/json")).status);
    const too_large: [2049]u8 = @splat('x');
    try std.testing.expectEqual(.payload_too_large, (try app.handle(allocator, .create, null, &too_large, "application/json")).status);
    const long_title: [161]u8 = @splat('a');
    try std.testing.expect(checkedTitle(&long_title) == null);
    try std.testing.expect(checkedTitle("\xff") == null);
    try std.testing.expect(checkedTitle("a\nb") == null);
}

test "HTML escapes task titles and list serialization reflects current state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var app = App.init();
    _ = try app.handle(allocator, .update, "1", "{\"title\":\"<script>alert(1)</script>\"}", "application/json");
    const page = try app.handle(allocator, .home, null, "", null);
    try std.testing.expect(std.mem.indexOf(u8, page.body, "&lt;script&gt;alert(1)&lt;/script&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, page.body, "<script>alert(1)</script>") == null);
    const list = try app.handle(allocator, .list, null, "", null);
    try std.testing.expect(std.mem.endsWith(u8, list.body, "\"total\":16}"));
}

test "concurrent mutations publish complete snapshots and unique identifiers" {
    const Worker = struct {
        app: *App,
        failed: std.atomic.Value(bool) = .init(false),

        fn run(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            for (0..8) |_| {
                const created = self.app.handle(allocator, .create, null, "{\"title\":\"Concurrent task\"}", "application/json") catch {
                    self.failed.store(true, .release);
                    return;
                };
                const list = self.app.handle(allocator, .list, null, "", null) catch {
                    self.failed.store(true, .release);
                    return;
                };
                const parsed = std.json.parseFromSlice(std.json.Value, allocator, list.body, .{}) catch {
                    self.failed.store(true, .release);
                    return;
                };
                defer parsed.deinit();
                if (created.status != .created) self.failed.store(true, .release);
            }
        }
    };
    var app = App.init();
    var workers: [4]Worker = undefined;
    var threads: [4]mox.io.sync.Thread = undefined;
    var started: usize = 0;
    defer for (threads[0..started]) |*thread| thread.join();
    for (&workers, &threads) |*worker, *thread| {
        worker.* = .{ .app = &app };
        try thread.start(Worker.run, worker);
        started += 1;
    }
    for (&threads) |*thread| thread.join();
    started = 0;
    for (&workers) |*worker| try std.testing.expect(!worker.failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 48), app.len);
    var seen: [49]bool = @splat(false);
    for (app.items[0..app.len]) |item| {
        try std.testing.expect(item.id > 0 and item.id < seen.len);
        try std.testing.expect(!seen[item.id]);
        seen[item.id] = true;
    }
}
