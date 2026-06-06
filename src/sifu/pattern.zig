const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const debug = std.log.debug;

const Node = @import("node.zig").Node;
const core = @import("../interpreter/core.zig");

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

    pub fn eql(self: Pattern, other: Pattern) bool {
        return self.height == other.height and
            self.root.len == other.root.len and
            for (self.root, other.root) |pattern, other_pattern| {
                if (!pattern.eql(other_pattern))
                    break false;
            } else true;
    }

    /// Evaluate match operators (`:`) without requiring a trie context.
    /// The `:` operator is right-associative, so `A : {B}` parses as [A, match({B})].
    /// LHS is prefix before the match node, RHS is inside the match node.
    /// Returns empty pattern when match fails.
    /// Always returns a pattern. Caller owns the returned pattern and should free with deinit.
    pub fn evaluatePure(self: Pattern, allocator: Allocator) Allocator.Error!Pattern {
        // Find the last .match node (`:` is right-associative so it's always last if present)
        if (self.root.len > 0 and self.root[self.root.len - 1] == .match) {
            const match_idx = self.root.len - 1;
            const match_pattern = self.root[match_idx].match;

            if (match_idx == 0) {
                // No LHS, just copy the pattern
                return self.copy(allocator);
            }

            // LHS is the prefix before the match node
            var lhs_height: usize = 0;
            for (self.root[0..match_idx]) |n| lhs_height = @max(lhs_height, n.height());
            const lhs = Pattern{ .root = self.root[0..match_idx], .height = lhs_height };

            // Try to match LHS with RHS
            if (try evaluateMatchOp(allocator, lhs, match_pattern)) |matched| {
                return matched;
            } else {
                // No match - return empty pattern to signal failure
                return Pattern{ .root = &.{}, .height = 0 };
            }
        }

        // No match operator at top level - recurse into nested patterns
        var result_nodes = std.ArrayList(Node).empty;
        errdefer result_nodes.deinit(allocator);

        for (self.root) |node| {
            switch (node) {
                inline .pattern, .arrow, .list, .infix, .newline => |sub_pattern, tag| {
                    const evaluated = try sub_pattern.evaluatePure(allocator);
                    var new_pattern = evaluated;
                    new_pattern.height += 1;
                    try result_nodes.append(allocator, @unionInit(Node, @tagName(tag), new_pattern));
                },
                else => {
                    try result_nodes.append(allocator, try node.copy(allocator));
                },
            }
        }

        const root = try result_nodes.toOwnedSlice(allocator);
        var max_height: usize = 0;
        for (root) |n| max_height = @max(max_height, n.height());
        return Pattern{ .root = root, .height = max_height };
    }

    /// Evaluate a single match operation: lhs : rhs
    /// Returns the matched value if found, null otherwise.
    fn evaluateMatchOp(
        allocator: Allocator,
        lhs: Pattern,
        rhs: Pattern,
    ) Allocator.Error!?Pattern {

        // RHS should be a single node (trie or pattern containing a list)
        if (rhs.root.len == 0) return null;

        debug("evaluateMatchOp: rhs.root.len={}", .{rhs.root.len});

        // Check if RHS is a trie
        if (rhs.root.len == 1) {
            debug("evaluateMatchOp: rhs.root[0] type={s}", .{@tagName(rhs.root[0])});
            switch (rhs.root[0]) {
                .trie => |trie| {
                    debug("evaluateMatchOp: found trie with size={}", .{trie.size()});
                    return try matchWithTrie(allocator, lhs, trie);
                },
                .pattern => |inner| {
                    // Check if it's a list (pattern containing list nodes)
                    return try matchWithList(allocator, lhs, inner);
                },
                else => {},
            }
        }

        // RHS might be a list directly at the pattern level
        return try matchWithList(allocator, lhs, rhs);
    }

    /// Match LHS with a trie: look up LHS in the trie and return its value
    fn matchWithTrie(
        allocator: Allocator,
        lhs: Pattern,
        trie: @import("trie.zig").Trie,
    ) Allocator.Error!?Pattern {
        const trie_module = @import("trie.zig");

        debug("matchWithTrie: trie.size()={}, lhs.root.len={}", .{ trie.size(), lhs.root.len });

        // No value found via match - check if LHS equals any key (set membership)
        // by iterating through all value indices and comparing keys
        const indices = try trie.valueIndices(allocator);
        defer allocator.free(indices);

        debug("matchWithTrie: found {} value indices", .{indices.len});

        for (indices) |idx| {
            const key = try trie.rebuildKey(allocator, idx);
            defer allocator.free(key.root);

            debug("matchWithTrie: checking idx={}, key.root.len={}", .{ idx, key.root.len });

            if (lhs.eql(key)) {
                debug("matchWithTrie: LHS matches key at idx={}", .{idx});
                // Key matches - return the value at this index
                const val = trie.getIndexOrNull(idx);
                if (val) |v| {
                    return try v.copy(allocator);
                }
                return try lhs.copy(allocator);
            }
        }

        // Try to match LHS against the trie using the match function
        var term_bindings = trie_module.VarBindings{};
        defer term_bindings.deinit(allocator);

        var matched = try trie.match(
            allocator,
            .{ .lower = 0, .upper = trie.size() },
            &term_bindings,
            lhs,
        );
        defer matched.deinit(allocator);

        if (matched.value) |value| {
            // Found a direct match with a value - rewrite with bindings
            return try core.rewrite(allocator, value, &term_bindings);
        }

        return null;
    }

    /// Match LHS with a list: check if LHS equals any element
    fn matchWithList(
        allocator: Allocator,
        lhs: Pattern,
        rhs: Pattern,
    ) Allocator.Error!?Pattern {
        // Walk through RHS looking for list elements
        var i: usize = 0;
        while (i < rhs.root.len) : (i += 1) {
            // Check if current position starts a list element that matches LHS
            var element_end = i + 1;

            // Find where this element ends (at next list node or end)
            while (element_end < rhs.root.len) : (element_end += 1) {
                if (rhs.root[element_end] == .list) break;
            }

            // Build element pattern
            const element_root = rhs.root[i..element_end];
            var element_height: usize = 0;
            for (element_root) |n| element_height = @max(element_height, n.height());
            const element = Pattern{ .root = element_root, .height = element_height };

            // Check if LHS matches this element
            if (lhs.eql(element)) {
                return try lhs.copy(allocator);
            }

            // Skip to after the list separator
            if (element_end < rhs.root.len and rhs.root[element_end] == .list) {
                // The list node contains the remaining elements
                const list_pattern = rhs.root[element_end].list;
                if (try matchWithList(allocator, lhs, list_pattern)) |result| {
                    return result;
                }
                break; // We've processed all remaining elements via recursion
            }

            i = element_end;
        }

        return null;
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
