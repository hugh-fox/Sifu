//! Built-in evaluator for numeric expressions.
//!
//! Non-Trie-specific: it operates purely on patterns and ignores the
//! evaluation context, so it works with any context type. Currently a no-op
//! placeholder; it will eventually fold arithmetic over matched number
//! literals.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Pattern = @import("../sifu/pattern.zig").Pattern;
const Trie = @import("../sifu/trie.zig").Trie;

pub fn evaluateMath(trie: *const Trie, pattern: Pattern) Allocator.Error!?Pattern {
    _ = trie;
    _ = pattern;
    return null;
}
