//! Independent compiler memory helpers: REP on x86_64, volatile byte loops elsewhere.

const builtin = @import("builtin");

// Windows commits stack pages lazily; compiler-generated probes must touch each guard.
fn probeStack() callconv(.naked) void {
    asm volatile (
        \\pushq %rcx
        \\pushq %rax
        \\leaq 24(%rsp), %rcx
        \\cmpq $4096, %rax
        \\jb 2f
        \\1:
        \\subq $4096, %rcx
        \\testq %rcx, (%rcx)
        \\subq $4096, %rax
        \\cmpq $4096, %rax
        \\jae 1b
        \\2:
        \\subq %rax, %rcx
        \\testq %rcx, (%rcx)
        \\popq %rax
        \\popq %rcx
        \\retq
    );
}

/// Called at comptime by standalone consumers that do not bundle compiler-rt.
pub fn install() void {
    @export(&memcpy, .{ .name = "memcpy" });
    @export(&memmove, .{ .name = "memmove" });
    @export(&memset, .{ .name = "memset" });
    if (builtin.os.tag == .windows and builtin.cpu.arch == .x86_64) {
        @export(&probeStack, .{ .name = "___chkstk_ms" });
        @export(&probeStack, .{ .name = "__chkstk" });
    }
}

pub fn memcpy(destination: [*]u8, source: [*]const u8, length: usize) callconv(.c) [*]u8 {
    if (builtin.cpu.arch == .x86_64) {
        var output = destination;
        var input = source;
        var count = length;
        asm volatile ("rep movsb"
            : [output] "={rdi}" (output),
              [input] "={rsi}" (input),
              [count] "={rcx}" (count),
            : [destination] "0" (destination),
              [source] "1" (source),
              [length] "2" (length),
            : .{ .memory = true });
        return destination;
    }
    // Volatile byte accesses prevent lowering this fallback back into a memcpy call.
    const output: [*]volatile u8 = destination;
    const input: [*]const volatile u8 = source;
    var index: usize = 0;
    while (index < length) : (index += 1) output[index] = input[index];
    return destination;
}

pub fn memset(destination: [*]u8, value: c_int, length: usize) callconv(.c) [*]u8 {
    if (builtin.cpu.arch == .x86_64) {
        var output = destination;
        var count = length;
        asm volatile ("rep stosb"
            : [output] "={rdi}" (output),
              [count] "={rcx}" (count),
            : [destination] "0" (destination),
              [length] "1" (length),
              [value] "{eax}" (value),
            : .{ .memory = true });
        return destination;
    }
    const output: [*]volatile u8 = destination;
    var index: usize = 0;
    while (index < length) : (index += 1) output[index] = @truncate(@as(u32, @bitCast(value)));
    return destination;
}

pub fn memmove(destination: [*]u8, source: [*]const u8, length: usize) callconv(.c) [*]u8 {
    if (length == 0) return destination;
    if (@intFromPtr(destination) <= @intFromPtr(source) or @intFromPtr(destination) - @intFromPtr(source) >= length) return memcpy(destination, source, length);
    if (builtin.cpu.arch == .x86_64) {
        var output = destination + length - 1;
        var input = source + length - 1;
        var count = length;
        // Copy overlapping ranges backward, then restore the ABI's clear direction flag.
        asm volatile (
            \\std
            \\rep movsb
            \\cld
            : [output] "={rdi}" (output),
              [input] "={rsi}" (input),
              [count] "={rcx}" (count),
            : [destination] "0" (output),
              [source] "1" (input),
              [length] "2" (length),
            : .{ .memory = true });
        return destination;
    }
    const output: [*]volatile u8 = destination;
    const input: [*]const volatile u8 = source;
    if (@intFromPtr(destination) <= @intFromPtr(source)) {
        var index: usize = 0;
        while (index < length) : (index += 1) output[index] = input[index];
    } else {
        var index = length;
        while (index != 0) {
            index -= 1;
            output[index] = input[index];
        }
    }
    return destination;
}
