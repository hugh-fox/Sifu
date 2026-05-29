const std = @import("std");
const testing = std.testing;
const ArenaAllocator = std.heap.ArenaAllocator;
const trie_mod = @import("sifu/trie.zig");
const Trie = trie_mod.Trie;
const Pattern = trie_mod.Pattern;
const Parser = @import("Parser.zig");

fn parseAndMatch(allocator: std.mem.Allocator, trie: Trie, query_str: []const u8) !?Pattern {
    var query = try Parser.parse(allocator, query_str);
    defer query.deinit(allocator);
    var term_bindings = trie_mod.VarBindings{};
    defer term_bindings.deinit(allocator);
    var pattern_bindings = trie_mod.VarPatternBindings{};
    defer pattern_bindings.deinit(allocator);
    var result = try trie.match(allocator, 0, &term_bindings, &pattern_bindings, query);
    defer result.deinit(allocator);
    if (result.value) |val| {
        return try val.copy(allocator);
    }
    return null;
}

fn expectMatch(allocator: std.mem.Allocator, trie: Trie, query_str: []const u8, expected_str: []const u8) !void {
    const result = try parseAndMatch(allocator, trie, query_str);
    try testing.expect(result != null);
    var result_mut = result.?;
    defer result_mut.deinit(allocator);
    var expected = try Parser.parse(allocator, expected_str);
    defer expected.deinit(allocator);
    try testing.expect(result_mut.eql(expected));
}

fn expectNoMatch(allocator: std.mem.Allocator, trie: Trie, query_str: []const u8) !void {
    const result = try parseAndMatch(allocator, trie, query_str);
    try testing.expect(result == null);
}

test "Submodules" {
    _ = @import("Parser.zig");
}

test "Pattern: simple vals" {
    var trie1 = try Parser.parseTrie(testing.allocator, "Aa Bb Cc -> 123");
    defer trie1.deinit(testing.allocator);
    var trie2 = try Parser.parseTrie(testing.allocator, "Aa Bb Cc -> 123");
    defer trie2.deinit(testing.allocator);
    try testing.expect(trie1.eql(trie2));

    // Test branching: add Aa Bb2 -> 456
    var trie_with_branch = try Parser.parseTrie(testing.allocator, "Aa Bb Cc -> 123; Aa Bb2 -> 456");
    defer trie_with_branch.deinit(testing.allocator);
    try testing.expect(!trie1.eql(trie_with_branch));

    // Verify match returns value
    try expectMatch(testing.allocator, trie1, "Aa Bb Cc", "123");
}

test "parseTrie: single key-value pair" {
    var trie = try Parser.parseTrie(testing.allocator, "A -> B");
    defer trie.deinit(testing.allocator);
    try expectMatch(testing.allocator, trie, "A", "B");
}

test "parseTrie: multiple entries with semicolon" {
    var trie = try Parser.parseTrie(testing.allocator, "A -> B; C -> D");
    defer trie.deinit(testing.allocator);
    try expectMatch(testing.allocator, trie, "A", "B");
    try expectMatch(testing.allocator, trie, "C", "D");
}

test "parseTrie: multi-token key" {
    var trie = try Parser.parseTrie(testing.allocator, "A B C -> X");
    defer trie.deinit(testing.allocator);
    try expectMatch(testing.allocator, trie, "A B C", "X");
}

test "parseTrie: entry without arrow (key equals value)" {
    var trie = try Parser.parseTrie(testing.allocator, "Foo");
    defer trie.deinit(testing.allocator);
    try expectMatch(testing.allocator, trie, "Foo", "Foo");
}

test "parseTrie: empty input" {
    const trie = try Parser.parseTrie(testing.allocator, "");
    // Shouldn't be anything to free here
    try expectNoMatch(testing.allocator, trie, "anything");
}

test "parseTrie: roundtrip" {
    var trie = try Parser.parseTrie(testing.allocator, "A -> B; B -> A; A -> B");
    defer trie.deinit(testing.allocator);
    try expectMatch(testing.allocator, trie, "A", "B");
    try expectMatch(testing.allocator, trie, "B", "A");
}

// evaluateComplete tests

fn expectEval(allocator: std.mem.Allocator, trie: Trie, query_str: []const u8, expected_str: []const u8) !void {
    var query = try Parser.parse(allocator, query_str);
    defer query.deinit(allocator);
    const eval = try trie.evaluateComplete(allocator, 0, query);
    if (eval.value) |*val| {
        defer @constCast(val).deinit(allocator);
        var expected = try Parser.parse(allocator, expected_str);
        defer expected.deinit(allocator);
        try testing.expect(val.eql(expected));
    } else {
        return error.NoEvalResult;
    }
}

test "evaluateComplete: simple rewrite" {
    var trie = try Parser.parseTrie(testing.allocator, "A -> B");
    defer trie.deinit(testing.allocator);
    try expectEval(testing.allocator, trie, "A", "B");
}

test "evaluateComplete: variable binding" {
    var trie = try Parser.parseTrie(testing.allocator, "x -> x");
    defer trie.deinit(testing.allocator);
    try expectEval(testing.allocator, trie, "Foo", "Foo");
}

test "evaluateComplete: multi-term with variable" {
    var trie = try Parser.parseTrie(testing.allocator, "Inc x -> x");
    defer trie.deinit(testing.allocator);
    try expectEval(testing.allocator, trie, "Inc 5", "5");
}

test "evaluateComplete: no match returns original" {
    var trie = try Parser.parseTrie(testing.allocator, "A -> B");
    defer trie.deinit(testing.allocator);
    var query = try Parser.parse(testing.allocator, "C");
    defer query.deinit(testing.allocator);
    const eval = try trie.evaluateComplete(testing.allocator, 0, query);
    if (eval.value) |*val| {
        defer @constCast(val).deinit(testing.allocator);
        try testing.expect(val.eql(query));
    }
}

test "evaluateComplete: roundtrip" {
    var trie = try Parser.parseTrie(testing.allocator, "A -> B; B -> A");
    defer trie.deinit(testing.allocator);
    try expectEval(testing.allocator, trie, "A", "A");
}
