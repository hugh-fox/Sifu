//! Numeric recursion: re-fire a rule at the same index when a sub-term's number
//! is strictly less than the number that matched at the parent level. This is
//! the value-based analog of `recursive` (which keys on shrinking height), and
//! is what makes a counting rule like `replicate` terminate:
//!   replicate 0 *x -->
//!   replicate n *x --> *x, replicate (n - 1) *x
//! the `n - 1` sub-call shrinks numerically, so it recurses against the same rule.

const std = @import("std");
const Node = @import("../sifu/node.zig").Node;
const Bound = @import("../sifu/trie.zig").Bound;
const math = @import("math.zig");

/// The largest number anywhere in `root`, or null if there are none. Arithmetic
/// sub-expressions are folded first (via `math.foldRoot`) so an unevaluated
/// counter like `(n - 1)` measures as its result, not its largest literal —
/// math folding is a later pass, so the recursion must do its own folding here.
/// Used as a level's numeric measure, mirroring `contentHeight` for height.
pub fn maxNumber(root: []const Node) ?i64 {
    var found: ?i64 = null;
    for (root) |node| {
        if (nodeNumber(node)) |value|
            found = if (found) |f| @max(f, value) else value;
    }
    return found;
}

fn nodeNumber(node: Node) ?i64 {
    return switch (node) {
        .constant => |constant| std.fmt.parseInt(i64, constant, 10) catch null,
        inline .pattern, .list => |sub| math.foldRoot(sub.root) orelse maxNumber(sub.root),
        else => null,
    };
}

/// The upper bound for a numeric descent: re-include the matched index
/// (`bound.lower`) when active and the sub-term's number shrank below the
/// parent's; otherwise null so the caller falls through to the next mode.
pub fn descendUpper(active: bool, bound: Bound, content_number: ?i64, pattern_number: ?i64) ?usize {
    if (!active) return null;
    const content = content_number orelse return null;
    const pattern = pattern_number orelse return null;
    return if (content < pattern) bound.lower else null;
}
