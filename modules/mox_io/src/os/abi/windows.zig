//! Authoritative Windows system ABI types and declarations.

pub const Handle = *anyopaque;
/// Native socket values are integer handles, distinct from Kernel32 pointers.
pub const Socket = usize;

pub const invalid_handle: Handle = @ptrFromInt(~@as(usize, 0));

pub const Bool = i32;

// System, file, process, and completion layouts use the native ABI.
pub const SystemInfo = extern struct {
    architecture: u16,
    reserved: u16,
    page_size: u32,
    minimum_address: ?*anyopaque,
    maximum_address: ?*anyopaque,
    active_processor_mask: usize,
    processor_count: u32,
    processor_type: u32,
    allocation_granularity: u32,
    processor_level: u16,
    processor_revision: u16,
};

pub const Overlapped = extern struct { internal: usize = 0, internal_high: usize = 0, offset: u32 = 0, offset_high: u32 = 0, event: ?Handle = null };

pub const Entry = extern struct { key: usize, overlapped: ?*Overlapped, internal: usize, bytes: u32 };

pub const WsaBuffer = extern struct { length: u32, pointer: [*]u8 };

pub const Guid = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };

pub const FileTime = extern struct { low: u32, high: u32 };

pub const HandleInfo = extern struct {
    attributes: u32,
    created: FileTime,
    accessed: FileTime,
    modified: FileTime,
    volume: u32,
    size_high: u32,
    size_low: u32,
    links: u32,
    index_high: u32,
    index_low: u32,
};

pub const StandardInfo = extern struct { allocated: i64, size: i64, links: u32, delete_pending: u8, directory: u8 };

pub const Startup = extern struct {
    size: u32,
    reserved: ?*anyopaque = null,
    desktop: ?*anyopaque = null,
    title: ?*anyopaque = null,
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    x_chars: u32 = 0,
    y_chars: u32 = 0,
    fill: u32 = 0,
    flags: u32 = 0,
    show: u16 = 0,
    reserved_size: u16 = 0,
    reserved_bytes: ?*anyopaque = null,
    input: ?Handle = null,
    output: ?Handle = null,
    err: ?Handle = null,
};

pub const StartupEx = extern struct { startup: Startup, attributes: ?*anyopaque = null };

pub const ProcessInfo = extern struct { process: Handle, thread: Handle, pid: u32, tid: u32 };

pub const FindData = extern struct {
    attributes: u32,
    created: u64 align(4),
    accessed: u64 align(4),
    modified: u64 align(4),
    size_high: u32,
    size_low: u32,
    reserved: [2]u32,
    name: [260]u16,
    alternate_name: [14]u16,
};

pub const AddrInfo = extern struct {
    flags: i32,
    family: i32,
    socket_type: i32,
    protocol: i32,
    length: usize,
    name: ?[*:0]u8,
    address: ?[*]const u8,
    next: ?*AddrInfo,
};

// IOCP and overlapped socket operations.
pub extern "kernel32" fn CreateIoCompletionPort(Handle, ?Handle, usize, u32) callconv(.winapi) ?Handle;
pub extern "kernel32" fn GetQueuedCompletionStatusEx(Handle, [*]Entry, u32, *u32, u32, Bool) callconv(.winapi) Bool;
pub extern "kernel32" fn PostQueuedCompletionStatus(Handle, u32, usize, ?*Overlapped) callconv(.winapi) Bool;
pub extern "kernel32" fn CancelIoEx(Handle, ?*Overlapped) callconv(.winapi) Bool;
pub extern "kernel32" fn ReadFile(Handle, [*]u8, u32, ?*u32, ?*Overlapped) callconv(.winapi) Bool;
pub extern "ntdll" fn RtlNtStatusToDosError(u32) callconv(.winapi) u32;
pub extern "ws2_32" fn WSAStartup(u16, *anyopaque) callconv(.winapi) i32;
pub extern "ws2_32" fn WSACleanup() callconv(.winapi) i32;
pub extern "ws2_32" fn WSAGetLastError() callconv(.winapi) i32;
pub extern "ws2_32" fn WSASocketW(i32, i32, i32, ?*anyopaque, u32, u32) callconv(.winapi) usize;
pub extern "ws2_32" fn closesocket(usize) callconv(.winapi) i32;
pub extern "ws2_32" fn bind(usize, *const anyopaque, i32) callconv(.winapi) i32;
pub extern "ws2_32" fn listen(usize, i32) callconv(.winapi) i32;
pub extern "ws2_32" fn getsockname(usize, *anyopaque, *i32) callconv(.winapi) i32;
pub extern "ws2_32" fn getpeername(usize, *anyopaque, *i32) callconv(.winapi) i32;
pub extern "ws2_32" fn setsockopt(usize, i32, i32, ?*const anyopaque, i32) callconv(.winapi) i32;
pub extern "ws2_32" fn WSAIoctl(usize, u32, *const anyopaque, u32, *anyopaque, u32, *u32, ?*Overlapped, ?*anyopaque) callconv(.winapi) i32;
pub extern "ws2_32" fn WSARecv(usize, *WsaBuffer, u32, ?*u32, *u32, *Overlapped, ?*anyopaque) callconv(.winapi) i32;
pub extern "ws2_32" fn WSASend(usize, *WsaBuffer, u32, ?*u32, u32, *Overlapped, ?*anyopaque) callconv(.winapi) i32;
pub extern "ws2_32" fn WSARecvFrom(usize, *WsaBuffer, u32, ?*u32, *u32, *anyopaque, *i32, *Overlapped, ?*anyopaque) callconv(.winapi) i32;
pub extern "ws2_32" fn WSASendTo(usize, *WsaBuffer, u32, ?*u32, u32, *const anyopaque, i32, *Overlapped, ?*anyopaque) callconv(.winapi) i32;

// Virtual memory, clocks, and process handles.
pub extern "kernel32" fn VirtualAlloc(?*anyopaque, usize, u32, u32) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn VirtualFree(*anyopaque, usize, u32) callconv(.winapi) Bool;
pub extern "kernel32" fn GetSystemInfo(*SystemInfo) callconv(.winapi) void;
pub extern "kernel32" fn GetStdHandle(u32) callconv(.winapi) ?Handle;
pub extern "kernel32" fn WriteFile(Handle, [*]const u8, u32, ?*u32, ?*Overlapped) callconv(.winapi) Bool;
pub extern "kernel32" fn ExitProcess(u32) callconv(.winapi) noreturn;
pub extern "kernel32" fn QueryPerformanceCounter(*i64) callconv(.winapi) Bool;
pub extern "kernel32" fn QueryPerformanceFrequency(*i64) callconv(.winapi) Bool;
pub extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;
pub extern "kernel32" fn GetLastError() callconv(.winapi) u32;
pub extern "kernel32" fn CloseHandle(Handle) callconv(.winapi) Bool;
pub extern "kernel32" fn Sleep(u32) callconv(.winapi) void;

// Files, pipes, and child processes.
pub extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?Handle) callconv(.winapi) Handle;
pub extern "kernel32" fn FlushFileBuffers(Handle) callconv(.winapi) Bool;
pub extern "kernel32" fn GetFileInformationByHandle(Handle, *HandleInfo) callconv(.winapi) Bool;
pub extern "kernel32" fn GetFileInformationByHandleEx(Handle, u32, *anyopaque, u32) callconv(.winapi) Bool;
pub extern "kernel32" fn CreatePipe(*Handle, *Handle, ?*anyopaque, u32) callconv(.winapi) Bool;
pub extern "kernel32" fn CreateProcessW(?[*:0]const u16, [*:0]u16, ?*anyopaque, ?*anyopaque, Bool, u32, ?*anyopaque, ?[*:0]const u16, *Startup, *ProcessInfo) callconv(.winapi) Bool;
pub extern "kernel32" fn GetCurrentProcess() callconv(.winapi) Handle;
pub extern "kernel32" fn DuplicateHandle(Handle, Handle, Handle, *Handle, u32, Bool, u32) callconv(.winapi) Bool;
pub extern "kernel32" fn InitializeProcThreadAttributeList(?*anyopaque, u32, u32, *usize) callconv(.winapi) Bool;
pub extern "kernel32" fn UpdateProcThreadAttribute(*anyopaque, u32, usize, *anyopaque, usize, ?*anyopaque, ?*usize) callconv(.winapi) Bool;
pub extern "kernel32" fn DeleteProcThreadAttributeList(*anyopaque) callconv(.winapi) void;
pub extern "kernel32" fn WaitForSingleObject(Handle, u32) callconv(.winapi) u32;
pub extern "kernel32" fn GetExitCodeProcess(Handle, *u32) callconv(.winapi) Bool;
pub extern "kernel32" fn TerminateProcess(Handle, u32) callconv(.winapi) Bool;

// Directory traversal and path conversion.
pub extern "kernel32" fn CreateDirectoryW([*:0]const u16, ?*anyopaque) callconv(.winapi) Bool;
pub extern "kernel32" fn DeleteFileW([*:0]const u16) callconv(.winapi) Bool;
pub extern "kernel32" fn RemoveDirectoryW([*:0]const u16) callconv(.winapi) Bool;
pub extern "kernel32" fn MoveFileExW([*:0]const u16, [*:0]const u16, u32) callconv(.winapi) Bool;
pub extern "kernel32" fn SetFileInformationByHandle(Handle, u32, *const anyopaque, u32) callconv(.winapi) Bool;
pub extern "kernel32" fn FindFirstFileW([*:0]const u16, *FindData) callconv(.winapi) Handle;
pub extern "kernel32" fn FindNextFileW(Handle, *FindData) callconv(.winapi) Bool;
pub extern "kernel32" fn FindClose(Handle) callconv(.winapi) Bool;
pub extern "kernel32" fn WideCharToMultiByte(u32, u32, [*]const u16, i32, [*]u8, i32, ?*const u8, ?*i32) callconv(.winapi) i32;
pub extern "ws2_32" fn getsockopt(usize, i32, i32, *anyopaque, *i32) callconv(.winapi) i32;
pub extern "ws2_32" fn shutdown(usize, i32) callconv(.winapi) i32;
pub extern "ws2_32" fn getaddrinfo([*:0]const u8, ?[*:0]const u8, *const AddrInfo, *?*AddrInfo) callconv(.winapi) i32;
pub extern "ws2_32" fn freeaddrinfo(*AddrInfo) callconv(.winapi) void;

// Threads and synchronization objects.
pub extern "kernel32" fn CreateThread(?*anyopaque, usize, *const fn (?*anyopaque) callconv(.winapi) u32, ?*anyopaque, u32, ?*u32) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn SwitchToThread() callconv(.winapi) i32;
pub extern "kernel32" fn InitializeSRWLock(*anyopaque) callconv(.winapi) void;
pub extern "kernel32" fn AcquireSRWLockExclusive(*anyopaque) callconv(.winapi) void;
pub extern "kernel32" fn ReleaseSRWLockExclusive(*anyopaque) callconv(.winapi) void;
pub extern "kernel32" fn InitializeConditionVariable(*anyopaque) callconv(.winapi) void;
pub extern "kernel32" fn SleepConditionVariableSRW(*anyopaque, *anyopaque, u32, u32) callconv(.winapi) i32;
pub extern "kernel32" fn WakeConditionVariable(*anyopaque) callconv(.winapi) void;
pub extern "kernel32" fn WakeAllConditionVariable(*anyopaque) callconv(.winapi) void;
pub extern "kernel32" fn GetActiveProcessorCount(u16) callconv(.winapi) u32;
pub extern "kernel32" fn GetActiveProcessorGroupCount() callconv(.winapi) u16;
pub extern "kernel32" fn GetProcessAffinityMask(*anyopaque, *usize, *usize) callconv(.winapi) i32;

// Guard the layouts shared by synchronous helpers and overlapped completions.
comptime {
    const wide = @sizeOf(usize) == 8;
    if (@sizeOf(Overlapped) != (if (wide) @as(usize, 32) else 20) or
        @offsetOf(Overlapped, "event") != (if (wide) @as(usize, 24) else 16) or
        @sizeOf(Entry) != (if (wide) @as(usize, 32) else 16) or
        @sizeOf(WsaBuffer) != (if (wide) @as(usize, 16) else 8) or
        @sizeOf(Guid) != 16 or @sizeOf(FileTime) != 8 or
        @sizeOf(HandleInfo) != 52 or @sizeOf(StandardInfo) != 24 or
        @sizeOf(Startup) != (if (wide) @as(usize, 104) else 68) or
        @sizeOf(StartupEx) != (if (wide) @as(usize, 112) else 72) or
        @sizeOf(ProcessInfo) != (if (wide) @as(usize, 24) else 16) or
        @sizeOf(FindData) != 592 or
        @sizeOf(AddrInfo) != (if (wide) @as(usize, 48) else 32))
    {
        @compileError("Windows ABI layout mismatch");
    }
}
