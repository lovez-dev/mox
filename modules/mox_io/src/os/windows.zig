//! Minimal declarations for documented Windows APIs.

const win_abi = @import("abi/windows.zig");

pub const Handle = win_abi.Handle;
pub const invalid_handle = win_abi.invalid_handle;
pub const Bool = win_abi.Bool;
pub const VirtualAlloc = win_abi.VirtualAlloc;
pub const VirtualFree = win_abi.VirtualFree;
pub const GetSystemInfo = win_abi.GetSystemInfo;
pub const GetStdHandle = win_abi.GetStdHandle;
pub const WriteFile = win_abi.WriteFile;
pub const ExitProcess = win_abi.ExitProcess;
pub const QueryPerformanceCounter = win_abi.QueryPerformanceCounter;
pub const QueryPerformanceFrequency = win_abi.QueryPerformanceFrequency;
pub const GetCurrentThreadId = win_abi.GetCurrentThreadId;
pub const GetLastError = win_abi.GetLastError;
pub const CloseHandle = win_abi.CloseHandle;
pub const Sleep = win_abi.Sleep;
pub const SystemInfo = win_abi.SystemInfo;

pub fn pageSize() usize {
    var info: SystemInfo = undefined;
    GetSystemInfo(&info);
    return info.page_size;
}

pub fn mapPages(length: usize) ?[]u8 {
    const pointer: [*]u8 = @ptrCast(VirtualAlloc(null, length, 0x3000, 4) orelse return null);
    return pointer[0..length];
}

pub fn unmapPages(bytes: []u8) void {
    if (VirtualFree(bytes.ptr, 0, 0x8000) == 0) @panic("VirtualFree failed");
}

pub fn writeStderr(bytes: []const u8) void {
    writeHandle(0xfffffff4, bytes);
}

pub fn writeStdout(bytes: []const u8) void {
    writeHandle(0xfffffff5, bytes);
}

fn writeHandle(stream: u32, bytes: []const u8) void {
    const handle = GetStdHandle(stream) orelse return;
    var offset: usize = 0;
    while (offset < bytes.len) {
        var count: u32 = 0;
        const length: u32 = @intCast(@min(bytes.len - offset, 0xffffffff));
        if (WriteFile(handle, bytes[offset..].ptr, length, &count, null) == 0 or count == 0) return;
        offset += count;
    }
}

pub fn exit(code: u8) noreturn {
    ExitProcess(code);
}

pub fn now() u64 {
    var counter: i64 = 0;
    var frequency: i64 = 0;
    if (QueryPerformanceCounter(&counter) == 0 or QueryPerformanceFrequency(&frequency) == 0) @panic("performance counter unavailable");
    const ticks: u64 = @intCast(counter);
    const hz: u64 = @intCast(frequency);
    return (ticks / hz) * 1_000_000_000 + (ticks % hz) * 1_000_000_000 / hz;
}

pub fn threadId() u64 {
    return GetCurrentThreadId();
}
