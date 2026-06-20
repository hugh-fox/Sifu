//! The lower-bound trie-matching evaluation mode (Evaluation.md §1).
//!
//! This is the base evaluation mode: each `step` performs one rule match +
//! variable-capture rewrite (the rewrite itself lives on `Trie.rewrite`) and
//! raises the lower bound past the matched rule so it cannot fire again at this
//! level. It also supplies the `lhs : {trie}` inline-trie membership rewrite the
//! pure passes don't have. The generic driver lives in the parent
//! `interpreter.zig`; the other modes (`nested`, `recursive`) reuse the shared
//! `matchStep`/`nextIndex` helpers here and differ only in `child`/`transform`.
//!
//! The three evaluation modes differ only in where the next match may land
//! relative to the current match index `i`: `lower` raises past it (`> i`),
//! `nested` drops strictly below it (`< i`), and `recursive` re-includes it
//! (`<= i`) to re-fire the same rule on a shrunken term. They compose per level
//! inside `core.EvalCtx`, which threads a single `Bound` down through `child`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const debug = std.log.debug;

const Node = @import("../sifu/node.zig").Node;
const Pattern = @import("../sifu/pattern.zig").Pattern;
const trie_module = @import("../sifu/trie.zig");
const Trie = trie_module.Trie;
const Bound = trie_module.Bound;
const VarBindings = trie_module.VarBindings;

const core = @import("../interpreter.zig");
const contentHeight = core.contentHeight;

/// The index to match from given a `bound`, or null once the level has settled
/// (the lower bound reached the upper). Shared by every mode's `next`.
pub fn nextIndex(bound: Bound) ?usize {
    if (bound.lower >= bound.upper)
        return null;
    return bound.lower;
}

/// One atomic trie match/rewrite step shared by every mode. Matches `current`
/// within `ctx.bound`, and on success raises the lower bound past the match
/// (recording the index in `ctx.index`) so the rule cannot fire again at this
/// level. Returns the rewritten pattern (newly owned) or null once the level has
/// settled. Does not free `current`; the `Evaluator` replaces it. The modes
/// differ only in `child`/`transform`, not here. `ctx` is any mode context with
/// `trie`, `bound`, and `index` fields.
pub fn matchStep(current: Pattern, allocator: Allocator, ctx: anytype) Allocator.Error!?Pattern {
    const from = ctx.pickIndex() orelse return null;
    const bound = Bound{ .lower = from, .upper = ctx.bound.upper };
    const matched = try ctx.trie.matchRewrite(allocator, bound, current) orelse
        return null;
    ctx.index = matched.match_index;
    debug("matchStep: at index {}", .{matched.match_index});
    ctx.bound = .{ .lower = matched.match_index + 1, .upper = ctx.bound.upper };
    return matched.value;
}

/// The lower mode's structural rewrite (its `ModeCtx.transform`): the inline
/// trie membership match (`lhs : {trie}`), which yields the final value for the
/// level. Returns the finished value when the level matches a membership rule, or
/// null to recurse. `upper` is the level's bound upper. The caller owns `current`
/// and frees it on error.
pub fn membership(trie: Trie, upper: usize, current: *Pattern, allocator: Allocator) Allocator.Error!?Pattern {
    // Pattern match against an inline trie: `lhs : {trie}`. The trailing match
    // node carries its own trie, so the lhs (the prefix before it) is evaluated
    // against that trie using this same recursive evaluator rather than this
    // iterator's trie. A lhs that isn't a member evaluates to the empty pattern.
    if (current.root.len >= 2 and current.root[current.root.len - 1] == .match) {
        const raw_rhs = current.root[current.root.len - 1].match;
        // A label rhs (e.g. `T1`) is resolved against this trie first so it
        // becomes its bound `{trie}` before the membership check; a literal
        // `{trie}` rhs is already in hand and is used directly.
        const is_literal_trie = raw_rhs.root.len == 1 and raw_rhs.root[0] == .trie;
        var resolved: ?Pattern = null;
        if (!is_literal_trie) {
            var rhs_it = core.EvalEvaluator{
                .allocator = allocator,
                .current = try raw_rhs.copy(allocator),
                .ctx = .{ .trie = trie, .bound = .{ .lower = 0, .upper = upper } },
            };
            errdefer rhs_it.deinit();
            resolved = try rhs_it.next();
        }
        defer if (resolved) |*r| r.deinit(allocator);
        const rhs = resolved orelse raw_rhs;
        if (rhs.root.len == 1 and rhs.root[0] == .trie) {
            const inline_trie = rhs.root[0].trie;
            const lhs = Pattern{
                .root = current.root[0 .. current.root.len - 1],
                .height = contentHeight(current.root[0 .. current.root.len - 1]),
            };
            // Membership: a full match of the lhs against the trie.
            var bindings = VarBindings{};
            defer bindings.deinit(allocator);
            var matched = try inline_trie.match(allocator, .{ .upper = inline_trie.length() }, &bindings, lhs);
            defer matched.deinit(allocator);
            var out = if (matched.len != lhs.root.len)
                Pattern{ .root = &.{}, .height = 0 }
            else blk: {
                var lhs_it = try core.initEval(inline_trie, allocator, lhs);
                defer lhs_it.deinit();
                break :blk try lhs_it.next();
            };
            errdefer out.deinit(allocator);
            current.deinit(allocator);
            current.* = .{};
            return out;
        }
    }

    return null;
}

pub fn firstList(root: []const Node) ?usize {
    for (root, 0..) |node, i|
        if (node == .list or node == .semicolon) return if (i > 0) i else null;
    return null;
}

const testing = std.testing;
const Parser = @import("../Parser.zig");

test "rewrite: simple variable substitution" {
    var trie = try Parser.parseTrie(testing.allocator, "x --> x");
    defer trie.deinit(testing.allocator);

    // Value pattern is [variable(x)]
    const value_pattern = trie.getIndex(0);

    // Set up bindings: x = A
    var bindings = VarBindings{};
    defer bindings.deinit(testing.allocator);
    try bindings.put(testing.allocator, "x", Node{ .constant = "A" });

    // Rewrite should replace x with A
    var result = try Trie.rewrite(testing.allocator, value_pattern, &bindings);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.root.len);
    try testing.expect(result.root[0] == .constant);
    try testing.expectEqualStrings("A", result.root[0].constant);
}

test "rewrite: nested list with variables" {
    var trie = try Parser.parseTrie(testing.allocator, "x, y --> y, x");
    defer trie.deinit(testing.allocator);

    // Value pattern is [variable(y), list([variable(x)])]
    const value_pattern = trie.getIndex(0);
    try testing.expectEqual(@as(usize, 2), value_pattern.root.len);
    try testing.expect(value_pattern.root[0] == .variable);
    try testing.expect(value_pattern.root[1] == .list);

    // Set up bindings: x = A, y = B
    var bindings = VarBindings{};
    defer bindings.deinit(testing.allocator);
    try bindings.put(testing.allocator, "x", Node{ .constant = "A" });
    try bindings.put(testing.allocator, "y", Node{ .constant = "B" });

    // Rewrite should produce [B, list([A])]
    var result = try Trie.rewrite(testing.allocator, value_pattern, &bindings);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.root.len);
    try testing.expect(result.root[0] == .constant);
    try testing.expectEqualStrings("B", result.root[0].constant);
    try testing.expect(result.root[1] == .list);
    try testing.expectEqual(@as(usize, 1), result.root[1].list.root.len);
    try testing.expect(result.root[1].list.root[0] == .constant);
    try testing.expectEqualStrings("A", result.root[1].list.root[0].constant);
}
