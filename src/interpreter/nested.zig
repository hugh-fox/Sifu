//! The nested-recursion evaluation mode (Evaluation.md §3).
//!

const std = @import("std");
const Allocator = std.mem.Allocator;

const Node = @import("../sifu/node.zig").Node;
const Pattern = @import("../sifu/pattern.zig").Pattern;
const trie_module = @import("../sifu/trie.zig");
const Trie = trie_module.Trie;
const Bound = trie_module.Bound;

const core = @import("../interpreter.zig");
const contentHeight = core.contentHeight;
const lower = @import("lower.zig");

/// The upper bound for a nested descent: strictly below the parent's match so a
/// rule cannot re-fire itself. The shared `bound` has already had its lower
/// raised past the match (`lower = index + 1`), so `lower - 1` is that match
/// index, the exclusive upper for a nested sub-term.
pub fn descendUpper(bound: Bound) usize {
    return bound.lower - 1;
}

/// Reduce the head of a top-level list operator in place. When `current` holds a
/// list operator whose prefix (the head) is a sub-expression no whole rule
/// consumed, evaluate that head on its own against `trie` and splice the result
/// back ahead of the tail. The tail stays put — it is the nested list child the
/// driver recurses into separately. A head that doesn't reduce is left as-is.
/// Mutates `current`; the caller owns it and frees it on error.
pub fn head(
    allocator: Allocator,
    trie: Trie,
    modes: []const core.Mode,
    upper: usize,
    current: *Pattern,
) Allocator.Error!void {
    const list_pos = lower.firstList(current.root) orelse return;
    const old_head = Pattern{
        .root = current.root[0..list_pos],
        .height = contentHeight(current.root[0..list_pos]),
    };
    var head_it = core.EvalEvaluator{
        .allocator = allocator,
        .current = try old_head.copy(allocator),
        .ctx = .{ .trie = trie, .bound = .{ .lower = 0, .upper = upper }, .modes = modes },
    };
    errdefer head_it.deinit();
    var reduced = try head_it.next();
    if (reduced.eql(old_head)) {
        reduced.deinit(allocator);
        return;
    }
    const tail = current.root[list_pos..];
    const spliced = try allocator.alloc(Node, reduced.root.len + tail.len);
    @memcpy(spliced[0..reduced.root.len], reduced.root);
    @memcpy(spliced[reduced.root.len..], tail);
    for (current.root[0..list_pos]) |*node| @constCast(node).deinit(allocator);
    allocator.free(current.root);
    allocator.free(reduced.root);
    current.root = spliced;
}

/// Re-attempt a just-reduced wrapped term (`node`) one level up so a rule that
/// matches only the enclosing form — e.g. `(x) -> x` — can fire. Matches from
/// `from`, the lower bound the term's contents already reached, so an exhausted
/// cycle (e.g. `(A) -> A` / `A -> (A)`) is not re-entered. Returns the
/// replacement node when the term collapses to a single node, else null.
/// Terminates because such a rule's rhs drops a nesting level.
pub fn lift(
    trie: Trie,
    modes: []const core.Mode,
    upper: usize,
    node: Node,
    from: usize,
    allocator: Allocator,
) Allocator.Error!?Node {
    if (node != .pattern) return null;
    var term_root = [_]Node{node};
    const term = Pattern{ .root = &term_root, .height = node.height() };
    var it = core.EvalEvaluator{
        .allocator = allocator,
        .current = try term.copy(allocator),
        .ctx = .{ .trie = trie, .bound = .{ .lower = from, .upper = upper }, .modes = modes },
    };
    defer it.deinit();
    while (try it.step()) |_| {}
    if (it.current.eql(term) or it.current.root.len != 1) return null;
    return try it.current.root[0].copy(allocator);
}

/// Re-settle `current` after a `lift` removed a nesting level, in case a match
/// at this level is now possible (e.g. an application whose argument just became
/// a constant). Settles only — it does not descend again, which is bound-limited
/// per level. Takes ownership of `current` and returns the settled level.
pub fn resettle(
    trie: Trie,
    modes: []const core.Mode,
    bound: Bound,
    current: Pattern,
    allocator: Allocator,
) Allocator.Error!Pattern {
    var it = core.EvalEvaluator{
        .allocator = allocator,
        .current = current,
        .ctx = .{ .trie = trie, .bound = bound, .modes = modes },
    };
    errdefer it.deinit();
    while (try it.step()) |_| {}
    const settled = it.current;
    it.current = .{};
    return settled;
}
