//! Minimal panic hooks for standalone programs; failures terminate without unwinding.

const os = @import("../os/root.zig");

pub fn call(message: []const u8, _: ?usize) noreturn {
    @branchHint(.cold);
    os.writeStderr("panic: ");
    os.writeStderr(message);
    os.writeStderr("\n");
    os.exit(255);
}

pub fn sentinelMismatch(expected: anytype, _: @TypeOf(expected)) noreturn {
    call("sentinel mismatch", null);
}

pub fn unwrapError(_: anyerror) noreturn {
    call("error unwrapped", null);
}

pub fn outOfBounds(_: usize, _: usize) noreturn {
    call("index out of bounds", null);
}

pub fn startGreaterThanEnd(_: usize, _: usize) noreturn {
    call("invalid slice bounds", null);
}

pub fn inactiveUnionField(active: anytype, _: @TypeOf(active)) noreturn {
    call("inactive union field", null);
}

pub fn sliceCastLenRemainder(_: usize) noreturn {
    call("invalid slice cast", null);
}

pub fn unexpectedErrorCode(_: anyerror) noreturn {
    call("unexpected error code", null);
}

pub fn reachedUnreachable() noreturn {
    call("reached unreachable", null);
}

pub fn unwrapNull() noreturn {
    call("unwrap null", null);
}

pub fn castToNull() noreturn {
    call("cast to null", null);
}

pub fn incorrectAlignment() noreturn {
    call("incorrect alignment", null);
}

pub fn invalidErrorCode() noreturn {
    call("invalid error code", null);
}

pub fn integerOutOfBounds() noreturn {
    call("integer out of bounds", null);
}

pub fn integerOverflow() noreturn {
    call("integer overflow", null);
}

pub fn shlOverflow() noreturn {
    call("shl overflow", null);
}

pub fn shrOverflow() noreturn {
    call("shr overflow", null);
}

pub fn divideByZero() noreturn {
    call("divide by zero", null);
}

pub fn exactDivisionRemainder() noreturn {
    call("exact division remainder", null);
}

pub fn integerPartOutOfBounds() noreturn {
    call("integer part out of bounds", null);
}

pub fn corruptSwitch() noreturn {
    call("corrupt switch", null);
}

pub fn shiftRhsTooBig() noreturn {
    call("shift rhs too big", null);
}

pub fn invalidEnumValue() noreturn {
    call("invalid enum value", null);
}

pub fn forLenMismatch() noreturn {
    call("for len mismatch", null);
}

pub fn copyLenMismatch() noreturn {
    call("copy len mismatch", null);
}

pub fn memcpyAlias() noreturn {
    call("memcpy alias", null);
}

pub fn noreturnReturned() noreturn {
    call("noreturn returned", null);
}

pub fn loadUninstantiableType() noreturn {
    call("load uninstantiable type", null);
}
