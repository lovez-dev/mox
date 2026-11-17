//! Statically resolved model paths and a small typed expression grammar.
const std = @import("std");
const syntax = @import("syntax.zig");
const runtime = @import("runtime.zig");

fn fieldType(comptime T: type, comptime path: []const u8) type {
    if (path.len == 0) return T;
    const dot = std.mem.indexOfScalar(u8, path, '.') orelse path.len;
    if (dot < path.len and dot + 1 == path.len) @compileError("field paths cannot end with a dot");
    const part = path[0..dot];
    syntax.name(part);
    if (@typeInfo(T) != .@"struct" or !@hasField(T, part)) @compileError("field '" ++ part ++ "' in " ++ @typeName(T) ++ ": missing field");
    return fieldType(@FieldType(T, part), if (dot == path.len) "" else path[dot + 1 ..]);
}
fn field(value: anytype, comptime path: []const u8) fieldType(@TypeOf(value), path) {
    if (path.len == 0) return value;
    const dot = comptime std.mem.indexOfScalar(u8, path, '.') orelse path.len;
    return field(@field(value, path[0..dot]), if (dot == path.len) "" else path[dot + 1 ..]);
}
pub fn Root(comptime T: type) type {
    return struct {
        value: T,
        pub fn Type(comptime path: []const u8) type {
            return fieldType(T, path);
        }
        pub fn get(self: @This(), comptime path: []const u8) @This().Type(path) {
            return field(self.value, path);
        }
    };
}
pub fn Bind(comptime Parent: type, comptime name: []const u8, comptime T: type) type {
    return struct {
        parent: Parent,
        value: T,
        fn matches(comptime path: []const u8) bool {
            return syntax.eq(path, name) or std.mem.startsWith(u8, path, name ++ ".");
        }
        fn suffix(comptime path: []const u8) []const u8 {
            return if (path.len == name.len) "" else path[name.len + 1 ..];
        }
        pub fn Type(comptime path: []const u8) type {
            return if (matches(path)) fieldType(T, suffix(path)) else Parent.Type(path);
        }
        pub fn get(self: @This(), comptime path: []const u8) @This().Type(path) {
            return if (comptime matches(path)) field(self.value, suffix(path)) else self.parent.get(path);
        }
    };
}
pub const LoopInfo = struct { index: usize, first: bool, last: bool };
pub fn Element(comptime T: type) type {
    if (runtime.isText(T)) @compileError("text is not a loop collection");
    return switch (@typeInfo(T)) {
        .array => |a| a.child,
        .pointer => |p| if (p.size == .slice) p.child else @compileError("loops require arrays or slices"),
        else => @compileError("loops require arrays or slices"),
    };
}
pub fn LoopEnv(comptime E: type, comptime name: []const u8, comptime T: type) type {
    return Bind(Bind(E, name, T), "loop", LoopInfo);
}

const Op = enum { value, invert, conjunction, disjunction, equal, unequal, less, greater, less_equal, greater_equal };
const Expression = struct { op: Op = .value, left: []const u8, right: []const u8 = "" };
fn comparison(op: Op) bool {
    return switch (op) {
        .equal, .unequal, .less, .greater, .less_equal, .greater_equal => true,
        else => false,
    };
}
fn parse(comptime raw: []const u8) Expression {
    const text = syntax.trim(raw);
    if (text.len == 0) @compileError("empty expression");
    const operators = .{ " or ", " and ", " == ", " != ", " <= ", " >= ", " < ", " > " };
    const ops = [_]Op{ .disjunction, .conjunction, .equal, .unequal, .less_equal, .greater_equal, .less, .greater };
    inline for (operators, ops) |operator, op| {
        if (std.mem.indexOf(u8, text, operator)) |at| return .{ .op = op, .left = syntax.trim(text[0..at]), .right = syntax.trim(text[at + operator.len ..]) };
    }
    if (std.mem.startsWith(u8, text, "not ")) return .{ .op = .invert, .left = syntax.trim(text[4..]) };
    return .{ .left = text };
}
pub fn Type(comptime E: type, comptime expression: []const u8) type {
    const expr = parse(expression);
    switch (expr.op) {
        .value => {
            if (syntax.eq(expr.left, "true") or syntax.eq(expr.left, "false")) return bool;
            if (std.fmt.parseInt(i64, expr.left, 10)) |_| return i64 else |_| {}
            return E.Type(expr.left);
        },
        .invert => {
            condition(Type(E, expr.left));
            return bool;
        },
        .conjunction, .disjunction => {
            condition(Type(E, expr.left));
            condition(Type(E, expr.right));
            return bool;
        },
        else => {
            if (comparison(parse(expr.left).op) or comparison(parse(expr.right).op)) @compileError("chained comparisons are unsupported");
            const A = Type(E, expr.left);
            const B = Type(E, expr.right);
            if (@typeInfo(A) == .int and @typeInfo(A).int.bits > 128) @compileError("comparison integers must be at most 128 bits");
            if (@typeInfo(B) == .int and @typeInfo(B).int.bits > 128) @compileError("comparison integers must be at most 128 bits");
            if (runtime.isText(A) and runtime.isText(B) and (expr.op == .equal or expr.op == .unequal)) return bool;
            if ((@typeInfo(A) == .int and @typeInfo(B) == .int) or (A == B and (A == bool or @typeInfo(A) == .float))) {
                if (A == bool and expr.op != .equal and expr.op != .unequal) @compileError("booleans only support equality comparisons");
                return bool;
            }
            @compileError("incompatible comparison operands");
        },
    }
}
pub fn condition(comptime T: type) void {
    if (T != bool and @typeInfo(T) != .optional) @compileError("conditions require a boolean or optional");
}
pub fn truth(value: anytype) bool {
    return if (@TypeOf(value) == bool) value else value != null;
}
pub fn narrowed(comptime E: type, comptime expression: []const u8) type {
    const T = Type(E, expression);
    condition(T);
    return if (@typeInfo(T) == .optional) Bind(E, syntax.trim(expression), @typeInfo(T).optional.child) else E;
}
pub fn eval(env: anytype, comptime expression: []const u8, budget: *runtime.Budget) !Type(@TypeOf(env), expression) {
    try budget.step();
    const expr = comptime parse(expression);
    switch (expr.op) {
        .value => {
            if (comptime syntax.eq(expr.left, "true")) return true;
            if (comptime syntax.eq(expr.left, "false")) return false;
            if (comptime std.fmt.parseInt(i64, expr.left, 10)) |n| return n else |_| {}
            return env.get(expr.left);
        },
        .invert => return !truth(try eval(env, expr.left, budget)),
        .conjunction => return truth(try eval(env, expr.left, budget)) and truth(try eval(env, expr.right, budget)),
        .disjunction => return truth(try eval(env, expr.left, budget)) or truth(try eval(env, expr.right, budget)),
        else => {
            const a = try eval(env, expr.left, budget);
            const b = try eval(env, expr.right, budget);
            if (@typeInfo(@TypeOf(a)) == .float) {
                if (!std.math.isFinite(a) or !std.math.isFinite(b)) return error.InvalidNumber;
            }
            if (comptime runtime.isText(@TypeOf(a))) {
                try budget.scan(a.len);
                try budget.scan(b.len);
                const left: []const u8 = if (@typeInfo(@TypeOf(a)) == .array) &a else a;
                const right: []const u8 = if (@typeInfo(@TypeOf(b)) == .array) &b else b;
                try runtime.validateText(left);
                try runtime.validateText(right);
                const equal = std.mem.eql(u8, left, right);
                return if (expr.op == .equal) equal else !equal;
            }
            // Widen integers to avoid mixed signedness and literal coercion traps.
            const A = if (@typeInfo(@TypeOf(a)) == .int) @as(i256, a) else a;
            const B = if (@typeInfo(@TypeOf(b)) == .int) @as(i256, b) else b;
            return switch (expr.op) {
                .equal => A == B,
                .unequal => A != B,
                .less => A < B,
                .greater => A > B,
                .less_equal => A <= B,
                .greater_equal => A >= B,
                else => unreachable,
            };
        },
    }
}
