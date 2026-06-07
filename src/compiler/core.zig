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

/// Compiles `program` (an ordinary Sifu expression, e.g. `1 + 2`) to WAT,
/// by evaluating it against wat.sifu. Returns the emitted
/// WAT as a string.
///
/// Drive with an arena: `evaluateString` allocates the folded literal's bytes
/// from `allocator` without freeing them on `deinit`, matching how the
/// interpreter treats key text.
pub fn compile(allocator: Allocator, trie: Trie, program: []const u8) ![]const u8 {
    var pattern = try Parser.parse(allocator, program);
    defer pattern.deinit(allocator);

    const eval = try interpreter.evaluateComplete(trie, allocator, 0, pattern);
    var value = eval.value orelse return "";
    defer value.deinit(allocator);

    return value.toString(allocator);
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

test "compile: integer literal" {
    try expectCompiles("42", "\"(i32.const 42)\"");
}

test "compile: addition" {
    try expectCompiles("1 + 2", "\"(i32.add (i32.const 1) (i32.const 2))\"");
}

test "compile: nested expression" {
    try expectCompiles(
        "1 + 2 - 3",
        "\"(i32.add (i32.const 1) (i32.sub (i32.const 2) (i32.const 3)))\"",
    );
}
