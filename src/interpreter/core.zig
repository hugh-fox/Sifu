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

/// Recurse into nested expressions. Two cases must be distinguished:
///
///  - Structural recursion (form 2), e.g. `(x, *xs) -> x, (*xs)`: the
///    nested expression is strictly *smaller* than the pattern that was
///    matched, so progress is guaranteed and the producing rule may fire
///    again. The recursive call may match up to and including the current
///    index, so its upper bound is `structural_upper`.
///
///  - Nested recursion (form 3), e.g. `A -> (A)`: the nested expression
///    is the *same* size, just wrapped one level deeper. Reusing the
///    producing rule would loop forever, so the recursive call must match
///    strictly before the current index, giving an upper bound of `nested_upper`.
///
/// The two are told apart by comparing the nested node's height (which
/// includes its own nesting level) against the matched pattern's height,
/// measured the same way.
pub fn evaluateNested(
    trie: Trie,
    allocator: Allocator,
    pattern_height: usize,
    structural_upper: usize,
    nested_upper: usize,
    current: Pattern,
) Allocator.Error!Eval {
    const result = current;
    for (result.root, 0..) |*nested, i| switch (nested.*) {
        inline else => |sub_pattern, tag| if (@TypeOf(sub_pattern) == Pattern) {
            var content_height: usize = 0;
            for (sub_pattern.root) |node|
                content_height = @max(content_height, node.height());
            const inner = Pattern{ .root = sub_pattern.root, .height = content_height };
            const is_smaller = content_height < pattern_height;
            const recurse_upper = if (is_smaller) structural_upper else nested_upper;
            debug("Nested recurse [{d}] tag={s} content_h={d} pat_h={d} upper={d}", .{
                i, @tagName(tag), content_height, pattern_height, recurse_upper,
            });
            const nested_eval = try evaluateBounded(
                trie,
                allocator,
                .{ .lower = 0, .upper = recurse_upper },
                inner,
            );
            var new_value = nested_eval.value orelse try inner.copy(allocator);
            new_value.height += 1;
            @constCast(&sub_pattern).deinit(allocator);
            nested.* = @unionInit(Node, @tagName(tag), new_value);
        },
    };
    return Eval{ .value = result };
}

/// Main match loop with structural recursion. Iterates through rules
/// bottom-up by index, applying rewrites. When height decreases
/// (structural recursion), recursively evaluates with the same rule set.
/// Otherwise continues with increasing index to prevent infinite loops.
fn evaluateBottomUp(
    trie: Trie,
    allocator: Allocator,
    bound: Bound,
    pattern: Pattern,
) Allocator.Error!Eval {
    var index: usize = bound.lower;
    const upper = bound.upper;
    var current: Pattern = try pattern.copy(allocator);
    var last_index: usize = upper;
    var last_len: usize = 0;

    while (index < upper) {
        const step = try evaluateMatch(trie, allocator, .{ .lower = index, .upper = upper }, current);
        if (step.index < index)
            panic("Match index bug: step.index {} < index {}", .{ step.index, index });

        index = step.index + 1;

        const rewritten = step.value orelse {
            debug("Eval, no match", .{});
            index = upper;
            break;
        };

        last_index = step.index;
        last_len = step.len;

        var old_current = current;
        defer old_current.deinit(allocator);

        const is_structural = pattern.height > rewritten.height;
        debug(
            "is_structural: current {} > rewritten {}",
            .{ current.height, rewritten.height },
        );

        if (is_structural) {
            const rewritten_eval = try evaluateBounded(
                trie,
                allocator,
                .{ .lower = bound.lower, .upper = step.index + 1 },
                rewritten,
            );
            if (rewritten_eval.value) |val| {
                var rewritten_mut = rewritten;
                rewritten_mut.deinit(allocator);
                return Eval{
                    .value = val,
                    .index = step.index,
                    .len = step.len,
                };
            } else {
                current = rewritten;
            }
        } else {
            current = rewritten;
        }

        debug("Next eval index: {}\n", .{index});
    }

    return if (last_index < upper) .{
        .value = current,
        .index = last_index,
        .len = last_len,
    } else blk: {
        current.deinit(allocator);
        break :blk .{
            .value = null,
            .index = upper,
            .len = 0,
        };
    };
}

pub fn evaluateBounded(
    trie: Trie,
    allocator: Allocator,
    bound: Bound,
    pattern: Pattern,
) Allocator.Error!Eval {
    const bottom_up = try evaluateBottomUp(trie, allocator, bound, pattern);
    var current = bottom_up.value orelse try pattern.copy(allocator);
    const last_index = bottom_up.index;
    const last_len = bottom_up.len;

    current = try evaluateLHS(trie, allocator, bound, current);

    const structural_upper = if (bottom_up.value) |_| last_index + 1 else bound.upper;
    const nested_upper = if (bottom_up.value) |_| last_index else bound.upper;
    const nested_eval = try evaluateNested(trie, allocator, pattern.height, structural_upper, nested_upper, current);
    current = nested_eval.value orelse current;

    const eval = Eval{
        .value = current,
        .index = last_index,
        .len = last_len,
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
fn evaluateLHS(
    trie: Trie,
    allocator: Allocator,
    bound: Bound,
    current: Pattern,
) Allocator.Error!Pattern {
    var result = try current.evaluate(allocator, pure.step);
    @constCast(&current).deinit(allocator);

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
            trie,
            allocator,
            .{ .lower = 0, .upper = bound.upper },
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
    return result;
}
