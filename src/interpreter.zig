const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const debug = std.log.debug;
const panic = std.debug.panic;

const Node = @import("sifu/node.zig").Node;
const Pattern = @import("sifu/pattern.zig").Pattern;
const trie_module = @import("sifu/trie.zig");
const Trie = trie_module.Trie;
const Bound = trie_module.Bound;
const VarBindings = trie_module.VarBindings;
const comments_interpreter = @import("interpreter/comments.zig");
const math_interpreter = @import("interpreter/math.zig");
const string_interpreter = @import("interpreter/string.zig");

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

/// Adapt a trie-free `step` (`fn (Pattern, ctx) Allocator.Error!?Pattern`, null
/// when nothing changed) into the unified driver's step interface
/// (`fn (*Iterator) Allocator.Error!?Pattern`). The pure step only needs the
/// allocator; it reads and replaces `it.current` and ignores the trie/bounds.
fn pureStep(comptime f: anytype) fn (*Iterator) Allocator.Error!?Pattern {
    return struct {
        fn step(it: *Iterator) Allocator.Error!?Pattern {
            const next = (try f(it.current, .{ .allocator = it.allocator })) orelse
                return null;
            it.current.deinit(it.allocator);
            it.current = next;
            return it.current;
        }
    }.step;
}

/// Drive a pure (trie-free) `step` over every level of a pattern using the
/// single `evaluate` driver (with an empty trie, so no matching happens). A
/// pure step is `fn (Pattern, ctx) Allocator.Error!?Pattern`, returning null
/// when it changed nothing. Caller owns the returned pattern.
pub fn evaluatePure(
    allocator: Allocator,
    pattern: Pattern,
    comptime step: anytype,
) Allocator.Error!Pattern {
    var it = try Iterator.init(Trie{}, allocator, pattern);
    defer it.deinit();
    return evaluate(&it, pureStep(step), false);
}

/// Bound/index bookkeeping for trie evaluation. The iterator owns the `current`
/// pattern and the lower/upper bounds; it does *not* perform matching. Each
/// `next` only reports the index to match from (or null once the level has
/// settled); the actual match/rewrite is the `matchStep` evaluator, which calls
/// back into `advance` to move the bounds. The recursive `evaluate` drives this
/// to a fixed point and spawns `child` iterators for nested patterns; wasm
/// drives `matchStep` directly to expose each step of evaluation.
pub const Iterator = struct {
    trie: Trie,
    allocator: Allocator,
    bound: Bound,
    start_lower: usize = 0,
    index: usize = 0,
    matched: bool = false,
    current: Pattern = .{},

    pub fn init(trie: Trie, allocator: Allocator, pattern: Pattern) Allocator.Error!Iterator {
        return initAt(trie, allocator, 0, pattern);
    }

    pub fn initAt(
        trie: Trie,
        allocator: Allocator,
        lower: usize,
        pattern: Pattern,
    ) Allocator.Error!Iterator {
        return .{
            .trie = trie,
            .allocator = allocator,
            .bound = .{ .lower = lower, .upper = trie.length() },
            .start_lower = lower,
            .current = try pattern.copy(allocator),
        };
    }

    pub fn deinit(self: *Iterator) void {
        self.current.deinit(self.allocator);
    }

    /// The index to match from on this step, or null once the level has settled
    /// (the lower bound reached the upper). This only tracks position; matching
    /// is `matchStep`'s job.
    pub fn next(self: *Iterator) ?usize {
        if (self.bound.lower >= self.bound.upper)
            return null;
        return self.bound.lower;
    }

    /// Record a match at `match_index`, raising the lower bound past the matched
    /// rule so it cannot fire again at this level. Structural recursion (rescanning
    /// a shrunk term against earlier rules) is handled by `child` on descent, not
    /// by rescanning here: rescanning the top level from a lower bound re-opens
    /// growing rules and loops on cyclic programs (e.g. `A -> (A); (A) -> A`).
    fn advance(self: *Iterator, match_index: usize) void {
        self.index = match_index;
        self.matched = true;
        debug("Iterator.advance: at index {}", .{match_index});
        self.bound = .{ .lower = match_index + 1, .upper = self.bound.upper };
    }

    fn child(
        self: Iterator,
        sub: Pattern,
        content_height: usize,
        pattern_height: usize,
    ) Allocator.Error!Iterator {
        const structural_upper = if (self.matched) self.index + 1 else self.bound.upper;
        const nested_upper = if (self.matched) self.index else self.bound.upper;
        const recurse_upper = if (content_height < pattern_height) structural_upper else nested_upper;
        // `sub.height` carries the wrapping level's `+1`; the child evaluates the
        // unwrapped content, so reset its height to `content_height`. Otherwise
        // the recursive `evaluate` reads a `pattern_height` one too high and a
        // same-height rewrite (e.g. `A -> (A)`) looks structural and loops.
        var current = try sub.copy(self.allocator);
        current.height = content_height;
        return .{
            .trie = self.trie,
            .allocator = self.allocator,
            .bound = .{ .lower = 0, .upper = recurse_upper },
            .current = current,
        };
    }
};

/// One top-level trie match/rewrite step driven by `it`. Reads the index to
/// match from via `it.next`, matches `it.current` against the trie there, and
/// on success rewrites `it.current` and advances the iterator's bounds.
/// Returns the new `current` (owned by `it`) or null when nothing matched and
/// the level has settled. Kept separate from the iterator so the iterator only
/// tracks position; this is the trie-matching evaluator.
pub fn matchStep(it: *Iterator) Allocator.Error!?Pattern {
    const allocator = it.allocator;
    if (it.next() == null) return null;

    // A bare `{trie}` literal is a settled value, not a query term: matching it
    // against the rule trie is meaningless and crashes the trie matcher. Leave
    // it as-is so a label resolved to its bound trie (e.g. `T1 -> {A, B}`) stops.
    if (it.current.root.len == 1 and it.current.root[0] == .trie) return null;

    var term_bindings = VarBindings{};
    defer term_bindings.deinit(allocator);
    var match = try it.trie.match(allocator, it.bound, &term_bindings, it.current);
    defer match.deinit(allocator);
    const matched_value = match.value orelse return null;

    const rewritten = try rewrite(allocator, matched_value, &term_bindings);
    it.advance(match.match_index);

    it.current.deinit(allocator);
    it.current = rewritten;
    return it.current;
}

/// The single evaluation driver. Settles the current level by running `step`
/// to a fixed point, then recurses into every child with the same step. `step`
/// transforms `it.current` in place and returns the new value (or null when
/// nothing changed). When `trie_transforms` is set (the `matchStep` matcher),
/// the level also gets the trie-specific transforms: inline-trie `lhs : {trie}`
/// matching and operator/list head recursion. Pure steps (comments, strings)
/// pass `false` and ignore the iterator's trie and bounds entirely.
fn evaluate(
    it: *Iterator,
    comptime step: fn (*Iterator) Allocator.Error!?Pattern,
    comptime trie_transforms: bool,
) Allocator.Error!Pattern {
    const allocator = it.allocator;
    const pattern_height = it.current.height;
    it.start_lower = it.bound.lower;

    // Settle this level: run the step until it reports no more change.
    while (try step(it)) |_| {}

    // Take ownership of the settled pattern; the iterator keeps its bookkeeping
    // (index, matched, bound) so `child` can still derive recursion bounds.
    var current = it.current;
    it.current = .{};
    errdefer current.deinit(allocator);

    // Pattern match against an inline trie: `lhs : {trie}`. The trailing match
    // node carries its own trie, so the lhs (the prefix before it) is evaluated
    // against that trie using this same recursive evaluator rather than the
    // iterator's trie. A lhs that isn't a member evaluates to the empty pattern.
    if (trie_transforms and
        current.root.len >= 2 and current.root[current.root.len - 1] == .match)
    {
        const raw_rhs = current.root[current.root.len - 1].match;
        // A label rhs (e.g. `T1`) is resolved against the iterator's trie first
        // so it becomes its bound `{trie}` before the membership check; a literal
        // `{trie}` rhs is already in hand and is used directly.
        const is_literal_trie = raw_rhs.root.len == 1 and raw_rhs.root[0] == .trie;
        var resolved: ?Pattern = null;
        if (!is_literal_trie) {
            var rhs_it = Iterator{
                .trie = it.trie,
                .allocator = allocator,
                .bound = .{ .lower = 0, .upper = it.bound.upper },
                .current = try raw_rhs.copy(allocator),
            };
            errdefer rhs_it.deinit();
            resolved = try evaluate(&rhs_it, step, trie_transforms);
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
                var lhs_it = try Iterator.init(inline_trie, allocator, lhs);
                defer lhs_it.deinit();
                break :blk try evaluate(&lhs_it, step, trie_transforms);
            };
            errdefer out.deinit(allocator);
            current.deinit(allocator);
            return out;
        }
    }

    // Operator recursion: when a top-level list operator survives the match
    // loop, the prefix before it (the operator's lhs) is a head that no whole
    // rule consumed, so evaluate it as its own sub-expression and splice the
    // result back ahead of the tail. The tail itself is the nested list child
    // handled by the recursion below.
    if (trie_transforms) if (firstList(current.root)) |list_pos| {
        const head = Pattern{
            .root = current.root[0..list_pos],
            .height = contentHeight(current.root[0..list_pos]),
        };
        var head_it = Iterator{
            .trie = it.trie,
            .allocator = allocator,
            .bound = .{ .lower = 0, .upper = it.bound.upper },
            .current = try head.copy(allocator),
        };
        errdefer head_it.deinit();
        var reduced = try evaluate(&head_it, step, trie_transforms);
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
    };

    var max_height: usize = 0;
    for (current.root) |*node| switch (node.*) {
        .infix => |inf| {
            var child_it = try it.child(inf.rhs, contentHeight(inf.rhs.root), pattern_height);
            errdefer child_it.deinit();
            var rhs = try evaluate(&child_it, step, trie_transforms);
            rhs.height += 1;
            max_height = @max(max_height, rhs.height);
            @constCast(&inf.rhs).deinit(allocator);
            node.* = Node{ .infix = .{ .op = inf.op, .rhs = rhs } };
        },
        inline .pattern, .match, .arrow, .list, .newline => |sub, tag| {
            var child_it = try it.child(sub, contentHeight(sub.root), pattern_height);
            errdefer child_it.deinit();
            var evaluated = try evaluate(&child_it, step, trie_transforms);
            evaluated.height += 1;
            max_height = @max(max_height, evaluated.height);
            @constCast(&sub).deinit(allocator);
            node.* = @unionInit(Node, @tagName(tag), evaluated);
        },
        else => max_height = @max(max_height, node.height()),
    };
    current.height = max_height;
    return current;
}

fn contentHeight(root: []const Node) usize {
    var height: usize = 0;
    for (root) |node| height = @max(height, node.height());
    return height;
}

fn firstList(root: []const Node) ?usize {
    for (root, 0..) |node, i|
        if (node == .list) return if (i > 0) i else null;
    return null;
}

pub fn evaluateBounded(
    trie: Trie,
    allocator: Allocator,
    pattern: Pattern,
) Allocator.Error!Pattern {
    var it = try Iterator.init(trie, allocator, pattern);
    defer it.deinit();
    return evaluate(&it, matchStep, true);
}

pub fn evaluateComplete(
    trie: Trie,
    allocator: Allocator,
    pattern: Pattern,
) Allocator.Error!?Pattern {
    // Strip comments from the query so they never reach matching or output.
    var stripped = try evaluatePure(allocator, pattern, comments_interpreter.step);
    defer stripped.deinit(allocator);

    // Trie-driven match/rewrite evaluation (structural and nested recursion,
    // including `lhs : {trie}` matches against inline tries).
    var evaluated = try evaluateBounded(trie, allocator, stripped);
    defer evaluated.deinit(allocator);

    // Fold any arithmetic expressions in the result.
    var folded_math = try evaluatePure(allocator, evaluated, math_interpreter.step);
    defer folded_math.deinit(allocator);

    // Fold any string concatenations in the result.
    return try evaluatePure(allocator, folded_math, string_interpreter.step);
}

const testing = std.testing;
const ArenaAllocator = std.heap.ArenaAllocator;
const Parser = @import("Parser.zig");

fn expectEval(allocator: Allocator, trie: Trie, query_str: []const u8, expected_str: []const u8) !void {
    var query = try Parser.parse(allocator, query_str);
    defer query.deinit(allocator);
    if (try evaluateComplete(trie, allocator, query)) |*val| {
        defer @constCast(val).deinit(allocator);
        var expected = try Parser.parse(allocator, expected_str);
        defer expected.deinit(allocator);
        if (!val.eql(expected)) {
            const result_str = try val.toString(allocator);
            defer allocator.free(result_str);
            try testing.expectEqualStrings(expected_str, result_str);
        }
    } else {
        return error.NoEvalResult;
    }
}

test "evaluateComplete: simple rewrite" {
    var trie = try Parser.parseTrie(testing.allocator, "A -> B");
    defer trie.deinit(testing.allocator);
    try expectEval(testing.allocator, trie, "A", "B");
}

test "evaluateComplete: variable binding" {
    var trie = try Parser.parseTrie(testing.allocator, "x -> x");
    defer trie.deinit(testing.allocator);
    try expectEval(testing.allocator, trie, "Foo", "Foo");
}

test "evaluateComplete: multi-term with variable" {
    var trie = try Parser.parseTrie(testing.allocator, "Inc x -> x");
    defer trie.deinit(testing.allocator);
    try expectEval(testing.allocator, trie, "Inc 5", "5");
}

test "evaluateComplete: no match returns original" {
    var trie = try Parser.parseTrie(testing.allocator, "A -> B");
    defer trie.deinit(testing.allocator);
    var query = try Parser.parse(testing.allocator, "C");
    defer query.deinit(testing.allocator);
    if (try evaluateComplete(trie, testing.allocator, query)) |*val| {
        defer @constCast(val).deinit(testing.allocator);
        try testing.expect(val.eql(query));
    }
}

test "evaluateComplete: inline trie membership A : {A -> B}" {
    var trie = Trie{};
    defer trie.deinit(testing.allocator);
    try expectEval(testing.allocator, trie, "A : {A -> B}", "B");
}

test "evaluateComplete: roundtrip" {
    var trie = try Parser.parseTrie(testing.allocator, "A -> B; B -> A");
    defer trie.deinit(testing.allocator);
    try expectEval(testing.allocator, trie, "A", "A");
}

test "evaluateComplete: VarPattern in nested list" {
    var trie = try Parser.parseTrie(testing.allocator, "A, *x --> *x");
    defer trie.deinit(testing.allocator);

    try expectEval(testing.allocator, trie, "A,", "");
    try expectEval(testing.allocator, trie, "A, B", "B");
    try expectEval(testing.allocator, trie, "A, B, C", "B, C");
    try expectEval(testing.allocator, trie, "A, B, C,", "B, C,");
}

test "evaluateComplete: nested pattern" {
    var trie = try Parser.parseTrie(testing.allocator, "x, y --> y, x");
    defer trie.deinit(testing.allocator);

    // Verify trie structure: x -> , -> y -> value
    try testing.expect(trie.var_branches.items.len == 1);
    const x_trie = trie.map.get("x") orelse return error.MissingX;
    try testing.expect(x_trie.map.contains(","));
    const comma_trie = x_trie.map.get(",") orelse return error.MissingComma;
    try testing.expect(comma_trie.var_branches.items.len == 1);

    // Test the match directly
    var query = try Parser.parse(testing.allocator, "A, B");
    defer query.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), query.root.len);
    try testing.expect(query.root[0] == .constant);
    try testing.expect(query.root[1] == .list);

    var term_bindings = VarBindings{};
    defer term_bindings.deinit(testing.allocator);
    var match_result = try trie.match(testing.allocator, .{ .upper = trie.length() }, &term_bindings, query);
    defer match_result.deinit(testing.allocator);

    // Match should succeed with value
    try testing.expect(match_result.value != null);

    // Check bindings
    try testing.expect(term_bindings.get("x") != null);
    try testing.expect(term_bindings.get("y") != null);

    try expectEval(testing.allocator, trie, "A, B", "B, A");
}

test "evaluateComplete: VarPattern in nested pattern" {
    var trie = try Parser.parseTrie(testing.allocator, "(x, *x) --> x + *x");
    defer trie.deinit(testing.allocator);
    try expectEval(testing.allocator, trie, "(A, B C)", "A + B C");
}

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

test "evaluateComplete: step by step x, y --> y, x" {
    var trie = try Parser.parseTrie(testing.allocator, "x, y --> y, x");
    defer trie.deinit(testing.allocator);

    var query = try Parser.parse(testing.allocator, "A, B");
    defer query.deinit(testing.allocator);

    var result = try evaluateComplete(trie, testing.allocator, query) orelse
        return error.NoEvalResult;
    defer result.deinit(testing.allocator);

    // Result should be [B, list([A])]
    try testing.expectEqual(@as(usize, 2), result.root.len);
    try testing.expect(result.root[0] == .constant);
    try testing.expectEqualStrings("B", result.root[0].constant);
    try testing.expect(result.root[1] == .list);
    try testing.expectEqual(@as(usize, 1), result.root[1].list.root.len);
    try testing.expect(result.root[1].list.root[0] == .constant);
    try testing.expectEqualStrings("A", result.root[1].list.root[0].constant);
}

test "evaluateComplete: simple var_pattern unwrap" {
    // (*xs) --> *xs should unwrap the outer parens
    var trie = try Parser.parseTrie(testing.allocator, "(*xs) --> *xs");
    defer trie.deinit(testing.allocator);

    try expectEval(testing.allocator, trie, "(A)", "A");
    try expectEval(testing.allocator, trie, "(A, B)", "A, B");
    try expectEval(testing.allocator, trie, "(A, B, C)", "A, B, C");
}

test "Operators: list heads evaluated against a lower rule" {
    // The nested-recursion example from Evaluation.md: each rewritten list head
    // (`F 1`) is reduced by the lower rule (`F x --> G x`). The trailing commas
    // keep a list separator at every step so the tail keeps recursing.
    var trie = try Parser.parseTrie(testing.allocator,
        \\F x --> G x
        \\(x, *xs) --> F x, (*xs)
    );
    defer trie.deinit(testing.allocator);

    try expectEval(testing.allocator, trie, "(1,)", "G 1, ()");
    try expectEval(testing.allocator, trie, "(1, 2,)", "G 1, G 2, ()");
    try expectEval(testing.allocator, trie, "(1, 2, 3,)", "G 1, G 2, G 3, ()");
}

test "Structural recursion: height tracking through evaluation" {
    // Simulate the evaluation of (1, 2, 3) with rules:
    // (x) --> x           (rule 0)
    // (x, *xs) --> x, (*xs)  (rule 1)
    //
    // Heights with new model (each op adds 1):
    // - "(1, 2, 3)": parens(1) + comma(1) + comma(1) = 3
    // - "1, (2, 3)": comma(1) + parens(1) + comma(1) = 3
    // - "(2, 3)": parens(1) + comma(1) = 2
    //
    // Step 1: (1, 2, 3) matches rule 1, x=1, *xs=(2, 3)
    // Rewrite to: 1, (2, 3) with height 3
    // is_structural: query.height(3) > rewritten.height(3) = false

    var trie = try Parser.parseTrie(testing.allocator, "(x) --> x\n(x, *xs) --> x, (*xs)");
    defer trie.deinit(testing.allocator);

    var query = try Parser.parse(testing.allocator, "(1, 2, 3)");
    defer query.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), query.height);

    // Match step
    var bindings = VarBindings{};
    defer bindings.deinit(testing.allocator);
    var match_result = try trie.match(testing.allocator, .{ .upper = trie.length() }, &bindings, query);
    defer match_result.deinit(testing.allocator);

    // Should match rule 1
    try testing.expectEqual(@as(usize, 1), match_result.match_index);
    try testing.expect(match_result.value != null);

    // Rewrite step
    var rewritten = try rewrite(testing.allocator, match_result.value.?, &bindings);
    defer rewritten.deinit(testing.allocator);

    // Check structural recursion condition
    const is_structural_top = query.height > rewritten.height;
    try testing.expect(!is_structural_top); // 3 > 3 = false

    // Check the nested pattern inside the rewritten result
    // rewritten = [1, list([pattern(2, 3)])]
    try testing.expectEqual(@as(usize, 2), rewritten.root.len);
    try testing.expect(rewritten.root[1] == .list);

    const list_pattern = rewritten.root[1].list;
    try testing.expectEqual(@as(usize, 1), list_pattern.root.len);
    try testing.expect(list_pattern.root[0] == .pattern);

    const nested_pattern_node = list_pattern.root[0];
    // Node.height() returns the Pattern's height inside the node
    // (2, 3) = parens(1) + comma(1) = 2
    try testing.expectEqual(@as(usize, 2), nested_pattern_node.height());

    const nested_content = nested_pattern_node.pattern;
    try testing.expectEqual(@as(usize, 2), nested_content.height);

    // Structural recursion check: nested height 2 < query height 3
    const is_structural_nested = nested_pattern_node.height() < query.height;
    try testing.expect(is_structural_nested); // 2 < 3 = true
}

test "Structural recursion with var_pattern: (x, *xs) --> x, (*xs)" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const trie = try Parser.parseTrie(allocator,
        \\(x) --> x
        \\(x, *xs) --> x, (*xs)
    );

    // First verify (1, 2) works
    const query2 = try Parser.parse(allocator, "(1, 2)");
    const eval_result2 = try evaluateComplete(trie, allocator, query2);
    _ = eval_result2;

    // Then (2, 3)
    const query3 = try Parser.parse(allocator, "(2, 3)");
    const eval_result3 = try evaluateComplete(trie, allocator, query3);
    _ = eval_result3;

    // (1, 2, 3) should evaluate to 1, 2, 3
    const query = try Parser.parse(allocator, "(1, 2, 3)");
    const eval_result = try evaluateComplete(trie, allocator, query);

    if (eval_result) |value| {
        const str = try value.toString(allocator);
        try testing.expectEqualStrings("1, 2, 3", str);
    } else {
        return error.TestUnexpectedResult;
    }
}

test "List with variables: x, y --> y, x" {
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    // Key: [x, list([y])] representing "x, y"
    var constant_pat_list = [_]Node{.{ .variable = "y" }};
    var constant_root = [_]Node{
        .{ .variable = "x" },
        .{ .list = .{ .root = &constant_pat_list } },
    };

    // Value: [y, list([x])] representing "y, x"
    var val_list = [_]Node{.{ .variable = "x" }};
    var val_root = [_]Node{
        .{ .variable = "y" },
        .{ .list = .{ .root = &val_list } },
    };

    _ = try trie.append(
        testing.allocator,
        Pattern{ .root = &constant_root },
        Pattern{ .root = &val_root },
    );

    // Verify trie structure: should have var x -> , -> var y -> value
    try testing.expect(trie.var_branches.items.len > 0);
    // Get the trie under x (variables are stored in map)
    const x_trie = trie.map.get("x") orelse {
        return error.TestUnexpectedResult;
    };
    // Check for comma
    try testing.expect(x_trie.map.contains(","));
    const comma_trie = x_trie.map.get(",").?;
    // Check for y variable
    try testing.expect(comma_trie.var_branches.items.len > 0);

    // Query: [A, list([B])] representing "A, B"
    var query_list = [_]Node{.{ .constant = "B" }};
    var query_root = [_]Node{
        .{ .constant = "A" },
        .{ .list = .{ .root = &query_list } },
    };

    const eval_result = try evaluateComplete(
        trie,
        testing.allocator,
        Pattern{ .root = &query_root },
    );

    if (eval_result) |value| {
        var val = value;
        defer val.deinit(testing.allocator);
        const str = try val.toString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("B, A", str);
    } else {
        return error.TestUnexpectedResult;
    }
}

test "VarPattern in nested pattern" {
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    // Key: (x, *x) - pattern containing [x, list(*x)]
    var inner_list = [_]Node{.{ .variable = "*x" }};
    var constant_pat_inner = [_]Node{
        .{ .variable = "x" },
        .{ .list = .{ .root = &inner_list } },
    };
    var constant_root = [_]Node{.{ .pattern = .{ .root = &constant_pat_inner } }};

    // Value: x + *x
    var val_root = [_]Node{
        .{ .variable = "x" },
        .{ .constant = "+" },
        .{ .variable = "*x" },
    };

    _ = try trie.append(
        testing.allocator,
        Pattern{ .root = &constant_root },
        Pattern{ .root = &val_root },
    );

    // Query: (1, 2 3) - pattern containing [1, list([2, 3])]
    var query_list_inner = [_]Node{ .{ .constant = "2" }, .{ .constant = "3" } };
    var query_inner = [_]Node{
        .{ .constant = "1" },
        .{ .list = .{ .root = &query_list_inner } },
    };
    var query_root = [_]Node{.{ .pattern = .{ .root = &query_inner } }};

    const eval_result = try evaluateComplete(
        trie,
        testing.allocator,
        Pattern{ .root = &query_root },
    );

    if (eval_result) |value| {
        var val = value;
        defer val.deinit(testing.allocator);
        const str = try val.toString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1 + 2 3", str);
    } else {
        try testing.expect(false);
    }
}
