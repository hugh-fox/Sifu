/// Comment removal: strip `.comment` nodes from a pattern.
///
/// Comments, like everything else, are preserved as nodes by the parser. This
/// evaluator drops every
/// comment node (recursing into nested patterns) so the result can be matched,
/// rewritten and stored in a trie without comments interfering. Non-Trie
/// specific: it operates purely on patterns.
///
const std = @import("std");
const Allocator = std.mem.Allocator;

const Node = @import("../sifu/node.zig").Node;
const Pattern = @import("../sifu/pattern.zig").Pattern;

/// One comment-stripping step on a single pattern level: drop every
/// `.comment` node at this level, copying the rest. Nested patterns are
/// handled by the driver (`core.evaluate`), which applies this step at
/// every level, so comments are removed throughout.
///
/// As a `pure.Step`: returns null when this level has no comment to drop (so
/// the driver's fixpoint loop terminates), otherwise an owned pattern.
pub fn step(pattern: Pattern, allocator: Allocator) Allocator.Error!?Pattern {
    var dropped = false;
    for (pattern.root) |node| {
        if (node == .comment) {
            dropped = true;
            break;
        }
    }
    if (!dropped) return null;

    var result = std.ArrayList(Node).empty;
    errdefer {
        for (result.items) |*n| n.deinit(allocator);
        result.deinit(allocator);
    }
    for (pattern.root) |node| {
        if (node == .comment)
            continue;
        // The driver frees the input pattern after this step returns, so each
        // retained node must be an owned deep copy, not an alias.
        try result.append(allocator, try node.copy(allocator));
    }

    return .{ .root = try result.toOwnedSlice(allocator), .height = pattern.height };
}

/// One whitespace-collapse step on a single pattern level. Whitespace
/// separators (`.newline`/`.indent`) carry layout only; after comments are gone
/// they can leave empty entries (a comment-only line, or a leading/trailing
/// newline). Collapse those so the residual pattern matches as if the layout
/// weren't there. Run as a separate pass *after* comment removal so emptied
/// separators are visible (the top-down driver settles a level before its
/// children, so a separator emptied by a nested comment is only seen on a later
/// pass). A separator is always the last node at its level (right associative),
/// so a sole separator means an empty leading entry.
pub fn whitespaceStep(pattern: Pattern, allocator: Allocator) Allocator.Error!?Pattern {
    const root = pattern.root;
    if (root.len == 1) {
        switch (root[0]) {
            .newline, .indent => |sep| return try sep.rhs.copy(allocator),
            else => {},
        }
    }
    if (root.len == 0) return null;

    const empty_tail = switch (root[root.len - 1]) {
        .newline, .indent => |sep| sep.rhs.root.len == 0,
        else => false,
    };
    if (!empty_tail) return null;

    var result = std.ArrayList(Node).empty;
    errdefer {
        for (result.items) |*n| n.deinit(allocator);
        result.deinit(allocator);
    }
    for (root[0 .. root.len - 1]) |node|
        try result.append(allocator, try node.copy(allocator));
    return .{ .root = try result.toOwnedSlice(allocator), .height = pattern.height };
}

const testing = std.testing;
const Parser = @import("../Parser.zig");
const core = @import("../interpreter.zig");

fn expectStripped(src: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parsed = try Parser.parse(allocator, src);
    const stripped = try core.evaluateComments(allocator, parsed);
    const str = try stripped.toString(allocator);
    try testing.expectEqualStrings(expected, str);
}

test "evaluateComments: trailing comment removed" {
    try expectStripped("A # a comment", "A");
}

test "evaluateComments: comment inside arrow value removed" {
    try expectStripped("A -> B # c", "A -> B");
}

test "evaluateComments: leading comment removed" {
    try expectStripped("# heading\nA B", "A B");
}

test "evaluateComments: no comments is identity" {
    try expectStripped("A -> B", "A -> B");
}
