//! Concatenative evaluation: follow a pattern in a trie until no matches.
//!
//! Performs a partial but exhaustive match (keeps evaluating any results of the
//! query) and if possible a rewrite. Starts matching between [lower, upper)
//! bounds, shrinking the upper bound to each matched value's index. If nothing
//! matches, then the original pattern is returned unchanged.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const debug = std.log.debug;

const Node = @import("../sifu/node.zig").Node;
const Pattern = @import("../sifu/pattern.zig").Pattern;
const trie_module = @import("../sifu/trie.zig");
const Trie = trie_module.Trie;
const Bound = trie_module.Bound;
const VarBindings = trie_module.VarBindings;

const core = @import("core.zig");

pub fn evaluateSlice(
    trie: Trie,
    allocator: Allocator,
    pattern: Pattern,
    result: *ArrayList(Node),
) Allocator.Error!Pattern {
    _ = result;
    var bound: Bound = .{ .upper = trie.size() };
    var total_matched: usize = 0;
    var matched: Trie.Match = .{ .index = 0 };
    var term_bindings = VarBindings{};
    defer term_bindings.deinit(allocator);
    while (matched.match_index < bound.upper) : (bound.upper = matched.match_index) {
        debug("Matching from bounds [{},{})", .{ bound.lower, bound.upper });
        matched = try trie.match(allocator, bound, &term_bindings, pattern);
        defer matched.deinit(allocator);
        debug(
            "Match result: {} of {} pattern nodes at index {}, ",
            .{ matched.len, pattern.root.len, matched.match_index },
        );
        if (matched.value) |value| {
            debug("matched value: {}", .{value});
            return try core.rewrite(allocator, value, &term_bindings);
        } else debug("but no match", .{});
        total_matched += matched.len;
        if (total_matched < pattern.root.len)
            break;
    }
    return try pattern.copy(allocator);
}
