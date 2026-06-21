//! Numeric recursion: re-fire the matched rule on a rewritten sub-term as long
//! as that same rule is still the lowest one matching it. This terminates a
//! counting rule like `replicate` without measuring numbers directly:
//!   replicate 0 *x -->
//!   replicate n *x --> *x, replicate (n - 1) *x
//! the shrinking `(n - 1)` sub-call keeps re-firing the same rule until it
//! reaches the base case (`replicate 0`); then the earlier rule becomes the
//! lowest match and recursion defers to it — re-firing would skip it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Node = @import("../sifu/node.zig").Node;
const trie_module = @import("../sifu/trie.zig");
const Trie = trie_module.Trie;
const Bound = trie_module.Bound;
const Pattern = trie_module.Pattern;
const VarBindings = trie_module.VarBindings;

/// The upper bound for a numeric descent: re-fire the matched rule (re-include
/// `bound.lower`) on `sub`, but only while the matched rule is still the lowest
/// rule that completely matches it *and* an earlier rule exists to converge to.
/// An earlier rule matching means recursion has reached a base case — return null
/// so the caller defers to it (via the nested descent); no earlier rule (matched
/// at index 0) or no match at all also returns null, ending the recursion.
/// `bound.lower` is `matched_index + 1`, so the matched rule lives at
/// `bound.lower - 1` and `[0, bound.lower)` spans it and every earlier rule.
pub fn descendUpper(
    active: bool,
    trie: Trie,
    bound: Bound,
    sub: Pattern,
    allocator: Allocator,
) Allocator.Error!?usize {
    if (!active) return null;
    const matched = bound.lower - 1;
    if (matched == 0) return null;
    var bindings = VarBindings{};
    defer bindings.deinit(allocator);
    var match = try trie.match(allocator, .{ .lower = 0, .upper = bound.lower }, &bindings, sub);
    defer match.deinit(allocator);
    const complete = match.value != null and match.len == sub.root.len;
    return if (complete and match.match_index == matched) bound.lower else null;
}
