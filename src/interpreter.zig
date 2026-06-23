const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const debug = std.log.debug;
const panic = std.debug.panic;

const Node = @import("sifu/node.zig").Node;
const Pattern = @import("sifu/pattern.zig").Pattern;
const trie_module = @import("sifu/trie.zig");
const Trie = trie_module.Trie;
const VarBindings = trie_module.VarBindings;
const comments_interpreter = @import("interpreter/comments.zig");
const math_interpreter = @import("interpreter/math.zig");
const string_interpreter = @import("interpreter/string.zig");

// Each evaluation mode lives in its own file; this file holds the generic
// `Evaluator` they build on, the pure passes, and the `evaluateModes` pipeline
// that chains the selected modes.
const lower = @import("interpreter/lower.zig");
const nested = @import("interpreter/nested.zig");
const recursive = @import("interpreter/recursive.zig");
const numeric = @import("interpreter/numeric.zig");
const random = @import("interpreter/random.zig");
const Bound = trie_module.Bound;

pub const Mode = enum { lower, nested, recursive, numeric, random };

/// Every mode active: the default `evaluateComplete` behavior.
pub const all_modes: []const Mode = &.{ .lower, .recursive, .nested };

pub const EvalCtx = struct {
    trie: Trie,
    bound: Bound,
    /// The index of the last match at this level, or null until one happens.
    index: ?usize = null,
    /// The descent modes active for this evaluation, shared down through `child`.
    modes: []const Mode = all_modes,
    /// Set by `lift` when a sub-term lost a nesting level, so `afterDescent`
    /// knows to re-settle the level.
    lifted: bool = false,

    fn has(self: EvalCtx, mode: Mode) bool {
        return std.mem.indexOfScalar(Mode, self.modes, mode) != null;
    }

    /// The rule index to match from at this level, or null once the level has
    /// settled. `.random` picks within the bound; otherwise the lowest in-range
    /// index. Used by `lower.matchStep` to gate matching.
    pub fn pickIndex(self: EvalCtx) ?usize {
        if (self.has(.random))
            return random.pickIndex(self.bound);
        return lower.nextIndex(self.bound);
    }

    /// The bounds for descending into a sub-pattern of `content_height` within a
    /// level of `pattern_height`. Before a match at this level (index == null) the
    /// sub-term keeps the full upper bound. After a match a shrinking sub-term may
    /// recurse at the same index (`recursive`, §2) and an equal-height one drops
    /// strictly below it (`nested`, §3); each applies only if its mode is active
    /// (a disabled mode yields upper 0, leaving the sub-term unmatched).
    /// `numeric` (§2 on values) re-fires the index on `sub` unless a previous
    /// rule already matches it (then it defers to that rule via `nested`).
    pub fn child(
        self: EvalCtx,
        content_height: usize,
        pattern_height: usize,
        sub: Pattern,
        allocator: Allocator,
    ) Allocator.Error!EvalCtx {
        // A recursive descent (§2) re-fires the matched rule at the same index on
        // a shrinking sub-term, so it keeps a `lower = 0` range capped at the
        // current index. A non-recursive nested descent instead shrinks the
        // bound from the bottom: it continues from the raised lower (past the
        // matched rule) with the full upper, so later rules can still fire deeper
        // in the nesting. It may shrink over rules that could have matched, but
        // never cycles — the lower bound only rises, exhausting the rules.
        const sub_bound: Bound = if (self.index == null)
            .{ .lower = 0, .upper = self.bound.upper }
        else if (recursive.descendUpper(self.has(.recursive), self.bound, content_height, pattern_height)) |upper|
            .{ .lower = 0, .upper = upper }
        else if (try numeric.descendUpper(self.has(.numeric), self.trie, self.bound, sub, allocator)) |upper|
            .{ .lower = 0, .upper = upper }
        else if (self.has(.nested))
            .{ .lower = 0, .upper = nested.descendUpper(self.bound) }
        else
            .{ .lower = 0, .upper = 0 };
        return .{
            .trie = self.trie,
            .bound = sub_bound,
            .modes = self.modes,
        };
    }

    /// The structural rewrites of a settled level: the inline-trie membership
    /// match (`lhs : {trie}`), which finalizes the level, and (when `.nested` is
    /// active) the operator/list-head recursion, which reduces the head in place
    /// before the driver descends. The caller owns `current` and frees it on error.
    pub fn transform(self: *EvalCtx, current: *Pattern, allocator: Allocator) Allocator.Error!?Pattern {
        if (try lower.membership(self.trie, self.bound.upper, current, allocator)) |result|
            return result;
        if (self.has(.nested))
            try nested.head(allocator, self.trie, self.modes, self.bound.upper, current);
        return null;
    }

    /// After a sub-term `node` has been reduced (its evaluation reached
    /// `child_it`'s lower bound), the nested mode re-attempts it one level up so
    /// a rule matching only the enclosing form (`(x) -> x`) can fire. Records a
    /// successful lift for `afterDescent`. A no-op when `.nested` is inactive.
    pub fn lift(self: *EvalCtx, node: *Node, child_it: anytype, allocator: Allocator) Allocator.Error!void {
        if (!self.has(.nested)) return;
        if (try nested.lift(self.trie, self.modes, self.bound.upper, node.*, child_it.ctx.bound.lower, allocator)) |reduced| {
            node.deinit(allocator);
            node.* = reduced;
            self.lifted = true;
        }
    }

    /// Re-settle the level once if a `lift` removed a nesting level, in case a
    /// match here is now possible (e.g. an application whose argument became a
    /// constant). Returns the re-settled level, or null to keep `current`.
    pub fn afterDescent(self: *EvalCtx, current: *Pattern, allocator: Allocator) Allocator.Error!?Pattern {
        if (!self.lifted) return null;
        self.lifted = false;
        const settled = try nested.resettle(self.trie, self.modes, self.bound, current.*, allocator);
        current.* = .{};
        return settled;
    }
};

/// The trie-matching iterator: `EvalCtx` bookkeeping stepped by `lower.matchStep`
/// (the §1 match/rewrite), gated on the `.lower` mode being active.
pub const EvalEvaluator = Evaluator(EvalCtx, evalStep);

fn evalStep(current: Pattern, allocator: Allocator, ctx: *EvalCtx) Allocator.Error!?Pattern {
    if (!ctx.has(.lower)) return null;
    return lower.matchStep(current, allocator, ctx);
}

/// Build an `EvalEvaluator` over a copy of `pattern`, matching from rule 0.
pub fn initEval(trie: Trie, allocator: Allocator, pattern: Pattern) Allocator.Error!EvalEvaluator {
    return initEvalAt(trie, allocator, 0, pattern);
}

/// Build an `EvalEvaluator` over a copy of `pattern`, matching from rule `lower_index`.
pub fn initEvalAt(
    trie: Trie,
    allocator: Allocator,
    lower_index: usize,
    pattern: Pattern,
) Allocator.Error!EvalEvaluator {
    return .{
        .allocator = allocator,
        .current = try pattern.copy(allocator),
        .ctx = .{ .trie = trie, .bound = .{ .lower = lower_index, .upper = trie.length() } },
    };
}

/// Evaluate `pattern` against `trie` to a fixed point with the given `modes`
/// active, composed per level inside a single traversal.
pub fn evaluateModes(
    trie: Trie,
    allocator: Allocator,
    pattern: Pattern,
    modes: []const Mode,
) Allocator.Error!Pattern {
    var it = try initEval(trie, allocator, pattern);
    it.ctx.modes = modes;
    defer it.deinit();
    return it.next();
}

pub fn Evaluator(
    comptime Ctx: type,
    comptime stepFn: fn (Pattern, Allocator, *Ctx) Allocator.Error!?Pattern,
) type {
    return struct {
        allocator: Allocator,
        current: Pattern = .{},
        ctx: Ctx,

        const Self = @This();

        /// Fully evaluate `current` against the context and return the result.
        /// Takes ownership of `current` (it is left empty), so the result is the
        /// caller's; `.ctx` remains readable for the final bookkeeping.
        pub fn next(self: *Self) Allocator.Error!Pattern {
            return evaluate(self);
        }

        /// One atomic rewrite. Returns the new `current` (owned by the iterator)
        /// or null once this level has settled (nothing changed). The atomic
        /// step does not free the old `current`; that is done here on replace.
        /// This is the unit `evaluate` loops to a fixed point.
        pub fn step(self: *Self) Allocator.Error!?Pattern {
            const stepped = (try stepFn(self.current, self.allocator, &self.ctx)) orelse
                return null;
            self.current.deinit(self.allocator);
            self.current = stepped;
            return self.current;
        }

        pub fn deinit(self: *Self) void {
            self.current.deinit(self.allocator);
        }
    };
}

fn evaluate(it: anytype) Allocator.Error!Pattern {
    const Eval = @TypeOf(it.*);
    const allocator = it.allocator;
    const pattern_height = it.current.height;

    // Settle this level: run the step until it reports no more change.
    while (try it.step()) |_| {}

    // Take ownership of the settled pattern; the context keeps its bookkeeping
    // so `child` can still derive recursion bounds.
    var current = it.current;
    it.current = .{};
    errdefer current.deinit(allocator);

    // Hand the level to the context's structural transforms. A returned value is
    // the final result (recursion stops); null means descend into `current`,
    // which `transform` may have mutated in place.
    if (try it.ctx.transform(&current, allocator)) |result| return result;

    var max_height: usize = 0;
    for (current.root) |*node| switch (node.*) {
        .infix => |inf| {
            var child_it = try spawnChild(Eval, it.ctx, inf.rhs, pattern_height, allocator);
            errdefer child_it.deinit();
            var rhs = try evaluate(&child_it);
            rhs.height += 1;
            max_height = @max(max_height, rhs.height);
            @constCast(&inf.rhs).deinit(allocator);
            node.* = Node{ .infix = .{ .op = inf.op, .rhs = rhs } };
        },
        inline .pattern, .match, .arrow, .list, .semicolon => |sub, tag| {
            var child_it = try spawnChild(Eval, it.ctx, sub, pattern_height, allocator);
            errdefer child_it.deinit();
            var evaluated = try evaluate(&child_it);
            evaluated.height += 1;
            // Only a sub-term that actually reduced can newly match a rule one
            // level up; an unchanged one would just re-grow it.
            const changed = !evaluated.eql(sub);
            @constCast(&sub).deinit(allocator);
            node.* = @unionInit(Node, @tagName(tag), evaluated);
            // Let the context re-attempt the just-reduced sub-term one level up
            // (the nested mode's `(x) -> x` style lift); a no-op for the rest.
            if (changed) try it.ctx.lift(node, &child_it, allocator);
            max_height = @max(max_height, node.height());
        },
        inline .newline, .indent => |sep, tag| {
            var child_it = try spawnChild(Eval, it.ctx, sep.rhs, pattern_height, allocator);
            errdefer child_it.deinit();
            var evaluated = try evaluate(&child_it);
            evaluated.height += 1;
            max_height = @max(max_height, evaluated.height);
            @constCast(&sep.rhs).deinit(allocator);
            node.* = @unionInit(Node, @tagName(tag), .{ .ws = sep.ws, .rhs = evaluated });
        },
        else => max_height = @max(max_height, node.height()),
    };
    current.height = max_height;

    // Give the context a chance to re-settle the level after a lift (a no-op for
    // the pure passes and when nothing was lifted).
    if (try it.ctx.afterDescent(&current, allocator)) |result| return result;
    return current;
}

/// Build a child iterator of type `Eval` for descending into `sub`. The child's
/// context comes from the parent's `ctx.child` (which derives recursion bounds
/// from `content_height`/`pattern_height`); its `current` is a copy of `sub`
/// reset to the unwrapped `content_height` so the recursion reads the right
/// height. Identical preparation for every context, so it is hoisted here.
fn spawnChild(
    comptime Eval: type,
    parent_ctx: anytype,
    sub: Pattern,
    pattern_height: usize,
    allocator: Allocator,
) Allocator.Error!Eval {
    const content_height = contentHeight(sub.root);
    var current = try sub.copy(allocator);
    current.height = content_height;
    return .{
        .allocator = allocator,
        .current = current,
        .ctx = try parent_ctx.child(content_height, pattern_height, sub, allocator),
    };
}

/// The height of a level's content: the max height over its nodes, with no
/// wrapping `+1`. Used by `evaluate` (and the rewrite) to set a child's height
/// when descending into it as its own root.
pub fn contentHeight(root: []const Node) usize {
    var height: usize = 0;
    for (root) |node| height = @max(height, node.height());
    return height;
}

/// The context for a pure (non-trie) pass: no match bounds, no early-finish
/// transform. It only satisfies the `evaluate` driver's interface so the pure
/// `step` functions can reuse the same node-walk as the trie rewrite.
const PureCtx = struct {
    pub fn transform(_: *PureCtx, _: *Pattern, _: Allocator) Allocator.Error!?Pattern {
        return null; // pure passes never finalize early; always recurse
    }
    pub fn child(_: PureCtx, _: usize, _: usize, _: Pattern, _: Allocator) Allocator.Error!PureCtx {
        return .{};
    }
    pub fn lift(_: *PureCtx, _: *Node, child_it: anytype, _: Allocator) Allocator.Error!void {
        _ = child_it; // pure passes have no trie to re-match against
    }
    pub fn afterDescent(_: *PureCtx, _: *Pattern, _: Allocator) Allocator.Error!?Pattern {
        return null;
    }
};

/// Adapt a pure `step` (which ignores any context) to the `Evaluator` step
/// signature, which threads a `*PureCtx`.
fn pureStep(
    comptime step: fn (Pattern, Allocator) Allocator.Error!?Pattern,
) fn (Pattern, Allocator, *PureCtx) Allocator.Error!?Pattern {
    return struct {
        fn f(p: Pattern, a: Allocator, _: *PureCtx) Allocator.Error!?Pattern {
            return step(p, a);
        }
    }.f;
}

/// Run a pure `step` over `pattern` to a fixed point at every level, through the
/// same node-walk the trie rewrite uses.
fn evaluatePure(
    allocator: Allocator,
    pattern: Pattern,
    comptime step: fn (Pattern, Allocator) Allocator.Error!?Pattern,
) Allocator.Error!Pattern {
    var it = Evaluator(PureCtx, pureStep(step)){
        .allocator = allocator,
        .current = try pattern.copy(allocator),
        .ctx = .{},
    };
    defer it.deinit();
    return it.next();
}

pub fn evaluateComments(allocator: Allocator, pattern: Pattern) Allocator.Error!Pattern {
    // Strip comments first, then collapse the layout whitespace they leave
    // behind (a second pass so separators emptied by nested comments are seen).
    var stripped = try evaluatePure(allocator, pattern, comments_interpreter.step);
    defer stripped.deinit(allocator);
    return evaluatePure(allocator, stripped, comments_interpreter.whitespaceStep);
}

pub fn evaluateMath(allocator: Allocator, pattern: Pattern) Allocator.Error!Pattern {
    return evaluatePure(allocator, pattern, math_interpreter.step);
}

pub fn evaluateStrings(allocator: Allocator, pattern: Pattern) Allocator.Error!Pattern {
    return evaluatePure(allocator, pattern, string_interpreter.step);
}

pub fn evaluateComplete(
    trie: Trie,
    allocator: Allocator,
    pattern: Pattern,
) Allocator.Error!?Pattern {
    // Strip comments from the query so they never reach matching or output.
    var stripped = try evaluateComments(allocator, pattern);
    defer stripped.deinit(allocator);

    // Trie-driven match/rewrite evaluation. Each mode is its own pass, chained
    // by `evaluateModes`; drop a mode or reorder to mix and match.
    var evaluated = try evaluateModes(trie, allocator, stripped, &.{
        .lower, // §1: match at the index, then raise the lower bound past it
        .recursive, // §2: recurse at the same index on shrinking sub-terms
        .numeric, // §2 on values: recurse at the same index on shrinking numbers
        .nested, // §3: descend strictly below the index (e.g. list heads)
    });
    defer evaluated.deinit(allocator);

    // Fold any arithmetic expressions in the result.
    var folded_math = try evaluateMath(allocator, evaluated);
    defer folded_math.deinit(allocator);

    // Fold any string concatenations in the result.
    return try evaluateStrings(allocator, folded_math);
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

/// Evaluate `query_str` against `trie` with exactly `modes` active and assert the
/// printed result equals `expected_str`. Used to pin down each evaluation mode
/// (`.lower`, `.recursive`, `.nested`) on its own and in combination.
fn expectSteps(
    allocator: Allocator,
    trie: Trie,
    query_str: []const u8,
    modes: []const Mode,
    expected_str: []const u8,
) !void {
    var query = try Parser.parse(allocator, query_str);
    defer query.deinit(allocator);
    var val = try evaluateModes(trie, allocator, query, modes);
    defer val.deinit(allocator);
    const result_str = try val.toString(allocator);
    defer allocator.free(result_str);
    try testing.expectEqualStrings(expected_str, result_str);
}

test "evaluateModes: lower gates matching" {
    var trie = try Parser.parseTrie(testing.allocator, "A -> B");
    defer trie.deinit(testing.allocator);
    // With lower on, A matches and rewrites to B.
    try expectSteps(testing.allocator, trie, "A", &.{.lower}, "B");
    // Lower is the matcher; without it the other modes have nothing to descend.
    try expectSteps(testing.allocator, trie, "A", &.{ .recursive, .nested }, "A");
}

test "evaluateModes: recursive reduces shrinking sub-terms at the same index" {
    var trie = try Parser.parseTrie(testing.allocator, "(x) --> x\n(x, *xs) --> x, (*xs)");
    defer trie.deinit(testing.allocator);
    // Recursive alone (no nested) collapses the whole list by re-firing the rules
    // on the shrinking tail at the same index.
    try expectSteps(testing.allocator, trie, "(1, 2, 3)", &.{ .lower, .recursive }, "1, 2, 3");
    // Without recursive, only the top level is reduced; the tail stays nested.
    try expectSteps(testing.allocator, trie, "(1, 2, 3)", &.{.lower}, "1, (2, 3)");
}

test "evaluateModes: nested reduces list heads against previous rules" {
    var trie = try Parser.parseTrie(testing.allocator,
        \\F x --> G x
        \\(x, *xs) --> F x, (*xs)
    );
    defer trie.deinit(testing.allocator);
    // Nested (with lower) evaluates the list head (F 1) against the previous rule
    // inside the nested expression; the tail stays nested since collapsing it
    // would require re-firing the same rule (recursive).
    try expectSteps(testing.allocator, trie, "(1, 2,)", &.{ .lower, .nested }, "G 1, (2, )");
    // Without nested, the head is left unreduced.
    try expectSteps(testing.allocator, trie, "(1, 2,)", &.{.lower}, "F 1, (2, )");
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
    const x_trie = trie.var_map.get("x") orelse return error.MissingX;
    try testing.expect(x_trie.getToken(",") != null);
    const comma_trie = x_trie.getToken(",") orelse return error.MissingComma;
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
    var rewritten = try Trie.rewrite(testing.allocator, match_result.value.?, &bindings);
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
    const x_trie = trie.var_map.get("x") orelse {
        return error.TestUnexpectedResult;
    };
    // Check for comma
    try testing.expect(x_trie.getToken(",") != null);
    const comma_trie = x_trie.getToken(",").?;
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
