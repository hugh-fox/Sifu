/// Decomposes a quoted string literal into its individual characters, shared by
/// both the recursive-descent parser (`Parser.zig`) and the tree-sitter AST
/// converter (`tree_sitter_parser.zig`) so they produce identical patterns.
///
/// Each character becomes its own `.char` node whose text is the source bytes
/// spelling that character: a UTF-8 codepoint, or an escape sequence (`\"`,
/// `\'`, `\\`, ...) kept intact. The surrounding quotes are dropped. No memory
/// is allocated for the character text; each node points into the original
/// token, so both parsers agree byte-for-byte. Char nodes (as opposed to plain
/// `.constant` keys) print adjacently and let the string evaluator recognise a
/// string, keeping whitespace significant.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Node = @import("node.zig").Node;

/// Appends one `.char` node per character of `token` (a quoted string literal,
/// including its surrounding quotes) to `nodes`.
pub fn appendStringChars(
    allocator: Allocator,
    nodes: *ArrayList(Node),
    token: []const u8,
) Allocator.Error!void {
    // A malformed token without both quotes is kept whole rather than dropped.
    if (token.len < 2) {
        try nodes.append(allocator, .{ .char = token });
        return;
    }
    const inner = token[1 .. token.len - 1];
    var i: usize = 0;
    while (i < inner.len) {
        const start = i;
        if (inner[i] == '\\' and i + 1 < inner.len) {
            i += 2; // escape sequence: backslash plus the escaped byte
        } else {
            const len = std.unicode.utf8ByteSequenceLength(inner[i]) catch 1;
            i = @min(i + len, inner.len);
        }
        try nodes.append(allocator, .{ .char = inner[start..i] });
    }
}
