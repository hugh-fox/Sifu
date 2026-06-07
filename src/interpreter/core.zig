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
const pure = @import("pure.zig");
const comments = @import("comments.zig");
const string = @import("string.zig");

pub const Eval = struct {
    value: ?Pattern = null,
    index: usize = 0,
    len: usize = 0,
};

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
        .key => |key| try result.append(allocator, Node.ofKey(key)),
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
        else => panic("unimplemented", .{}),
    };

    const nodes = try result.toOwnedSlice(allocator);
    return Pattern{ .root = nodes, .height = max_child };
}

/// Run the full evaluation pipeline. Each stage is one evaluator driven over
/// the pattern: comments are stripped, the trie's match/rewrite evaluator runs,
/// then string concatenations are folded. Each pure-pattern stage is a single
/// `step` driven by `Pattern.evaluate`, which owns recursion and height.
pub fn evaluateComplete(
    trie: Trie,
    allocator: Allocator,
    lower_bound: usize,
    pattern: Pattern,
) Allocator.Error!Eval {
    // Strip comments from the query so they never reach matching or output.
    var stripped = try pattern.evaluate(allocator, comments.step);
    defer stripped.deinit(allocator);

    // Trie-driven match/rewrite evaluation.
    var eval = try evaluateBounded(trie, allocator, .{ .lower = lower_bound, .upper = trie.size() }, stripped);

    // Fold any string concatenations in the result.
    if (eval.value) |value| {
        var produced = value;
        const folded = try produced.evaluate(allocator, string.step);
        produced.deinit(allocator);
        eval.value = folded;
    }
    return eval;
}

pub fn evaluateMatch(
    trie: Trie,
    allocator: Allocator,
    bound: Bound,
    pattern: Pattern,
) Allocator.Error!Eval {
    var term_bindings = VarBindings{};
    defer term_bindings.deinit(allocator);

    var matched = try trie.match(allocator, bound, &term_bindings, pattern);
    defer matched.deinit(allocator);

    const matched_value = matched.value orelse {
        return Eval{ .value = null, .index = matched.match_index, .len = matched.len };
    };

    const rewritten = try rewrite(allocator, matched_value, &term_bindings);
    return Eval{ .value = rewritten, .index = matched.match_index, .len = matched.len };
}

/// The mutable state an evaluator (`Step`) threads through one level of
/// evaluation. Each step owns its bound bookkeeping here and is responsible for
/// advancing it so it eventually returns null (signalling "no more matches"),
/// which is how the driver terminates.
///
/// Two distinct axes meet in this struct, and keeping them apart is the whole
/// point:
///
///   - The trie's `Bound` is a half-open range of *trie indices*. Evaluation
///     starts at `{ .lower = 0, .upper = trie.size() }` — 0 up to the trie's
///     height — and a `match` against the trie returns an *index* within that
///     range (`index` below).
///
///   - A *pattern* is measured along a different axis. `len` is how far a match
///     progressed *through the pattern*; `height` is the pattern's level of
///     nesting. Pattern height — not the trie index — is what governs
///     structural recursion (see `child`).
pub const Context = struct {
    trie: Trie,
    bound: Bound,
    allocator: Allocator,
    /// The lower bound at the start of this level, restored on a structural
    /// rewrite so the smaller result is rescanned from the beginning.
    start_lower: usize = 0,
    /// Trie index of the last successful top-level match at this level (a
    /// position within `bound`). This is what bounds child matches on recursion.
    index: usize = 0,
    /// How far that match progressed through the pattern. Reported out as
    /// `Eval.len`; it is pattern progress, not a trie index, so it never bounds.
    len: usize = 0,
    matched: bool = false,

    /// Derive the context for a nested child whose pattern height (nesting
    /// level) is `content_height`, inside a level of pattern height
    /// `pattern_height`. Structural recursion keys off pattern *height*: when
    /// the child is strictly less nested than its parent (`(x, *xs) -> x,
    /// (*xs)`) the term is shrinking, so the producing rule may fire again and
    /// the child may rematch at the same trie index (`index + 1`). When the
    /// child is the same height, just wrapped a level deeper (`A -> (A)`),
    /// reusing the rule would loop forever, so the child must match strictly
    /// before that index (`index`). This index/height interplay is the only
    /// trie-specific knowledge the generic driver needs, so it lives on the
    /// context the caller supplies.
    pub fn child(self: Context, content_height: usize, pattern_height: usize) Context {
        const structural_upper = if (self.matched) self.index + 1 else self.bound.upper;
        const nested_upper = if (self.matched) self.index else self.bound.upper;
        const recurse_upper = if (content_height < pattern_height) structural_upper else nested_upper;
        return .{
            .trie = self.trie,
            .bound = .{ .lower = 0, .upper = recurse_upper },
            .allocator = self.allocator,
        };
    }
};

/// A step is any `fn (Pattern, ctx: anytype) Allocator.Error!?Pattern`. It
/// transforms one pattern level, returning the rewritten pattern when it
/// changed something (the driver then repeats) or null when it did nothing.
/// `ctx` is a pointer to whatever context type the caller chose; the step and
/// the context agree on its shape. Recursion into nested sub-patterns and the
/// repeat loop are the driver's (`evaluate`) job.
///
/// The trie evaluator's ordered step list: match/rewrite against the trie, then
/// reduce a list/op head prefix (and `:` match operators).
const trie_steps = .{ matchStep, lhsStep };

/// The unified evaluation driver, generic over the caller's context type. At
/// each level it applies the steps in order, repeating from the first whenever
/// one fires, until every step returns null. It then recurses once into the
/// nested children — whose context is derived via `ctx.child(...)` — and
/// returns. Steps own their bounds and termination; the driver owns recursion
/// and height tracking.
///
/// `ctx` is a pointer to the caller's context (it must expose `allocator`,
/// `bound`, `start_lower`, and a `child(content_height, pattern_height)`
/// method). `steps` is a comptime tuple of step functions.
///
/// Caller owns the returned pattern and should free it with `deinit`.
fn evaluate(pattern: Pattern, ctx: anytype, comptime steps: anytype) Allocator.Error!Pattern {
    const pattern_height = pattern.height;
    ctx.start_lower = ctx.bound.lower;
    var current = try pattern.copy(ctx.allocator);

    // Apply the steps in order, restarting from the first whenever one fires,
    // until they all report "no change". Steps advance their own bound.
    outer: while (true) {
        inline for (steps) |step| {
            if (try step(current, ctx)) |next| {
                current.deinit(ctx.allocator);
                current = next;
                continue :outer;
            }
        }
        break;
    }

    // Recurse once into the nested children with contexts derived from the
    // settled top-level match outcome.
    for (current.root) |*nested| switch (nested.*) {
        inline else => |sub_pattern, tag| if (@TypeOf(sub_pattern) == Pattern) {
            var content_height: usize = 0;
            for (sub_pattern.root) |node|
                content_height = @max(content_height, node.height());
            const inner = Pattern{ .root = sub_pattern.root, .height = content_height };
            var child_ctx = ctx.child(content_height, pattern_height);
            var new_value = try evaluate(inner, &child_ctx, steps);
            new_value.height += 1;
            @constCast(&sub_pattern).deinit(ctx.allocator);
            nested.* = @unionInit(Node, @tagName(tag), new_value);
        },
    };
    return current;
}

/// Trie match/rewrite as a single step. Performs one top-level match within
/// `ctx.bound`; on success it rewrites, records the match's trie `index` and
/// pattern `len` in `ctx`, and advances the bound. A structural rewrite — one
/// whose result is strictly less nested (lower pattern height) — rescans the
/// shrinking term from `start_lower` up to the matched index; a rewrite that
/// keeps the same height advances the lower bound past the matched rule so it
/// can't re-fire. Returns null when no rule matches in range.
fn matchStep(pattern: Pattern, ctx: *Context) Allocator.Error!?Pattern {
    if (ctx.bound.lower >= ctx.bound.upper) return null;
    const m = try evaluateMatch(ctx.trie, ctx.allocator, ctx.bound, pattern);
    const rewritten = m.value orelse return null;

    ctx.index = m.index;
    ctx.len = m.len;
    ctx.matched = true;

    const is_structural = pattern.height > rewritten.height;
    debug("matchStep: structural={} ({} > {})", .{ is_structural, pattern.height, rewritten.height });
    ctx.bound = if (is_structural)
        .{ .lower = ctx.start_lower, .upper = m.index + 1 }
    else
        .{ .lower = m.index + 1, .upper = ctx.bound.upper };

    return rewritten;
}

pub fn evaluateBounded(
    trie: Trie,
    allocator: Allocator,
    bound: Bound,
    pattern: Pattern,
) Allocator.Error!Eval {
    var ctx = Context{ .trie = trie, .bound = bound, .allocator = allocator };
    const value = try evaluate(pattern, &ctx, trie_steps);
    const eval = Eval{
        .value = value,
        .index = if (ctx.matched) ctx.index else bound.upper,
        .len = ctx.len,
    };
    debug("Evaluated {} nodes at index {}\n", .{ eval.len, eval.index });
    return eval;
}

// Tests

const testing = std.testing;
const ArenaAllocator = std.heap.ArenaAllocator;
const Parser = @import("../Parser.zig");

fn expectEval(allocator: Allocator, trie: Trie, query_str: []const u8, expected_str: []const u8) !void {
    var query = try Parser.parse(allocator, query_str);
    defer query.deinit(allocator);
    const eval = try evaluateComplete(trie, allocator, 0, query);
    if (eval.value) |*val| {
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
    const eval = try evaluateComplete(trie, testing.allocator, 0, query);
    if (eval.value) |*val| {
        defer @constCast(val).deinit(testing.allocator);
        try testing.expect(val.eql(query));
    }
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
    try testing.expect(query.root[0] == .key);
    try testing.expect(query.root[1] == .list);

    var term_bindings = VarBindings{};
    defer term_bindings.deinit(testing.allocator);
    var match_result = try trie.match(testing.allocator, .{ .upper = trie.size() }, &term_bindings, query);
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
    try bindings.put(testing.allocator, "x", Node{ .key = "A" });

    // Rewrite should replace x with A
    var result = try rewrite(testing.allocator, value_pattern, &bindings);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.root.len);
    try testing.expect(result.root[0] == .key);
    try testing.expectEqualStrings("A", result.root[0].key);
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
    try bindings.put(testing.allocator, "x", Node{ .key = "A" });
    try bindings.put(testing.allocator, "y", Node{ .key = "B" });

    // Rewrite should produce [B, list([A])]
    var result = try rewrite(testing.allocator, value_pattern, &bindings);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.root.len);
    try testing.expect(result.root[0] == .key);
    try testing.expectEqualStrings("B", result.root[0].key);
    try testing.expect(result.root[1] == .list);
    try testing.expectEqual(@as(usize, 1), result.root[1].list.root.len);
    try testing.expect(result.root[1].list.root[0] == .key);
    try testing.expectEqualStrings("A", result.root[1].list.root[0].key);
}

test "evaluateComplete: step by step x, y --> y, x" {
    var trie = try Parser.parseTrie(testing.allocator, "x, y --> y, x");
    defer trie.deinit(testing.allocator);

    var query = try Parser.parse(testing.allocator, "A, B");
    defer query.deinit(testing.allocator);

    const eval = try evaluateComplete(trie, testing.allocator, 0, query);
    var result = eval.value orelse return error.NoEvalResult;
    defer result.deinit(testing.allocator);

    // Result should be [B, list([A])]
    try testing.expectEqual(@as(usize, 2), result.root.len);
    try testing.expect(result.root[0] == .key);
    try testing.expectEqualStrings("B", result.root[0].key);
    try testing.expect(result.root[1] == .list);
    try testing.expectEqual(@as(usize, 1), result.root[1].list.root.len);
    try testing.expect(result.root[1].list.root[0] == .key);
    try testing.expectEqualStrings("A", result.root[1].list.root[0].key);
}

test "evaluateComplete: simple var_pattern unwrap" {
    // (*xs) --> *xs should unwrap the outer parens
    var trie = try Parser.parseTrie(testing.allocator, "(*xs) --> *xs");
    defer trie.deinit(testing.allocator);

    try expectEval(testing.allocator, trie, "(A)", "A");
    try expectEval(testing.allocator, trie, "(A, B)", "A, B");
    try expectEval(testing.allocator, trie, "(A, B, C)", "A, B, C");
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
    var match_result = try trie.match(testing.allocator, .{ .upper = trie.size() }, &bindings, query);
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
    const eval_result2 = try evaluateComplete(trie, allocator, 0, query2);
    _ = eval_result2;

    // Then (2, 3)
    const query3 = try Parser.parse(allocator, "(2, 3)");
    const eval_result3 = try evaluateComplete(trie, allocator, 0, query3);
    _ = eval_result3;

    // (1, 2, 3) should evaluate to 1, 2, 3
    const query = try Parser.parse(allocator, "(1, 2, 3)");
    const eval_result = try evaluateComplete(trie, allocator, 0, query);

    if (eval_result.value) |value| {
        const str = try value.toString(allocator);
        try testing.expectEqualStrings("1, 2, 3", str);
    } else {
        return error.TestUnexpectedResult;
    }
}

/// Evaluate the head (LHS) of a pattern. When the result is a list/op
/// (a non-list prefix followed by a top-level comma `,` list node), the
/// complete-match loop cannot reduce the prefix on its own because the
/// trailing comma prevents the whole pattern from matching any rule, and
/// the nested-recursion loop only descends into wrapper nodes. Reduce the
/// prefix here as its own sub-pattern, e.g. the head `F 1` of `F 1, (2, 3)`
/// reduces to `G 1`. Returns `current` unchanged if there is no reducible
/// head; otherwise the old root is freed and a new one is returned.
///
/// Also evaluates match operators (`:`) via the pure step.
///
/// As a `Step`: does not free its input (the driver owns it) and returns null
/// when nothing changed, so the driver's repeat loop terminates.
fn lhsStep(pattern: Pattern, ctx: *Context) Allocator.Error!?Pattern {
    const allocator = ctx.allocator;
    var result = try pattern.evaluate(allocator, pure.step);

    var list_pos: usize = result.root.len;
    for (result.root, 0..) |node, i| {
        if (node == .list) {
            list_pos = i;
            break;
        }
    }
    if (list_pos > 0 and list_pos < result.root.len) {
        var head_height: usize = 0;
        for (result.root[0..list_pos]) |node|
            head_height = @max(head_height, node.height());
        var head_eval = try evaluateBounded(
            ctx.trie,
            allocator,
            .{ .lower = 0, .upper = ctx.bound.upper },
            .{ .root = result.root[0..list_pos], .height = head_height },
        );
        if (head_eval.value) |*head_val| {
            defer head_val.deinit(allocator);
            const tail = result.root[list_pos..];
            const new_root = try allocator.alloc(Node, head_val.root.len + tail.len);
            for (head_val.root, new_root[0..head_val.root.len]) |node, *dst|
                dst.* = try node.copy(allocator);
            @memcpy(new_root[head_val.root.len..], tail);
            for (result.root[0..list_pos]) |*node|
                @constCast(node).deinit(allocator);
            allocator.free(result.root);
            var new_height: usize = 0;
            for (new_root) |node| new_height = @max(new_height, node.height());
            result = .{ .root = new_root, .height = new_height };
        }
    }
    // The driver owns the input; only hand back an owned result when something
    // actually changed, otherwise free our copy and report "no change".
    if (result.eql(pattern)) {
        result.deinit(allocator);
        return null;
    }
    return result;
}
