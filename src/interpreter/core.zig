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
    term_bindings: *VarBindings,
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
        inline .pattern, .arrow, .match, .list, .infix => |nested, tag| {
            const rewritten = try rewrite(allocator, nested, term_bindings);
            const wrapped = Pattern{ .root = rewritten.root, .height = rewritten.height + 1 };
            max_child = @max(max_child, wrapped.height);
            try result.append(allocator, @unionInit(Node, @tagName(tag), wrapped));
        },
        else => panic("unimplemented", .{}),
    };

    const nodes = try result.toOwnedSlice(allocator);
    return Pattern{ .root = nodes, .height = max_child };
}

pub fn evaluateComplete(
    trie: Trie,
    allocator: Allocator,
    lower_bound: usize,
    pattern: Pattern,
) Allocator.Error!Eval {
    return evaluateBounded(trie, allocator, .{ .lower = lower_bound, .upper = trie.size() }, pattern);
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

/// Evaluate the head (LHS) of a pattern. When the result is a list/op
/// (a non-list prefix followed by a top-level comma `,` list node), the
/// complete-match loop cannot reduce the prefix on its own because the
/// trailing comma prevents the whole pattern from matching any rule, and
/// the nested-recursion loop only descends into wrapper nodes. Reduce the
/// prefix here as its own sub-pattern, e.g. the head `F 1` of `F 1, (2, 3)`
/// reduces to `G 1`. Returns `current` unchanged if there is no reducible
/// head; otherwise the old root is freed and a new one is returned.
///
/// Also evaluates match operators (`:`) via Pattern.evaluatePure.
fn evaluateLHS(
    trie: Trie,
    allocator: Allocator,
    bound: Bound,
    current: Pattern,
) Allocator.Error!Pattern {
    var result = try current.evaluatePure(allocator);
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
