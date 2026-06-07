/// Evaluator for string values.
///
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Node = @import("../sifu/node.zig").Node;
const Pattern = @import("../sifu/pattern.zig").Pattern;

/// The infix operator denoting string concatenation. It is deliberately
/// distinct from arithmetic `+` so that folding string output never collides
/// with the `+` expressions the compiler translates.
pub const concat_op = "++";

/// One string-evaluation step on a single pattern level: if the level is a
/// top-level `+` concatenation (`operand (+ operand)*`) of foldable operands,
/// fold it into a single string literal; otherwise return the level unchanged.
/// Recursion into nested patterns is the driver's job (`Pattern.evaluate`), so
/// nested concatenations are already folded by the time this runs at a level.
///
/// Always returns an owned pattern; free it with `deinit`. The bytes of any
/// computed literal are allocated from `allocator` and outlive the call (they
/// are not freed by `deinit`, matching how the interpreter treats key text), so
/// drive this with an arena or otherwise own those bytes.
pub fn step(pattern: Pattern, allocator: Allocator) Allocator.Error!Pattern {
    // A top-level concatenation looks like `operand (+ operand)*`, i.e. the
    // second node is a `+` infix. Fold the whole root into one literal.
    if (pattern.root.len >= 2 and isConcat(pattern.root[1])) {
        var acc = ArrayList(u8).empty;
        errdefer acc.deinit(allocator);
        if (try appendRoot(&acc, pattern.root, allocator)) {
            const literal = try quote(allocator, acc.items);
            acc.deinit(allocator);
            const root = try allocator.alloc(Node, 1);
            root[0] = .{ .key = literal };
            return .{ .root = root, .height = 0 };
        }
        // Not all operands were foldable (e.g. an unbound variable); leave the
        // expression intact.
        acc.deinit(allocator);
    }

    return pattern.copy(allocator);
}

/// True if `node` is a `+` infix operation.
fn isConcat(node: Node) bool {
    return node == .infix and std.mem.eql(u8, node.infix.op, concat_op);
}

/// Appends the concatenated content of a node sequence of the form
/// `operand (+ operand)*` to `acc`. Returns false (leaving `acc`'s prior
/// contents in place) when the sequence is not a foldable concatenation.
fn appendRoot(acc: *ArrayList(u8), root: []const Node, allocator: Allocator) Allocator.Error!bool {
    if (root.len == 0) return true;
    if (!try appendOperand(acc, root[0], allocator)) return false;

    var i: usize = 1;
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
        .key => |key| {
            try acc.appendSlice(allocator, unquote(key));
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
const core = @import("core.zig");

/// Parses `source`, folds strings, and returns the printed result. Uses the
/// caller's arena so computed literals are reclaimed in bulk.
fn evalToString(allocator: Allocator, source: []const u8) ![]const u8 {
    const pattern = try Parser.parse(allocator, source);
    const folded = try pattern.evaluate(allocator, step);
    return folded.toString(allocator);
}

test "evaluateString: concatenate two string literals" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try evalToString(arena.allocator(), "\"i32.\" ++ \"const\"");
    try testing.expectEqualStrings("\"i32.const\"", out);
}

test "evaluateString: concatenate a chain" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try evalToString(arena.allocator(), "\"a\" ++ \"b\" ++ \"c\"");
    try testing.expectEqualStrings("\"abc\"", out);
}

test "evaluateString: concatenate string with a number" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try evalToString(arena.allocator(), "\"i32.const \" ++ 42");
    try testing.expectEqualStrings("\"i32.const 42\"", out);
}

test "evaluateString: parenthesized operand folds and unwraps" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try evalToString(arena.allocator(), "\"x\" ++ (\"y\" ++ \"z\")");
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
    // `x` has no value here, so the concatenation must be left intact.
    const out = try evalToString(arena.allocator(), "\"i32.const \" ++ x");
    try testing.expectEqualStrings("\"i32.const \" ++ x", out);
}

test "I32-Const rule rewrites to a mnemonic string" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const trie = try Parser.parseTrie(allocator, "I32-Const -> \"i32.const\"");
    const query = try Parser.parse(allocator, "I32-Const");
    const eval = try core.evaluateComplete(trie, allocator, 0, query);
    const value = eval.value orelse return error.NoEvalResult;
    const out = try value.toString(allocator);
    try testing.expectEqualStrings("\"i32.const\"", out);
}

test "rule + concat assembles an instruction" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // A rule emits the mnemonic plus its operand as a concatenation; the
    // string evaluator then folds it into finished instruction text. The rule
    // uses `-->` (lower precedence than the `++` infix) so the whole
    // concatenation is the rewrite value, not just the first literal.
    const trie = try Parser.parseTrie(allocator, "Const x --> \"i32.const \" ++ x");
    const query = try Parser.parse(allocator, "Const 42");
    const eval = try core.evaluateComplete(trie, allocator, 0, query);
    const rewritten = eval.value orelse return error.NoEvalResult;

    const folded = try rewritten.evaluate(allocator, step);
    const out = try folded.toString(allocator);
    try testing.expectEqualStrings("\"i32.const 42\"", out);
}
