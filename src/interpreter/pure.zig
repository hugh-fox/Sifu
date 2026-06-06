const std = @import("std");
const Allocator = std.mem.Allocator;

const Node = @import("../sifu/node.zig").Node;
const Pattern = @import("../sifu/pattern.zig").Pattern;

/// Evaluate match operators (`:`) without requiring a trie context.
/// The `:` operator is right-associative, so `A : {B}` parses as [A, match({B})].
/// LHS is prefix before the match node, RHS is inside the match node.
/// Returns empty pattern when match fails.
/// Always returns a pattern. Caller owns the returned pattern and should free with deinit.
pub fn evaluatePure(pattern: Pattern, allocator: Allocator) Allocator.Error!Pattern {
    // Find the last .match node (`:` is right-associative so it's always last if present)
    if (pattern.root.len > 0 and pattern.root[pattern.root.len - 1] == .match) {
        const match_idx = pattern.root.len - 1;
        const match_pattern = pattern.root[match_idx].match;

        if (match_idx == 0) {
            // No LHS, just copy the pattern
            return pattern.copy(allocator);
        }

        // LHS is the prefix before the match node
        var lhs_height: usize = 0;
        for (pattern.root[0..match_idx]) |n| lhs_height = @max(lhs_height, n.height());
        const lhs = Pattern{ .root = pattern.root[0..match_idx], .height = lhs_height };

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

    for (pattern.root) |node| {
        switch (node) {
            inline .pattern, .arrow, .list, .infix, .newline => |sub_pattern, tag| {
                const evaluated = try evaluatePure(sub_pattern, allocator);
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
    if (rhs.root.len == 0) return null;

    const last_idx = rhs.root.len - 1;
    const last_node = rhs.root[last_idx];

    // Check element (prefix before any list/trie node)
    var element_height: usize = 0;
    for (rhs.root[0..last_idx]) |n| element_height = @max(element_height, n.height());
    const element = Pattern{ .root = rhs.root[0..last_idx], .height = element_height };

    if (element.root.len > 0 and lhs.eql(element)) {
        return try lhs.copy(allocator);
    }

    // Handle last node based on type
    switch (last_node) {
        .list => |list_pattern| return try evaluateMatchOp(allocator, lhs, list_pattern),
        .pattern => |inner| return try evaluateMatchOp(allocator, lhs, inner),
        else => {
            // Single element case - check if LHS matches entire RHS
            if (lhs.eql(rhs)) {
                return try lhs.copy(allocator);
            }
            return null;
        },
    }
}
