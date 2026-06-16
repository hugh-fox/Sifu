//! Built-in evaluator for numeric expressions.
//!
//! Folds a top-level arithmetic infix chain of integer literals into a single
//! integer literal. Non-Trie-specific: it operates purely on patterns, mirroring
//! the other single-level `step` evaluators (`string.zig`, `comments.zig`,
//! `pure.zig`) driven by `core.evaluate`.
//!
//! Operators: `+ - * /`. The parser emits arithmetic as a single flat,
//! left-associative infix chain at one precedence level (`[operand, infix, ...]`,
//! each infix's rhs a single operand), so evaluation is left-associative and
//! there is *no* operator precedence: `1 + 2 * 3` folds as `(1 + 2) * 3 = 9`.
//! This is a known limitation of this MVP.
//!
//! Returns null when nothing folded; otherwise an owned single-literal pattern.
//! The bytes of any computed literal are allocated from the passed allocator and outlive the call (they
//! are not freed by `deinit`, matching how the interpreter treats constant text), so
//! drive this with an arena or otherwise own those bytes.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Node = @import("../sifu/node.zig").Node;
const Pattern = @import("../sifu/pattern.zig").Pattern;

/// One math-evaluation step on a single pattern level: if the level is a
/// top-level arithmetic chain (`operand (op operand)*`) of foldable integer
/// operands, fold it into a single integer literal; otherwise return the level
/// unchanged. Recursion into nested patterns is the driver's job
/// (`core.evaluate`), so nested expressions are already folded by the time
/// this runs at a level.
pub fn step(pattern: Pattern, allocator: Allocator) Allocator.Error!?Pattern {
    // A top-level arithmetic chain looks like `operand (op operand)*`, i.e. the
    // second node is a math infix. Fold the whole root into one literal.
    if (pattern.root.len >= 2 and isMathOp(pattern.root[1])) {
        if (foldRoot(pattern.root)) |value| {
            const literal = try std.fmt.allocPrint(allocator, "{d}", .{value});
            const root = try allocator.alloc(Node, 1);
            root[0] = .{ .constant = literal };
            return .{ .root = root, .height = 0 };
        }
        // Not all operands were foldable (e.g. an unbound variable, or a
        // division by zero); leave the expression intact.
    }

    return null;
}

/// True if `node` is one of the `+ - * /` infix operations.
fn isMathOp(node: Node) bool {
    if (node != .infix) return false;
    const op = node.infix.op;
    if (op.len != 1) return false;
    return switch (op[0]) {
        '+', '-', '*', '/' => true,
        else => false,
    };
}

/// Evaluates a flat node sequence of the form `operand (infix-op-operand)*`
/// left-associatively. `root[0]` is the initial operand; each following node is
/// a math infix whose rhs is a single operand. Returns `null` when the sequence
/// is not a foldable integer expression (non-integer operand, unbound variable,
/// or division by zero).
fn foldRoot(root: []const Node) ?i64 {
    if (root.len == 0) return null;

    var acc = operandValue(root[0]) orelse return null;
    var i: usize = 1;
    while (i < root.len) : (i += 1) {
        if (!isMathOp(root[i])) return null;
        const op = root[i].infix.op[0];
        const right = foldRoot(root[i].infix.rhs.root) orelse return null;
        acc = switch (op) {
            '+' => acc + right,
            '-' => acc - right,
            '*' => acc * right,
            '/' => if (right == 0) return null else @divTrunc(acc, right),
            else => return null,
        };
    }
    return acc;
}

/// The integer value of a single operand, or `null` if it isn't a foldable
/// integer (e.g. an unbound variable or an operator node). A parenthesized
/// operand is itself an arithmetic sub-expression, folded via `foldRoot`.
fn operandValue(node: Node) ?i64 {
    return switch (node) {
        .constant => |constant| std.fmt.parseInt(i64, constant, 10) catch null,
        .pattern => |sub| foldRoot(sub.root),
        else => null,
    };
}

// Tests

const testing = std.testing;
const ArenaAllocator = std.heap.ArenaAllocator;
const Parser = @import("../Parser.zig");
const core = @import("../interpreter.zig");

/// Parses `source`, folds arithmetic, and returns the printed result. Uses the
/// caller's arena so computed literals are reclaimed in bulk.
fn evalToString(allocator: Allocator, source: []const u8) ![]const u8 {
    const pattern = try Parser.parse(allocator, source);
    const folded = try core.evaluateMath(allocator, pattern);
    return folded.toString(allocator);
}

test "evaluateMath: add two literals" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try evalToString(arena.allocator(), "1 + 2");
    try testing.expectEqualStrings("3", out);
}

test "evaluateMath: subtraction is left-associative" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Flat, left-associative: 10 - 3 - 2 folds as (10 - 3) - 2 = 5.
    const out = try evalToString(arena.allocator(), "10 - 3 - 2");
    try testing.expectEqualStrings("5", out);
}

test "evaluateMath: no operator precedence (left-associative)" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // 1 + 2 * 3 folds as (1 + 2) * 3 = 9, not 7.
    const out = try evalToString(arena.allocator(), "1 + 2 * 3");
    try testing.expectEqualStrings("9", out);
}

test "evaluateMath: multiplication" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try evalToString(arena.allocator(), "2 * 3");
    try testing.expectEqualStrings("6", out);
}

test "evaluateMath: integer division" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try evalToString(arena.allocator(), "8 / 2");
    try testing.expectEqualStrings("4", out);
}

test "evaluateMath: parenthesized operand folds and unwraps" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try evalToString(arena.allocator(), "(1 + 2) * 4");
    try testing.expectEqualStrings("12", out);
}

test "evaluateMath: non-arithmetic expression is unchanged" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try evalToString(arena.allocator(), "A B");
    try testing.expectEqualStrings("A B", out);
}

test "evaluateMath: unbound variable is not foldable" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try evalToString(arena.allocator(), "1 + x");
    try testing.expectEqualStrings("1 + x", out);
}

test "evaluateMath: division by zero is left intact" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try evalToString(arena.allocator(), "1 / 0");
    try testing.expectEqualStrings("1 / 0", out);
}
