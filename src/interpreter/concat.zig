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


    /// The first half of evaluation with backtracking. The variables in the node match
    /// anything in the trie, and vars in the trie match anything in
    /// the expression. Includes partial prefixes (ones that don't match all
    /// pattern). This function returns any trie branches, even if their
    /// value is null, unlike `match`. The position defines the index where
    /// allowable matches begin. As a trie is matched, a hashmap for vars
    /// is populated with each var's bound variable. These can the be used
    /// by the caller for rewriting.
    /// - Any node matches a var trie including a var (the var node is
    ///   then stored in the var map like any other node)
    /// - A var node doesn't match a non-var trie (var matching is one
    ///   way)
    /// - A literal node that matches a trie of both literals and vars
    /// matches the literal part, not the var
    /// Returns a nullable struct describing a successful match containing:
    /// - the value for that match in the trie
    /// - the minimum index a subsequent match should use, which is one
    /// greater than the previous (except for structural recursion).
    /// - null if no match
    /// Time Complexity: O(mlogn) where m is the key len and n is the size of the trie.
    /// Returns a trie of the subset of branches that matches `node`. Caller
    /// owns the trie returned, but it is a shallow copy and thus cannot be
    /// freed with destroy/deinit without freeing references in self.
    // Add this struct near the top with other Match/Eval structs

    /// Finds all possible branches that could match the given node at or after
    /// bound.
    /// Returns a queue of all candidate matches with their indices, branches,
    /// and updated bindings.
    fn matchAllTerms(
        self: *const Trie,
        // allocator: Allocator,
        // bound: usize,
        // bindings: VarBindings,
        // node: Node,
    ) Allocator.Error!MatchQueue {
        _ = self;
        @panic("unimplemented\n");
    }

    const MatchQueue = std.PriorityQueue(Trie.IndexBranchTrie);
