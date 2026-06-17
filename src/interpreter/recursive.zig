//! Recursive evaluation at the same index (Evaluation.md §2).
//!

const Bound = @import("../sifu/trie.zig").Bound;

fn isShrinking(content_height: usize, pattern_height: usize) bool {
    return content_height < pattern_height;
}

pub fn descendUpper(active: bool, bound: Bound, content_height: usize, pattern_height: usize) ?usize {
    if (!isShrinking(content_height, pattern_height)) return null;
    return if (active) bound.lower else 0;
}
