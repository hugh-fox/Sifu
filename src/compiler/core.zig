//! The Sifu-to-WAT compiler driver.
//!
//! The compiler proper is `wat.sifu`: a trie of rewrite rules, piped in on
//! stdin as the rule set. This driver does nothing more than wire the
//! interpreter to it —
//!
//!   1. interpret `wat.sifu` as the trie (the rule set, supplied by the caller),
//!   2. interpret the input program (also Sifu) as the pattern to evaluate,
//!   3. evaluate the pattern against the trie with the ordinary interpreter.
//!
//! The result is a Sifu pattern that assembles WAT with the `++` string
//! operator. The only non-interpreter step is `string.evaluateString`, used
//! purely at the output stage to fold those string pieces into finished WAT
//! text so it prints as code rather than being re-read as Sifu. `string.zig` is
//! otherwise unrelated to the interpreter; the compiler is its only caller here.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Parser = @import("../Parser.zig");
const Trie = @import("../sifu/trie.zig").Trie;
const interpreter = @import("../interpreter/core.zig");

/// Compiles `program` (an ordinary Sifu expression, e.g. `1 + 2`) to a complete,
/// runnable WAT module, by evaluating it against wat.sifu and wrapping the
/// resulting body in a `(module …)`. Returns the emitted WAT as a string.
///
/// The body translation lives entirely in `wat.sifu` (the self-hosted compiler);
/// the module wrapper here is the one piece not yet expressed in Sifu. It can
/// move into a `Module …`/`Main …` rule once string literals with embedded
/// quotes are ergonomic in the language.
///
/// Drive with an arena: `evaluateString` allocates the folded literal's bytes
/// from `allocator` without freeing them on `deinit`, matching how the
/// interpreter treats constant text.
pub fn compile(allocator: Allocator, trie: Trie, program: []const u8) ![]const u8 {
    var pattern = try Parser.parse(allocator, program);
    defer pattern.deinit(allocator);

    const eval = try interpreter.evaluateComplete(trie, allocator, 0, pattern);
    var value = eval.value orelse return "";
    defer value.deinit(allocator);

    const folded = try value.toString(allocator);
    const body = unquote(folded);

    // Wrap the body in a runnable module. Using a `$main` name index keeps the
    // body itself quote-free; the one required `"main"` export string is written
    // here in Zig where quoting is trivial.
    return std.fmt.allocPrint(
        allocator,
        "(module (func $main (result i32) {s}) (export \"main\" (func $main)))",
        .{body},
    );
}

/// Strips a single pair of surrounding double quotes, if present. Mirrors the
/// helper in `string.zig`; the folded body is a single quoted string literal.
fn unquote(text: []const u8) []const u8 {
    if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"')
        return text[1 .. text.len - 1];
    return text;
}

// Tests

const testing = std.testing;
const ArenaAllocator = std.heap.ArenaAllocator;

/// The compiler's root, embedded so the tests can exercise it without piping.
const wat_source = @embedFile("wat.sifu");

fn expectCompiles(program: []const u8, expected_wat: []const u8) !void {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const trie = try Parser.parseTrie(allocator, wat_source);
    const wat = try compile(allocator, trie, program);
    try testing.expectEqualStrings(expected_wat, wat);
}

/// Wraps a body fragment in the module boilerplate `compile` emits, so tests
/// can state just the interesting part.
fn module(comptime body: []const u8) []const u8 {
    return "(module (func $main (result i32) " ++ body ++ ") (export \"main\" (func $main)))";
}

test "compile: integer literal" {
    try expectCompiles("42", module("(i32.const 42)"));
}

test "compile: addition" {
    try expectCompiles("1 + 2", module("(i32.add (i32.const 1) (i32.const 2))"));
}

test "compile: nested expression" {
    try expectCompiles(
        "1 + 2 - 3",
        module("(i32.add (i32.const 1) (i32.sub (i32.const 2) (i32.const 3)))"),
    );
}

test "compile: equality comparison" {
    try expectCompiles("1 == 1", module("(i32.eq (i32.const 1) (i32.const 1))"));
}

test "compile: less-than comparison" {
    try expectCompiles("1 < 2", module("(i32.lt_s (i32.const 1) (i32.const 2))"));
}

test "compile: greater-than comparison" {
    try expectCompiles("2 > 1", module("(i32.gt_s (i32.const 2) (i32.const 1))"));
}

test "compile: conditional" {
    try expectCompiles(
        "If 1 Then 2 Else 3",
        module("(if (result i32) (i32.const 1) (then (i32.const 2)) (else (i32.const 3)))"),
    );
}
