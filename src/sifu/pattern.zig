const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;

const Node = @import("node.zig").Node;

pub const Pattern = struct {
    root: []Node = &.{},
    height: usize = 0,

    pub fn isEmpty(self: Pattern) bool {
        return self.root.len == 0;
    }

    pub fn writeIndent(
        self: Pattern,
        writer: *Writer,
        optional_indent: ?usize,
    ) Writer.Error!void {
        const slice = self.root;
        if (slice.len == 0)
            return;
        try slice[0].writeSExp(writer, optional_indent);
        if (slice.len == 1) {
            return;
        } else for (slice[1 .. slice.len - 1]) |*node| {
            // Don't add space before list/newline nodes or comma keys
            if (node.* != .list and node.* != .newline and !node.isCommaKey())
                try writer.writeByte(' ');
            try node.writeSExp(writer, optional_indent);
        }
        // Don't add space before list/newline nodes or comma keys
        if (slice[slice.len - 1] != .list and slice[slice.len - 1] != .newline and !slice[slice.len - 1].isCommaKey())
            try writer.writeByte(' ');
        try slice[slice.len - 1]
            .writeSExp(writer, optional_indent);
    }

    pub fn write(
        self: Pattern,
        writer: *Writer,
    ) !void {
        return self.writeIndent(writer, 0);
    }

    pub fn toString(self: Pattern, allocator: Allocator) ![]const u8 {
        var buff: std.ArrayList(u8) = .empty;
        errdefer buff.deinit(allocator);
        var allocating_writer = Io.Writer.Allocating.fromArrayList(allocator, &buff);
        try self.write(&allocating_writer.writer);
        return allocating_writer.toOwnedSlice();
    }

    pub fn copy(self: Pattern, allocator: Allocator) !Pattern {
        const pattern_copy = try allocator.alloc(Node, self.root.len);
        for (self.root, pattern_copy) |node, *node_copy|
            node_copy.* = try node.copy(allocator);

        return Pattern{
            .root = pattern_copy,
            .height = self.height,
        };
    }

    pub fn clone(self: Pattern, allocator: Allocator) !*Pattern {
        const pattern_copy_ptr = try allocator.create(Pattern);
        pattern_copy_ptr.* = try self.copy(allocator);

        return pattern_copy_ptr;
    }

    /// Clears all memory and resets this Pattern's root to an empty pattern.
    pub fn deinit(pattern: *Pattern, allocator: Allocator) void {
        for (pattern.root) |*node| {
            @constCast(node).deinit(allocator);
        }
        allocator.free(pattern.root);
        pattern.* = .{};
    }

    pub fn destroy(self: *Pattern, allocator: Allocator) void {
        self.deinit(allocator);
        allocator.destroy(self);
    }

    /// A single evaluation step over one pattern level. A step transforms the
    /// nodes of the pattern it is given and returns a freshly-owned pattern; it
    /// must not recurse into nested sub-patterns nor adjust nesting heights —
    /// `evaluate` drives both of those.
    pub const Step = *const fn (Pattern, Allocator) Allocator.Error!Pattern;

    /// Evaluate `self` with `step`, bottom-up. Each nested sub-pattern is
    /// evaluated first (recursion), the per-level nesting heights are
    /// recomputed, and then `step` is applied once at this level. This is the
    /// shared driver for the pure-pattern evaluators (`string.step`,
    /// `comments.step`, `pure.step`); they only implement the one-level
    /// transformation and leave recursion and height tracking here.
    ///
    /// Caller owns the returned pattern and should free it with `deinit`.
    pub fn evaluate(self: Pattern, allocator: Allocator, step: Step) Allocator.Error!Pattern {
        var result = std.ArrayList(Node).empty;
        errdefer {
            for (result.items) |*node| node.deinit(allocator);
            result.deinit(allocator);
        }

        var max_height: usize = 0;
        for (self.root) |node| {
            switch (node) {
                // Infix keeps its operator out-of-band; recurse into operands.
                .infix => |inf| {
                    var rhs = try inf.rhs.evaluate(allocator, step);
                    rhs.height += 1;
                    max_height = @max(max_height, rhs.height);
                    try result.append(allocator, Node{ .infix = .{ .op = inf.op, .rhs = rhs } });
                },
                // Recurse into the nested pattern of the other compound nodes.
                inline .pattern, .match, .arrow, .list, .newline => |sub, tag| {
                    var evaluated = try sub.evaluate(allocator, step);
                    evaluated.height += 1;
                    max_height = @max(max_height, evaluated.height);
                    try result.append(allocator, @unionInit(Node, @tagName(tag), evaluated));
                },
                // Leaves (and tries, evaluated at their own construction) are
                // copied as-is; `step` decides what to do with them.
                else => {
                    const copied = try node.copy(allocator);
                    max_height = @max(max_height, copied.height());
                    try result.append(allocator, copied);
                },
            }
        }

        var recursed = Pattern{ .root = try result.toOwnedSlice(allocator), .height = max_height };
        defer recursed.deinit(allocator);
        return step(recursed, allocator);
    }

    pub fn eql(self: Pattern, other: Pattern) bool {
        return self.height == other.height and
            self.root.len == other.root.len and
            for (self.root, other.root) |pattern, other_pattern| {
                if (!pattern.eql(other_pattern))
                    break false;
            } else true;
    }
};

const testing = std.testing;

test "Pattern: equal to copy" {
    var root = [_]Node{
        .{ .key = "cherry" },
        .{ .key = "blossom" },
        .{ .key = "tree" },
    };
    const pattern = Pattern{ .root = &root };
    var copy = try pattern.copy(testing.allocator);
    defer copy.deinit(testing.allocator);
    try testing.expect(pattern.eql(copy));
    try testing.expect(copy.eql(pattern));
}

test "Pattern: equal to clone" {
    var list_root = [_]Node{.{ .key = "tree" }};
    var root = [_]Node{
        .{ .key = "cherry" },
        .{ .key = "blossom" },
        .{ .list = .{ .root = &list_root } },
    };
    const pattern = Pattern{ .root = &root };
    const clone = try pattern.clone(testing.allocator);
    defer clone.destroy(testing.allocator);
    try testing.expect(pattern.eql(clone.*));
    try testing.expect(clone.eql(pattern));
}

test "Pattern: toString" {
    var root = [_]Node{
        .{ .key = "Bb" },
        .{ .key = "Cc" },
    };
    const pattern = Pattern{ .root = &root };
    const str = try pattern.toString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("Bb Cc", str);
}

const ArenaAllocator = std.heap.ArenaAllocator;
const Parser = @import("../Parser.zig");

test "Pattern height: nested patterns" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try testing.expectEqual(@as(usize, 0), (try Parser.parse(alloc, "")).height);
    try testing.expectEqual(@as(usize, 0), (try Parser.parse(alloc, "A B")).height);
    try testing.expectEqual(@as(usize, 1), (try Parser.parse(alloc, "()")).height);
    try testing.expectEqual(@as(usize, 1), (try Parser.parse(alloc, ",")).height);
    try testing.expectEqual(@as(usize, 1), (try Parser.parse(alloc, "1,")).height);
    try testing.expectEqual(@as(usize, 1), (try Parser.parse(alloc, "1, 2")).height);
    try testing.expectEqual(@as(usize, 2), (try Parser.parse(alloc, "1, 2,")).height);
    try testing.expectEqual(@as(usize, 2), (try Parser.parse(alloc, "1,(2)")).height);
    try testing.expectEqual(@as(usize, 3), (try Parser.parse(alloc, "1,(2,3)")).height);
    try testing.expectEqual(@as(usize, 1), (try Parser.parse(alloc, "1 + 2")).height);
}
