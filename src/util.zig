const std = @import("std");
const math = std.math;
const Order = math.Order;
const meta = std.meta;
const mem = std.mem;
const Strategy = std.hash.Strategy;
const Wyhash = std.hash.Wyhash;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const no_os = @import("builtin").target.os.tag == .freestanding;
const wasm = @import("wasm.zig");
pub const streams = @import("streams.zig").streams;
pub const panic = std.debug.panic;
const detect_leaks = @import("build_options").detect_leaks;
pub const GPA = std.heap.GeneralPurposeAllocator(
    .{
        .safety = detect_leaks,
        // .never_unmap = detect_leaks,
        // .retain_metadata = detect_leaks,
        .enable_memory_limit = detect_leaks, // for tracking allocation amount
        .verbose_log = detect_leaks,
    },
);

/// Remove the tag from a union type.
pub fn toUntagged(comptime TaggedUnion: type) type {
    var info = @typeInfo(TaggedUnion);
    info.Union.tag_type = null;
    return @Type(info);
}

/// Shorthand for printing to stderr or null writer and panicking on errors.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    streams.err.print(fmt, args) catch panic(fmt, args);
}

pub fn popMany(
    unmanaged_list_ptr: anytype,
    index: usize,
    allocator: Allocator,
) !@typeInfo(@TypeOf(unmanaged_list_ptr)).Pointer.child {
    var result = try @typeInfo(@TypeOf(unmanaged_list_ptr)).Pointer.child
        .initCapacity(allocator, unmanaged_list_ptr.items.len - index);
    for (unmanaged_list_ptr.items[index..]) |pattern| {
        result.appendAssumeCapacity(pattern);
    }
    unmanaged_list_ptr.shrinkRetainingCapacity(index);
    return result;
}

pub fn popManyAsSlice(
    unmanaged_list_ptr: anytype,
    index: usize,
    allocator: Allocator,
) !@TypeOf(unmanaged_list_ptr.items) {
    var list = try popMany(unmanaged_list_ptr, index, allocator);
    return list.toOwnedSlice(allocator);
}

pub fn mapOption(option: anytype, function: anytype) @TypeOf(function(option)) {
    return if (option) |value|
        function(value)
    else
        null;
}

/// Get a reference to a nullable field in `struct_ptr`, creating one if it
/// doesn't already exist, initialized to default struct value.
pub fn getOrInit(
    comptime Field: anytype,
    struct_ptr: anytype,
    allocator: Allocator,
) !@typeInfo(@TypeOf(@field(struct_ptr, @tagName(Field)))).Optional.child {
    const field_option = @field(struct_ptr, @tagName(Field));
    const FieldPtrType = @typeInfo(@TypeOf(field_option)).Optional.child;
    const FieldType = @typeInfo(FieldPtrType).Pointer.child;
    const field = field_option orelse blk: {
        const new_field = try allocator.create(FieldType);
        new_field.* = FieldType{};
        break :blk new_field;
    };
    // @compileLog(FieldPtrType);
    // @compileLog(FieldType);
    @field(struct_ptr, @tagName(Field)) = field;
    return field;
}

pub fn hashFromHasherUpdate(
    comptime K: type,
) fn (K) u32 {
    return struct {
        fn hash(self: K) u32 {
            var hasher = Wyhash.init(0);
            self.hasherUpdate(&hasher);
            return @truncate(hasher.final());
        }
    }.hash;
}

pub fn hasherUpdateFromHash(
    comptime K: type,
    hash: fn (K) u32,
) fn (K, anytype) void {
    return struct {
        fn hasherUpdate(key: K, hasher: anytype) u32 {
            hasher.update(&mem.toBytes(hash(key)));
        }
    }.hasherUpdate;
}

pub fn genericWrite(val: anytype, writer: anytype) @TypeOf(writer).Error!void {
    return switch (@typeInfo(@TypeOf(val))) {
        .Struct, .Union => val.write(writer),
        .Pointer => |S| if (S.child == u8)
            writer.writeAll(val)
        else
            writer.print("{any}", .{val}),
        else => writer.print("{any}", .{val}),
    };
}

/// Convert a type with a hash and eql function with typical signatures to a
/// context compatible with std.array_hash_map.
pub fn IntoArrayContext(comptime Key: type) type {
    return struct {
        pub fn hash(self: @This(), key: Key) u32 {
            _ = self;
            return key.hash();
        }
        pub fn eql(
            self: @This(),
            key: Key,
            other: Key,
            b_index: usize,
        ) bool {
            _ = b_index;
            _ = self;
            return key.eql(other);
        }
    };
}

/// Convert a type with a hash and eql function with typical signatures to a
/// context compatible with std.hash_map.
pub fn IntoContext(comptime Key: type) type {
    return struct {
        pub fn hash(self: @This(), key: Key) u64 {
            _ = self;
            return key.hash();
        }
        pub fn eql(
            self: @This(),
            key: Key,
            other: Key,
        ) bool {
            _ = self;
            return key.eql(other);
        }
    };
}

/// Curry a function. Necessary in cases where a type is unknown until after its
/// parent's instantiation.
pub fn Curry(
    comptime Fn: fn (type, type) type,
    comptime Arg1: type,
) fn (type) type {
    return struct {
        pub fn Curried(comptime Arg2: type) type {
            return Fn(Arg1, Arg2);
        }
    }.Curried;
}

pub fn AutoSet(comptime T: type) type {
    return std.AutoHashMap(T, void);
}

// If this is just a const, the compiler complains about self-dependency in ast.zig
pub fn fsize() type {
    return switch (@typeInfo(usize).Int.bits) {
        8, 16 => f16,
        64 => f64,
        128 => f128,
        else => f32,
    };
}

const maxInt = std.math.maxInt;

pub fn first(slice: anytype) @TypeOf(slice[0]) {
    assert(slice.len > 0);
    return slice[0];
}

pub fn last(slice: anytype) @typeInfo(@TypeOf(slice)).Pointer.child {
    panic("this function appears to be broken", .{});
    // assert(slice.len > 0);
    // return slice[slice.len - 1];
}

/// Compare two slices whose elements can be compared by the `order` function.
/// Panics on slices of different length.
pub fn sliceOrder(
    lhs: anytype,
    rhs: anytype,
    op: fn (anytype, anytype) Order,
) Order {
    return for (lhs, rhs) |lhs_val, rhs_val|
        switch (op(lhs_val, rhs_val)) {
            .eq => continue,
            .lt => break .lt,
            .gt => break .gt,
        }
    else
        .eq;
}

pub fn sliceEql(
    lhs: anytype,
    rhs: @TypeOf(lhs),
    eq: fn (
        @typeInfo(@TypeOf(lhs)).Pointer.child,
        @typeInfo(@TypeOf(rhs)).Pointer.child,
    ) bool,
) bool {
    return lhs.len == rhs.len and for (lhs, rhs) |lhs_val, rhs_val| {
        if (!eq(lhs_val, rhs_val))
            break false;
    } else true;
}

/// Call a function with both values, if they are present, returning null if
/// not.
/// Like Haskell's liftM2 but with Zig's optional type as the monad.
pub fn liftOption(
    comptime R: type,
    maybe_lhs: anytype,
    maybe_rhs: anytype,
    op: fn (anytype, anytype) R,
) ?R {
    if (maybe_lhs) |lhs| if (maybe_rhs) |rhs|
        return op(lhs, rhs);

    return null;
}

const testing = std.testing;

test "expect f64" {
    try std.testing.expectEqual(switch (maxInt(usize)) {
        maxInt(u8), maxInt(u16) => f16,
        maxInt(u64) => f64,
        maxInt(u128) => f128,
        else => f32,
    }, fsize());
}

test "slices of different len" {
    const s1: []const usize = &.{ 1, 2, 3 };
    const s2: []const usize = &.{ 1, 2, 4 };
    try testing.expectEqual(Order.lt, sliceOrder(s1, s2, math.order));
    const s3: []const usize = &.{ 1, 2, 3 };
    const eq = struct {
        pub fn eq(a: usize, b: usize) bool {
            return a == b;
        }
    }.eq;
    try testing.expect(sliceEql(s1, s3, eq));
    try testing.expect(!sliceEql(s1, s2, eq));
}
