//! The trie-matching evaluation step.
//!
//! This is the trie-specific context driven by `core.evaluate`: it owns the
//! match bounds and performs one rule match + variable-capture rewrite per
//! `step`, and supplies the structural rewrites (`lhs : {trie}` membership and
//! operator/list head recursion) the pure passes don't have. The generic driver
//! and the trie-free steps live elsewhere; this file is only the matcher.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const debug = std.log.debug;
const panic = std.debug.panic;

const Node = @import("../sifu/node.zig").Node;
const Pattern = @import("../sifu/pattern.zig").Pattern;
const trie_module = @import("../sifu/trie.zig");
const Trie = trie_module.Trie;
const Bound = trie_module.Bound;
const VarBindings = trie_module.VarBindings;

const core = @import("../interpreter.zig");
const contentHeight = core.contentHeight;

/// The trie-matching iterator: the `MatchCtx` bookkeeping paired with the atomic
/// `matchStep` via the standardized `Evaluator`.
pub const MatchEvaluator = core.Evaluator(MatchCtx, matchStep);

/// Rewrites all variable captures into the matched expression. Copies any
/// variables in node if they are keys in bindings with their values. If
/// there are no matches in bindings, this function is equivalent to copy.
pub fn rewrite(
    allocator: Allocator,
    pattern: Pattern,
    term_bindings: *const VarBindings,
) Allocator.Error!Pattern {
    var result = ArrayList(Node).empty;
    errdefer result.deinit(allocator);
    var max_child: usize = 0;

    for (pattern.root) |node| switch (node) {
        .constant => |constant| try result.append(allocator, Node.ofConstant(constant)),
        .variable => |variable| {
            const is_var_pattern = variable.len > 0 and variable[0] == '*';
            if (is_var_pattern) {
                if (term_bindings.get(variable)) |sub_pattern| {
                    debug("Var pattern found: {s}", .{variable});
                    for (sub_pattern.pattern.root) |sub_node| {
                        const copied = try sub_node.copy(allocator);
                        max_child = @max(max_child, copied.height());
                        try result.append(allocator, copied);
                    }
                } else try result.append(allocator, node);
            } else {
                if (term_bindings.get(variable)) |bound_node| {
                    debug("Var found: {s}", .{variable});
                    const copied = try bound_node.copy(allocator);
                    max_child = @max(max_child, copied.height());
                    try result.append(allocator, copied);
                } else {
                    debug("Var not found", .{});
                    try result.append(allocator, node);
                }
            }
        },
        inline .pattern, .arrow, .match, .list => |nested, tag| {
            const rewritten = try rewrite(allocator, nested, term_bindings);
            const wrapped = Pattern{ .root = rewritten.root, .height = rewritten.height + 1 };
            max_child = @max(max_child, wrapped.height);
            try result.append(allocator, @unionInit(Node, @tagName(tag), wrapped));
        },
        .infix => |inf| {
            const rewritten = try rewrite(allocator, inf.rhs, term_bindings);
            const wrapped = Pattern{ .root = rewritten.root, .height = rewritten.height + 1 };
            max_child = @max(max_child, wrapped.height);
            try result.append(allocator, Node{ .infix = .{ .op = inf.op, .rhs = wrapped } });
        },
        // A trie literal carries no rewritable variables of its own; copy it
        // through so a value like `A : {trie}` survives the rewrite intact.
        .trie => try result.append(allocator, try node.copy(allocator)),
        // Comments are kept in the trie (so its print stays layout-faithful) but
        // are inert: drop them from a rewritten value so they never reach output.
        .comment => {},
        else => panic("unimplemented", .{}),
    };

    const nodes = try result.toOwnedSlice(allocator);
    return Pattern{ .root = nodes, .height = max_child };
}

/// Bound/index bookkeeping for trie evaluation. The context owns the lower/upper
/// bounds and the index of the last match; it does *not* own the pattern (that
/// lives on the `Evaluator`) and does *not* perform matching. `next` only reports
/// the index to match from (or null once the level has settled); the actual
/// match/rewrite is the `matchStep` step function, which calls back into `advance`
/// to move the bounds. The recursive `evaluate` drives a `MatchEvaluator` to a
/// fixed point and spawns `child` contexts for nested patterns; wasm drives
/// `next` directly to expose each step of evaluation.
pub const MatchCtx = struct {
    trie: Trie,
    bound: Bound,
    index: usize = 0,
    matched: bool = false,

    /// The index to match from on this step, or null once the level has settled
    /// (the lower bound reached the upper). This only tracks position; matching
    /// is `matchStep`'s job.
    pub fn next(self: *MatchCtx) ?usize {
        if (self.bound.lower >= self.bound.upper)
            return null;
        return self.bound.lower;
    }

    /// Record a match at `match_index`, raising the lower bound past the matched
    /// rule so it cannot fire again at this level. Structural recursion (rescanning
    /// a shrunk term against earlier rules) is handled by `child` on descent, not
    /// by rescanning here: rescanning the top level from a lower bound re-opens
    /// growing rules and loops on cyclic programs (e.g. `A -> (A); (A) -> A`).
    fn advance(self: *MatchCtx, match_index: usize) void {
        self.index = match_index;
        self.matched = true;
        debug("MatchCtx.advance: at index {}", .{match_index});
        self.bound = .{ .lower = match_index + 1, .upper = self.bound.upper };
    }

    /// The bounds for descending into a sub-pattern of `content_height` within a
    /// level of `pattern_height`. The `Evaluator` prepares the child's `current`;
    /// this only derives the recursion bounds from the last match.
    pub fn child(
        self: MatchCtx,
        content_height: usize,
        pattern_height: usize,
    ) MatchCtx {
        const structural_upper = if (self.matched) self.index + 1 else self.bound.upper;
        const nested_upper = if (self.matched) self.index else self.bound.upper;
        const recurse_upper = if (content_height < pattern_height) structural_upper else nested_upper;
        return .{
            .trie = self.trie,
            .bound = .{ .lower = 0, .upper = recurse_upper },
        };
    }

    /// Apply the trie-language structural rewrites to a settled level. Two of
    /// them: an inline-trie membership match (`lhs : {trie}`), which yields the
    /// final value for this level (`done`), and operator/list head recursion,
    /// which reduces the head in place before `evaluate` descends into the tail
    /// (recurse). Mutates `current` in place (the operator/list-head splice) and
    /// returns null to recurse, or the finished value when the level is done. The
    /// caller owns `current` and frees it on error.
    pub fn transform(self: *MatchCtx, current: *Pattern, allocator: Allocator) Allocator.Error!?Pattern {
        // Pattern match against an inline trie: `lhs : {trie}`. The trailing
        // match node carries its own trie, so the lhs (the prefix before it) is
        // evaluated against that trie using this same recursive evaluator rather
        // than this iterator's trie. A lhs that isn't a member evaluates to the
        // empty pattern.
        if (current.root.len >= 2 and current.root[current.root.len - 1] == .match) {
            const raw_rhs = current.root[current.root.len - 1].match;
            // A label rhs (e.g. `T1`) is resolved against this trie first so it
            // becomes its bound `{trie}` before the membership check; a literal
            // `{trie}` rhs is already in hand and is used directly.
            const is_literal_trie = raw_rhs.root.len == 1 and raw_rhs.root[0] == .trie;
            var resolved: ?Pattern = null;
            if (!is_literal_trie) {
                var rhs_it = MatchEvaluator{
                    .allocator = allocator,
                    .current = try raw_rhs.copy(allocator),
                    .ctx = .{ .trie = self.trie, .bound = .{ .lower = 0, .upper = self.bound.upper } },
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
                    var lhs_it = try initMatch(inline_trie, allocator, lhs);
                    defer lhs_it.deinit();
                    break :blk try lhs_it.next();
                };
                errdefer out.deinit(allocator);
                current.deinit(allocator);
                current.* = .{};
                return out;
            }
        }

        // Operator recursion: when a top-level list operator survives the match
        // loop, the prefix before it (the operator's lhs) is a head that no whole
        // rule consumed, so evaluate it as its own sub-expression and splice the
        // result back ahead of the tail. The tail itself is the nested list child
        // handled by `evaluate`'s recursion.
        if (firstList(current.root)) |list_pos| {
            const head = Pattern{
                .root = current.root[0..list_pos],
                .height = contentHeight(current.root[0..list_pos]),
            };
            var head_it = MatchEvaluator{
                .allocator = allocator,
                .current = try head.copy(allocator),
                .ctx = .{ .trie = self.trie, .bound = .{ .lower = 0, .upper = self.bound.upper } },
            };
            errdefer head_it.deinit();
            var reduced = try head_it.next();
            if (reduced.eql(head)) {
                reduced.deinit(allocator);
            } else {
                const tail = current.root[list_pos..];
                const spliced = try allocator.alloc(Node, reduced.root.len + tail.len);
                @memcpy(spliced[0..reduced.root.len], reduced.root);
                @memcpy(spliced[reduced.root.len..], tail);
                for (current.root[0..list_pos]) |*node| @constCast(node).deinit(allocator);
                allocator.free(current.root);
                allocator.free(reduced.root);
                current.root = spliced;
            }
        }

        return null;
    }
};

/// One atomic trie match/rewrite step, the `Evaluator` step function for
/// `MatchCtx`. Reads the index to match from via `ctx.next`, matches `current`
/// against the trie there, and on success returns the rewritten pattern (newly
/// owned) and advances the context's bounds. Returns null when nothing matched
/// and the level has settled. Does not free `current`; the `Evaluator` replaces
/// it. Kept separate from the context so the context only tracks position.
pub fn matchStep(current: Pattern, allocator: Allocator, ctx: *MatchCtx) Allocator.Error!?Pattern {
    if (ctx.next() == null) return null;

    // A bare `{trie}` literal is a settled value, not a query term: matching it
    // against the rule trie is meaningless and crashes the trie matcher. Leave
    // it as-is so a label resolved to its bound trie (e.g. `T1 -> {A, B}`) stops.
    if (current.root.len == 1 and current.root[0] == .trie) return null;

    var term_bindings = VarBindings{};
    defer term_bindings.deinit(allocator);
    var match = try ctx.trie.match(allocator, ctx.bound, &term_bindings, current);
    defer match.deinit(allocator);
    const matched_value = match.value orelse return null;

    const rewritten = try rewrite(allocator, matched_value, &term_bindings);
    ctx.advance(match.match_index);
    return rewritten;
}

fn firstList(root: []const Node) ?usize {
    for (root, 0..) |node, i|
        if (node == .list) return if (i > 0) i else null;
    return null;
}

/// Build a `MatchEvaluator` over a copy of `pattern`, matching from rule 0.
pub fn initMatch(trie: Trie, allocator: Allocator, pattern: Pattern) Allocator.Error!MatchEvaluator {
    return initMatchAt(trie, allocator, 0, pattern);
}

/// Build a `MatchEvaluator` over a copy of `pattern`, matching from rule `lower`.
pub fn initMatchAt(
    trie: Trie,
    allocator: Allocator,
    lower: usize,
    pattern: Pattern,
) Allocator.Error!MatchEvaluator {
    return .{
        .allocator = allocator,
        .current = try pattern.copy(allocator),
        .ctx = .{ .trie = trie, .bound = .{ .lower = lower, .upper = trie.length() } },
    };
}

/// Evaluate `pattern` against `trie` to a fixed point with the trie matcher.
pub fn evaluateBounded(
    trie: Trie,
    allocator: Allocator,
    pattern: Pattern,
) Allocator.Error!Pattern {
    var it = try initMatch(trie, allocator, pattern);
    defer it.deinit();
    return it.next();
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
    var result = try rewrite(testing.allocator, value_pattern, &bindings);
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
    var result = try rewrite(testing.allocator, value_pattern, &bindings);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.root.len);
    try testing.expect(result.root[0] == .constant);
    try testing.expectEqualStrings("B", result.root[0].constant);
    try testing.expect(result.root[1] == .list);
    try testing.expectEqual(@as(usize, 1), result.root[1].list.root.len);
    try testing.expect(result.root[1].list.root[0] == .constant);
    try testing.expectEqualStrings("A", result.root[1].list.root[0].constant);
}
