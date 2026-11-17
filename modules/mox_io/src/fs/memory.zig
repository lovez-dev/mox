//! Single-owner filesystem with fixed metadata pools and growable file contents.

const MemoryFs = @This();

const base = @import("../mem/allocator.zig");
const Tracking = @import("../mem/tracking.zig");
const Layout = @import("../mem/layout.zig").Layout;
const Arena = @import("../mem/arena.zig");
const path = @import("virtual_path.zig");
const t = @import("types.zig");

const none = ~@as(u32, 0);

pub const Error = base.Error || path.Error || error{
    InvalidOptions,
    InvalidState,
    Capacity,
    StaleHandle,
    StaleIterator,
    FileNotFound,
    PathAlreadyExists,
    NotDirectory,
    IsDirectory,
    DirectoryNotEmpty,
    AccessDenied,
    FileTooLarge,
    QuotaExceeded,
    BufferTooSmall,
    Busy,
};

pub const Options = struct {
    /// Includes the root and unlinked files retained by open handles.
    nodes: u32 = 256,
    open_files: u32 = 128,
    max_file_size: usize = ~@as(usize, 0),

    /// Logical data, including unlinked files. Allocator overhead is separate.
    max_data_bytes: usize = ~@as(usize, 0),
};

pub const Stats = struct {
    memory: Tracking.Stats,
    files: usize,
    directories: usize,
    open_files: usize,
    unlinked_files: usize,
    data_bytes: usize,
    capacity_bytes: usize,
};

const Node = struct {
    live: bool = false,
    linked: bool = false,
    kind: t.Kind = .file,
    path: []const u8 = "",
    path_allocation: ?base.Allocation = null,
    data: ?base.Allocation = null,
    size: usize = 0,
    parent: u32 = none,
    children: u32 = 0,
    references: u32 = 0,

    permissions: u16 = 0o600,
    next: u32 = none,
};

const Slot = struct {
    generation: u64 = 0,
    node: u32 = none,
    access: t.Access = .read,
    position: u64 = 0,
    next: u32 = none,
};

// Fixed metadata pools share one backing allocation.
tracking: Tracking,
options: Options,
allocation: ?base.Allocation = null,
nodes: []Node = &.{},
order: []u32 = &.{},
slots: []Slot = &.{},

count: usize = 0,
free_node: u32 = none,
free_slot: u32 = none,

files: usize = 0,
directories: usize = 0,
open_files: usize = 0,
unlinked_files: usize = 0,
data_bytes: usize = 0,
capacity_bytes: usize = 0,

// Structural edits invalidate iterators through this generation.
epoch: u64 = 0,
active: bool = false,

/// Keep this value at a stable address until deinit succeeds.
pub fn init(self: *MemoryFs, allocator: base.Allocator, options: Options) Error!void {
    self.* = .{ .tracking = .{ .parent = allocator }, .options = options };
    if (options.nodes == 0 or options.nodes == none or options.open_files == none) return error.InvalidOptions;
    var layout: Layout = .{};
    try layout.add(Node, options.nodes);
    try layout.add(u32, options.nodes);
    try layout.add(Slot, options.open_files);
    const block = try self.tracking.allocator().allocate(layout.size, @max(@alignOf(Node), @alignOf(Slot)));
    errdefer self.tracking.allocator().release(block);
    var arena: Arena = .{ .bytes = block.bytes };
    self.nodes = try arena.allocate(Node, options.nodes);
    self.order = try arena.allocate(u32, options.nodes);
    self.slots = try arena.allocate(Slot, options.open_files);
    for (self.nodes, 0..) |*node, index| node.* = .{ .next = if (index + 1 < self.nodes.len) @intCast(index + 1) else none };
    for (self.slots, 0..) |*slot, index| slot.* = .{ .next = if (index + 1 < self.slots.len) @intCast(index + 1) else none };
    self.nodes[0] = .{ .live = true, .linked = true, .kind = .directory, .permissions = 0o755 };
    self.order[0] = 0;
    self.count = 1;
    self.directories = 1;
    self.free_node = if (options.nodes > 1) 1 else none;
    self.free_slot = if (options.open_files > 0) 0 else none;
    self.allocation = block;
    self.active = true;
}

/// Open files must be closed first; a Busy result leaves the filesystem intact.
pub fn deinit(self: *MemoryFs) Error!void {
    if (self.open_files != 0) return error.Busy;
    if (!self.active) return;
    for (self.nodes, 0..) |node, index| if (node.live) self.releaseNode(@intCast(index));
    self.tracking.allocator().release(self.allocation.?);
    self.allocation = null;
    self.nodes = &.{};
    self.order = &.{};
    self.slots = &.{};
    self.count = 0;
    self.files = 0;
    self.directories = 0;
    self.active = false;
}

pub fn stats(self: *const MemoryFs) Stats {
    return .{
        .memory = self.tracking.stats(),
        .files = self.files,
        .directories = self.directories,
        .open_files = self.open_files,
        .unlinked_files = self.unlinked_files,
        .data_bytes = self.data_bytes,
        .capacity_bytes = self.capacity_bytes,
    };
}

pub fn open(self: *MemoryFs, name: []const u8, options: t.OpenOptions) Error!File {
    try self.ready();
    const key = try path.canonical(name);
    if ((options.creation == .truncate_existing or options.creation == .create_always) and options.access == .read) return error.InvalidOptions;
    const found = self.find(key);
    if (found != null and options.creation == .create_new) return error.PathAlreadyExists;
    if (found) |index| if (self.nodes[index].kind == .directory) return error.IsDirectory;
    if (found == null and (options.creation == .open_existing or options.creation == .truncate_existing)) return error.FileNotFound;
    // Reserve a handle before creating or truncating anything.
    const slot_index = try self.reserveSlot();
    errdefer self.releaseSlot(slot_index);
    const index = found orelse try self.createNode(key, .file, options.permissions);
    if (options.creation == .truncate_existing or options.creation == .create_always) self.setSize(&self.nodes[index], 0);
    const slot = &self.slots[slot_index];
    slot.node = index;
    slot.access = options.access;
    self.nodes[index].references += 1;
    self.open_files += 1;
    return .{ .fs = self, .index = slot_index, .generation = slot.generation };
}

pub fn readFile(self: *const MemoryFs, name: []const u8, output: []u8) Error![]u8 {
    try self.ready();
    const index = self.find(try path.canonical(name)) orelse return error.FileNotFound;
    const node = &self.nodes[index];
    if (node.kind == .directory) return error.IsDirectory;
    if (output.len < node.size) return error.BufferTooSmall;
    if (node.size != 0) @memcpy(output[0..node.size], node.data.?.bytes[0..node.size]);
    return output[0..node.size];
}

/// Allocation failure preserves an existing file and removes a newly created entry.
pub fn writeFile(self: *MemoryFs, name: []const u8, input: []const u8) Error!void {
    try self.ready();
    const key = try path.canonical(name);
    const found = self.find(key);
    const index = found orelse try self.createNode(key, .file, 0o600);
    errdefer if (found == null) self.unlinkNode(index);
    const node = &self.nodes[index];
    if (node.kind == .directory) return error.IsDirectory;
    try self.ensureData(node, input.len);
    if (input.len != 0) @memcpy(node.data.?.bytes[0..input.len], input);
    self.setSize(node, input.len);
}

pub fn stat(self: *const MemoryFs, name: []const u8) Error!t.Info {
    try self.ready();
    return info(&self.nodes[self.find(try path.canonical(name)) orelse return error.FileNotFound]);
}

pub fn makeDir(self: *MemoryFs, name: []const u8) Error!void {
    try self.ready();
    _ = try self.createNode(try path.canonical(name), .directory, 0o755);
}

/// Like recursive mkdir, successfully created parents survive a later failure.
pub fn makePath(self: *MemoryFs, name: []const u8) Error!void {
    try self.ready();
    const key = try path.canonical(name);
    for (0..key.len + 1) |end| {
        if (end == 0 or (end != key.len and key[end] != '/')) continue;
        const prefix = key[0..end];
        if (self.find(prefix)) |index| {
            if (self.nodes[index].kind != .directory) return error.NotDirectory;
        } else _ = try self.createNode(prefix, .directory, 0o755);
    }
}

pub fn deleteFile(self: *MemoryFs, name: []const u8) Error!void {
    try self.mutable();
    const index = self.find(try path.canonical(name)) orelse return error.FileNotFound;
    if (self.nodes[index].kind == .directory) return error.IsDirectory;
    self.unlinkNode(index);
}

pub fn removeDir(self: *MemoryFs, name: []const u8) Error!void {
    try self.mutable();
    const index = self.find(try path.canonical(name)) orelse return error.FileNotFound;
    const node = &self.nodes[index];
    if (node.kind != .directory) return error.NotDirectory;
    if (index == 0) return error.Busy;
    if (node.children != 0) return error.DirectoryNotEmpty;
    self.unlinkNode(index);
}

pub fn iterate(self: *MemoryFs, name: []const u8) Error!Iterator {
    try self.ready();
    const index = self.find(try path.canonical(name)) orelse return error.FileNotFound;
    if (self.nodes[index].kind != .directory) return error.NotDirectory;
    return .{ .fs = self, .parent = index, .epoch = self.epoch, .index = self.lowerBound(self.nodes[index].path) + 1 };
}

pub const Iterator = struct {
    fs: *MemoryFs,
    parent: u32,
    epoch: u64,
    index: usize,

    /// Entry names remain valid until the next directory mutation or deinit.
    pub fn next(self: *Iterator) Error!?t.DirectoryEntry {
        if (!self.fs.active or self.epoch != self.fs.epoch) return error.StaleIterator;
        const directory = self.fs.nodes[self.parent].path;
        while (self.index < self.fs.count) {
            const node = &self.fs.nodes[self.fs.order[self.index]];
            self.index += 1;
            switch (path.compareDirectory(node.path, directory)) {
                .less => continue,
                .greater => return null,
                .equal => {},
            }
            if (node.parent == self.parent) return .{ .name = path.basename(node.path), .kind = node.kind };
        }
        return null;
    }
};

/// Copies refer to the same handle; close invalidates every copy.
pub const File = struct {
    fs: *MemoryFs,
    index: u32,
    generation: u64,

    pub fn close(self: File) Error!void {
        const slot = try self.get();
        const node_index = slot.node;
        const node = &self.fs.nodes[node_index];
        node.references -= 1;
        self.fs.open_files -= 1;
        self.fs.releaseSlot(self.index);
        if (!node.linked and node.references == 0) self.fs.releaseNode(node_index);
    }

    pub fn stat(self: File) Error!t.Info {
        return info(&self.fs.nodes[(try self.get()).node]);
    }

    pub fn readAt(self: File, output: []u8, offset: u64) Error!usize {
        const slot = try self.get();
        if (slot.access == .write) return error.AccessDenied;
        const node = &self.fs.nodes[slot.node];
        if (offset >= node.size) return 0;
        const start: usize = @intCast(offset);
        const count = @min(output.len, node.size - start);
        @memcpy(output[0..count], node.data.?.bytes[start..][0..count]);
        return count;
    }

    pub fn writeAt(self: File, input: []const u8, offset: u64) Error!usize {
        const slot = try self.writable();
        if (input.len == 0) return 0;
        if (offset > ~@as(usize, 0)) return error.FileTooLarge;
        const start: usize = @intCast(offset);
        const end = @addWithOverflow(start, input.len);
        if (end[1] != 0) return error.FileTooLarge;
        const node = &self.fs.nodes[slot.node];
        const length = @max(node.size, end[0]);
        try self.fs.ensureData(node, length);
        if (start > node.size) @memset(node.data.?.bytes[node.size..start], 0);
        @memcpy(node.data.?.bytes[start..end[0]], input);
        self.fs.setSize(node, length);
        return input.len;
    }

    pub fn read(self: File, output: []u8) Error!usize {
        const slot = try self.get();
        const count = try self.readAt(output, slot.position);
        slot.position += count;
        return count;
    }

    pub fn write(self: File, input: []const u8) Error!usize {
        const slot = try self.get();
        const count = try self.writeAt(input, slot.position);
        slot.position += count;
        return count;
    }

    pub fn seek(self: File, offset: u64) Error!void {
        (try self.get()).position = offset;
    }

    pub fn truncate(self: File, length: u64) Error!void {
        const slot = try self.writable();
        if (length > ~@as(usize, 0)) return error.FileTooLarge;
        const size: usize = @intCast(length);
        const node = &self.fs.nodes[slot.node];
        try self.fs.ensureData(node, size);
        if (size > node.size) @memset(node.data.?.bytes[node.size..size], 0);
        self.fs.setSize(node, size);
    }

    /// Reserve data capacity without changing the file size or cursor.
    pub fn reserve(self: File, capacity: usize) Error!void {
        const slot = try self.writable();
        try self.fs.ensureData(&self.fs.nodes[slot.node], capacity);
    }

    fn get(self: File) Error!*Slot {
        if (!self.fs.active or self.index >= self.fs.slots.len) return error.StaleHandle;
        const slot = &self.fs.slots[self.index];
        if (slot.node == none or slot.generation != self.generation) return error.StaleHandle;
        return slot;
    }

    fn writable(self: File) Error!*Slot {
        const slot = try self.get();
        if (slot.access == .read) return error.AccessDenied;
        return slot;
    }
};

fn ready(self: *const MemoryFs) Error!void {
    if (!self.active) return error.InvalidState;
}

fn mutable(self: *const MemoryFs) Error!void {
    try self.ready();
    if (self.epoch == ~@as(u64, 0)) return error.Capacity;
}

fn lowerBound(self: *const MemoryFs, key: []const u8) usize {
    var low: usize = 0;
    var high = self.count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (path.compare(self.nodes[self.order[middle]].path, key) == .less) low = middle + 1 else high = middle;
    }
    return low;
}

fn find(self: *const MemoryFs, key: []const u8) ?u32 {
    const position = self.lowerBound(key);
    if (position == self.count) return null;
    const index = self.order[position];
    return if (path.compare(self.nodes[index].path, key) == .equal) index else null;
}

fn createNode(self: *MemoryFs, key: []const u8, kind: t.Kind, permissions: u16) Error!u32 {
    try self.mutable();
    const position = self.lowerBound(key);
    if (position < self.count and path.compare(self.nodes[self.order[position]].path, key) == .equal) return error.PathAlreadyExists;
    const parent = self.find(path.parent(key)) orelse return error.FileNotFound;
    if (self.nodes[parent].kind != .directory) return error.NotDirectory;
    if (self.free_node == none) return error.Capacity;
    const allocation = try self.tracking.allocator().allocate(key.len, 1);
    @memcpy(allocation.bytes[0..key.len], key);
    const index = self.free_node;
    self.free_node = self.nodes[index].next;
    self.nodes[index] = .{
        .live = true,
        .linked = true,
        .kind = kind,
        .path = allocation.bytes[0..key.len],
        .path_allocation = allocation,
        .parent = parent,
        .permissions = permissions,
    };
    var cursor = self.count;
    while (cursor > position) : (cursor -= 1) self.order[cursor] = self.order[cursor - 1];
    self.order[position] = index;
    self.count += 1;
    self.nodes[parent].children += 1;
    if (kind == .file) self.files += 1 else self.directories += 1;
    self.epoch += 1;
    return index;
}

fn unlinkNode(self: *MemoryFs, index: u32) void {
    const node = &self.nodes[index];
    const position = self.lowerBound(node.path);
    for (position..self.count - 1) |cursor| self.order[cursor] = self.order[cursor + 1];
    self.count -= 1;
    self.nodes[node.parent].children -= 1;
    node.linked = false;
    self.tracking.allocator().release(node.path_allocation.?);
    node.path_allocation = null;
    node.path = "";
    if (node.kind == .file) {
        self.files -= 1;
        self.unlinked_files += 1;
    } else self.directories -= 1;
    self.epoch +|= 1;
    if (node.references == 0) self.releaseNode(index);
}

fn releaseNode(self: *MemoryFs, index: u32) void {
    const node = &self.nodes[index];
    if (node.path_allocation) |block| self.tracking.allocator().release(block);
    if (node.data) |block| {
        self.capacity_bytes -= block.bytes.len;
        self.tracking.allocator().release(block);
    }
    self.data_bytes -= node.size;
    if (!node.linked and node.kind == .file) self.unlinked_files -= 1;
    node.* = .{ .next = self.free_node };
    self.free_node = index;
}

fn reserveSlot(self: *MemoryFs) Error!u32 {
    while (self.free_slot != none) {
        const index = self.free_slot;
        const slot = &self.slots[index];
        self.free_slot = slot.next;
        if (slot.generation == ~@as(u64, 0)) continue;
        slot.* = .{ .generation = slot.generation + 1 };
        return index;
    }
    return error.Capacity;
}

fn releaseSlot(self: *MemoryFs, index: u32) void {
    const slot = &self.slots[index];
    slot.node = none;
    slot.next = self.free_slot;
    self.free_slot = index;
}

fn ensureData(self: *MemoryFs, node: *Node, size: usize) Error!void {
    if (size > self.options.max_file_size) return error.FileTooLarge;
    if (size > node.size and size - node.size > self.options.max_data_bytes - self.data_bytes) return error.QuotaExceeded;
    const capacity = if (node.data) |block| block.bytes.len else 0;
    if (size <= capacity) return;
    const wanted = @min(self.options.max_file_size, @max(size, @max(@as(usize, 64), capacity +| capacity / 2)));
    const block = try self.tracking.allocator().allocate(wanted, 1);
    if (node.data) |old| {
        @memcpy(block.bytes[0..node.size], old.bytes[0..node.size]);
        self.tracking.allocator().release(old);
    }
    self.capacity_bytes = self.capacity_bytes - capacity + block.bytes.len;
    node.data = block;
}

fn setSize(self: *MemoryFs, node: *Node, size: usize) void {
    self.data_bytes = self.data_bytes - node.size + size;
    node.size = size;
}

fn info(node: *const Node) t.Info {
    return .{ .kind = node.kind, .size = node.size, .allocated_size = if (node.data) |block| block.bytes.len else 0, .permissions = node.permissions };
}
