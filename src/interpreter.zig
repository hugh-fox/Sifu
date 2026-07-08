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

fn evaluate(trie: *Trie) Allocator.Error!Pattern {
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

// pub fn evaluateComplete(
//     trie: Trie,
//     allocator: Allocator,
//     pattern: Pattern,
// ) Allocator.Error!?Pattern {
//     // Strip comments from the query so they never reach matching or output.
//     var stripped = try evaluateComments(allocator, pattern);
//     defer stripped.deinit(allocator);

//     // Trie-driven match/rewrite evaluation. Each mode is its own pass, chained
//     // by `evaluateModes`; drop a mode or reorder to mix and match.
//     var evaluated = try evaluateModes(trie, allocator, stripped, &.{
//         .lower, // §1: match at the index, then raise the lower bound past it
//         .recursive, // §2: recurse at the same index on shrinking sub-terms
//         .numeric, // §2 on values: recurse at the same index on shrinking numbers
//         .nested, // §3: descend strictly below the index (e.g. list heads)
//     });
//     defer evaluated.deinit(allocator);

//     // Fold any arithmetic expressions in the result.
//     var folded_math = try evaluateMath(allocator, evaluated);
//     defer folded_math.deinit(allocator);

//     // Fold any string concatenations in the result.
//     return try evaluateStrings(allocator, folded_math);
// }

// const testing = std.testing;
// const ArenaAllocator = std.heap.ArenaAllocator;
// const Parser = @import("Parser.zig");

// fn expectEval(allocator: Allocator, trie: Trie, query_str: []const u8, expected_str: []const u8) !void {
//     var query = try Parser.parse(allocator, query_str);
//     defer query.deinit(allocator);
//     if (try evaluateComplete(trie, allocator, query)) |*val| {
//         defer @constCast(val).deinit(allocator);
//         var expected = try Parser.parse(allocator, expected_str);
//         defer expected.deinit(allocator);
//         if (!val.eql(expected)) {
//             const result_str = try val.toString(allocator);
//             defer allocator.free(result_str);
//             try testing.expectEqualStrings(expected_str, result_str);
//         }
//     } else {
//         return error.NoEvalResult;
//     }
// }
