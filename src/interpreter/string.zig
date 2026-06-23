/// Evaluator for string values.
///
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Node = @import("../sifu/node.zig").Node;
const Pattern = @import("../sifu/pattern.zig").Pattern;

pub const concat_op = "+";

/// Placeholder; memory allocation is not handled.
pub fn step(pattern: Pattern, allocator: Allocator) Allocator.Error!?Pattern {
    // A top-level concatenation looks like `operand (+ operand)*`. A string
    // operand decomposes into several `.char` nodes, so the `+` infix can appear
    // at any position. Only fold when at least one operand is a string (has a
    // `.char`): otherwise a plain juxtaposition like `A + B C` would be folded
    // into a string, which it is not.
    if (hasConcat(pattern.root) and hasChar(pattern.root)) {
        var acc = ArrayList(u8).empty;
        errdefer acc.deinit(allocator);
        // TODO: improve this, should never need a `quote` function
        if (try appendRoot(&acc, pattern.root, allocator)) {
            const literal = try quote(allocator, acc.items);
            acc.deinit(allocator);
            const root = try allocator.alloc(Node, 1);
            root[0] = .{ .constant = literal };
            return .{ .root = root, .height = 0 };
        }
        // Not all operands were foldable (e.g. an unbound variable); leave the
        // expression intact.
        acc.deinit(allocator);
    }

    return null;
}

/// True if `node` is a `+` infix operation.
fn isConcat(node: Node) bool {
    return node == .infix and std.mem.eql(u8, node.infix.op, concat_op);
}

/// True if any node in the sequence is a `+` infix operation.
fn hasConcat(root: []const Node) bool {
    for (root) |node| if (isConcat(node)) return true;
    return false;
}

/// True if any node in the sequence (or a `+`-operand under it) is a string
/// character, marking the expression as a string concatenation.
fn hasChar(root: []const Node) bool {
    for (root) |node| switch (node) {
        .char => return true,
        .pattern => |sub| if (hasChar(sub.root)) return true,
        .infix => |inf| if (isConcat(node) and hasChar(inf.rhs.root)) return true,
        else => {},
    };
    return false;
}

/// Appends the concatenated content of a node sequence of the form
/// `operand (+ operand)*` to `acc`. Returns false (leaving `acc`'s prior
/// contents in place) when the sequence is not a foldable concatenation.
fn appendRoot(acc: *ArrayList(u8), root: []const Node, allocator: Allocator) Allocator.Error!bool {
    if (root.len == 0) return true;

    // The first operand is the leading run of plain nodes (string literals
    // decompose into one constant node per character, so a single operand can
    // span several nodes) up to the first `+` infix.
    var i: usize = 0;
    while (i < root.len and !isConcat(root[i])) : (i += 1) {
        if (!try appendOperand(acc, root[i], allocator)) return false;
    }

    while (i < root.len) : (i += 1) {
        if (!isConcat(root[i])) return false;
        // The operands are the infix node's rhs pattern.
        if (!try appendRoot(acc, root[i].infix.rhs.root, allocator)) return false;
    }
    return true;
}

/// Appends a single operand's textual content to `acc`, or returns false if the
/// operand is not foldable (e.g. an unbound variable or an operator node).
fn appendOperand(acc: *ArrayList(u8), node: Node, allocator: Allocator) Allocator.Error!bool {
    switch (node) {
        // A string character contributes its source bytes directly.
        .char => |c| {
            try acc.appendSlice(allocator, c);
            return true;
        },
        // A plain constant (e.g. a number operand like `42`) contributes its
        // text, with any surrounding quotes stripped.
        .constant => |constant| {
            try acc.appendSlice(allocator, unquote(constant));
            return true;
        },
        .pattern => |sub| return appendRoot(acc, sub.root, allocator),
        else => return false,
    }
}

/// Strips a single pair of surrounding double quotes, if present.
fn unquote(text: []const u8) []const u8 {
    if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"')
        return text[1 .. text.len - 1];
    return text;
}

/// Wraps `content` in double quotes, returning freshly allocated bytes.
fn quote(allocator: Allocator, content: []const u8) Allocator.Error![]u8 {
    const out = try allocator.alloc(u8, content.len + 2);
    out[0] = '"';
    @memcpy(out[1 .. 1 + content.len], content);
    out[out.len - 1] = '"';
    return out;
}

// Tests

const testing = std.testing;
const ArenaAllocator = std.heap.ArenaAllocator;
const Parser = @import("../Parser.zig");
const core = @import("../interpreter.zig");

/// Parses `source`, folds strings, and returns the printed result. Uses the
/// caller's arena so computed literals are reclaimed in bulk.
fn evalToString(allocator: Allocator, source: []const u8) ![]const u8 {
    const pattern = try Parser.parse(allocator, source);
    const folded = try core.evaluateStrings(allocator, pattern);
    return folded.toString(allocator);
}

test "evaluateString: concatenate two string literals" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try evalToString(arena.allocator(), "\"i32.\" + \"const\"");
    try testing.expectEqualStrings("\"i32.const\"", out);
}

test "evaluateString: concatenate a chain" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try evalToString(arena.allocator(), "\"a\" + \"b\" + \"c\"");
    try testing.expectEqualStrings("\"abc\"", out);
}

test "evaluateString: concatenate string with a number" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try evalToString(arena.allocator(), "\"i32.const \" + 42");
    try testing.expectEqualStrings("\"i32.const 42\"", out);
}

test "evaluateString: parenthesized operand folds and unwraps" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try evalToString(arena.allocator(), "\"x\" + (\"y\" + \"z\")");
    try testing.expectEqualStrings("\"xyz\"", out);
}

test "evaluateString: non-concat expression is unchanged" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try evalToString(arena.allocator(), "A B");
    try testing.expectEqualStrings("A B", out);
}

test "evaluateString: unbound variable is not foldable" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // `x` has no value here, so the concatenation must be left intact. The
    // string literal decomposes into characters that print adjacently, so it
    // reads back as `i32.const ` (trailing space character preserved) `+ x`.
    const out = try evalToString(arena.allocator(), "\"i32.const \" + x");
    try testing.expectEqualStrings("i32.const  + x", out);
}

test "I32-Const rule rewrites to a mnemonic string" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const trie = try Parser.parseTrie(allocator, "I32-Const -> \"i32.const\"");
    const query = try Parser.parse(allocator, "I32-Const");
    const value = try core.evaluateComplete(trie, allocator, query) orelse
        return error.NoEvalResult;
    const out = try value.toString(allocator);
    // Without a `+` concatenation to fold, the literal stays as its individual
    // characters, which print adjacently and read back as `i32.const`.
    try testing.expectEqualStrings("i32.const", out);
}

test "rule + concat assembles an instruction" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // A rule emits the mnemonic plus its operand as a concatenation; the
    // string evaluator then folds it into finished instruction text. The rule
    // uses `-->` (lower precedence than the `++` infix) so the whole
    // concatenation is the rewrite value, not just the first literal.
    const trie = try Parser.parseTrie(allocator, "Const x --> \"i32.const \" + x");
    const query = try Parser.parse(allocator, "Const 42");
    const rewritten = try core.evaluateComplete(trie, allocator, query) orelse
        return error.NoEvalResult;

    const folded = try core.evaluateStrings(allocator, rewritten);
    const out = try folded.toString(allocator);
    try testing.expectEqualStrings("\"i32.const 42\"", out);
}
