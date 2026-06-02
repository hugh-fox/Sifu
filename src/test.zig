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
    var result = try trie.match(allocator, .{ .upper = trie.size() }, &term_bindings, query);
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
        if (!val.eql(expected)) {
            const result_str = try val.toString(allocator);
            defer allocator.free(result_str);
            try testing.expectEqualStrings(expected_str, result_str);
        }
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

test "evaluateComplete: VarPattern in nested list" {
    var trie = try Parser.parseTrie(testing.allocator, "A, *x --> *x");
    defer trie.deinit(testing.allocator);

    try expectEval(testing.allocator, trie, "A,", "");
    try expectEval(testing.allocator, trie, "A, B", "B");
    try expectEval(testing.allocator, trie, "A, B, C", "B, C");
    try expectEval(testing.allocator, trie, "A, B, C,", "B, C,");
}

test "evaluateComplete: nested pattern" {
    var trie = try Parser.parseTrie(testing.allocator, "x, y --> y, x");
    defer trie.deinit(testing.allocator);

    // Verify trie structure: x -> , -> y -> value
    try testing.expect(trie.var_branches.items.len == 1);
    const x_trie = trie.map.get("x") orelse return error.MissingX;
    try testing.expect(x_trie.map.contains(","));
    const comma_trie = x_trie.map.get(",") orelse return error.MissingComma;
    try testing.expect(comma_trie.var_branches.items.len == 1);

    // Test the match directly
    var query = try Parser.parse(testing.allocator, "A, B");
    defer query.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), query.root.len);
    try testing.expect(query.root[0] == .key);
    try testing.expect(query.root[1] == .list);

    var term_bindings = trie_mod.VarBindings{};
    defer term_bindings.deinit(testing.allocator);
    var match_result = try trie.match(testing.allocator, .{ .upper = trie.size() }, &term_bindings, query);
    defer match_result.deinit(testing.allocator);

    // Match should succeed with value
    try testing.expect(match_result.value != null);

    // Check bindings
    try testing.expect(term_bindings.get("x") != null);
    try testing.expect(term_bindings.get("y") != null);

    try expectEval(testing.allocator, trie, "A, B", "B, A");
}

test "evaluateComplete: VarPattern in nested pattern" {
    var trie = try Parser.parseTrie(testing.allocator, "(x, *x) --> x + *x");
    defer trie.deinit(testing.allocator);
    try expectEval(testing.allocator, trie, "(A, B C)", "A + B C");
}

test "rewrite: simple variable substitution" {
    var trie = try Parser.parseTrie(testing.allocator, "x --> x");
    defer trie.deinit(testing.allocator);

    // Value pattern is [variable(x)]
    const value_pattern = trie.getIndex(0);

    // Set up bindings: x = A
    var bindings = trie_mod.VarBindings{};
    defer bindings.deinit(testing.allocator);
    try bindings.put(testing.allocator, "x", trie_mod.Node{ .key = "A" });

    // Rewrite should replace x with A
    var result = try trie.rewrite(testing.allocator, value_pattern, &bindings);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.root.len);
    try testing.expect(result.root[0] == .key);
    try testing.expectEqualStrings("A", result.root[0].key);
}

test "rewrite: nested list with variables" {
    var trie = try Parser.parseTrie(testing.allocator, "x, y --> y, x");
    defer trie.deinit(testing.allocator);

    // Value pattern is [variable(y), list([variable(x)])]
    const value_pattern = trie.getIndex(0);
    try testing.expectEqual(@as(usize, 2), value_pattern.root.len);
    try testing.expect(value_pattern.root[0] == .variable);
    try testing.expect(value_pattern.root[1] == .list);

    // Set up bindings: x = A, y = B
    var bindings = trie_mod.VarBindings{};
    defer bindings.deinit(testing.allocator);
    try bindings.put(testing.allocator, "x", trie_mod.Node{ .key = "A" });
    try bindings.put(testing.allocator, "y", trie_mod.Node{ .key = "B" });

    // Rewrite should produce [B, list([A])]
    var result = try trie.rewrite(testing.allocator, value_pattern, &bindings);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.root.len);
    try testing.expect(result.root[0] == .key);
    try testing.expectEqualStrings("B", result.root[0].key);
    try testing.expect(result.root[1] == .list);
    try testing.expectEqual(@as(usize, 1), result.root[1].list.root.len);
    try testing.expect(result.root[1].list.root[0] == .key);
    try testing.expectEqualStrings("A", result.root[1].list.root[0].key);
}

test "evaluateComplete: step by step x, y --> y, x" {
    var trie = try Parser.parseTrie(testing.allocator, "x, y --> y, x");
    defer trie.deinit(testing.allocator);

    var query = try Parser.parse(testing.allocator, "A, B");
    defer query.deinit(testing.allocator);

    const eval = try trie.evaluateComplete(testing.allocator, 0, query);
    var result = eval.value orelse return error.NoEvalResult;
    defer result.deinit(testing.allocator);

    // Result should be [B, list([A])]
    try testing.expectEqual(@as(usize, 2), result.root.len);
    try testing.expect(result.root[0] == .key);
    try testing.expectEqualStrings("B", result.root[0].key);
    try testing.expect(result.root[1] == .list);
    try testing.expectEqual(@as(usize, 1), result.root[1].list.root.len);
    try testing.expect(result.root[1].list.root[0] == .key);
    try testing.expectEqualStrings("A", result.root[1].list.root[0].key);
}

test "Parser structure: x, y --> y, x" {
    var zig_pattern = try Parser.parse(testing.allocator, "x, y --> y, x");
    defer zig_pattern.deinit(testing.allocator);

    // Due to precedence (comma=3 > long_arrow=2), this parses as: (x, y) --> (y, x)
    // Which gives: [variable(x), list([variable(y)]), arrow([variable(y), list([variable(x)])])]
    try testing.expectEqual(@as(usize, 3), zig_pattern.root.len);
    try testing.expect(zig_pattern.root[0] == .variable);
    try testing.expect(zig_pattern.root[1] == .list);
    try testing.expect(zig_pattern.root[2] == .arrow);
}

test "Parser structure: A, B" {
    var zig_pattern = try Parser.parse(testing.allocator, "A, B");
    defer zig_pattern.deinit(testing.allocator);

    // Zig parser should produce: [key(A), list([key(B)])]
    try testing.expectEqual(@as(usize, 2), zig_pattern.root.len);
    try testing.expect(zig_pattern.root[0] == .key);
    try testing.expect(zig_pattern.root[1] == .list);
    try testing.expectEqual(@as(usize, 1), zig_pattern.root[1].list.root.len);
}

// rebuildKey tests

const Node = trie_mod.Node;

fn expectRebuildRoundtrip(trie: Trie, index: usize) !void {
    var rebuilt = try trie.rebuildKey(testing.allocator, index);
    defer testing.allocator.free(rebuilt.root);
    const str = try rebuilt.toString(testing.allocator);
    defer testing.allocator.free(str);

    var parsed = try Parser.parse(testing.allocator, str);
    defer parsed.deinit(testing.allocator);

    // Verify parsed pattern matches the trie at this index
    var bindings = trie_mod.VarBindings{};
    defer bindings.deinit(testing.allocator);
    var match_result = try trie.match(testing.allocator, .{ .lower = index, .upper = trie.size() }, &bindings, parsed);
    defer match_result.deinit(testing.allocator);
    try testing.expect(match_result.value != null);
}

test "rebuildKey: multiple entries roundtrip" {
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    var key0 = [_]Node{ .{ .key = "A" }, .{ .key = "B" }, .{ .variable = "x" } };
    var key1 = [_]Node{ .{ .key = "A" }, .{ .key = "C" } };
    var key2 = [_]Node{ .{ .key = "A" }, .{ .key = "B" }, .{ .variable = "y" } };
    var val = [_]Node{.{ .key = "V" }};
    _ = try trie.append(testing.allocator, .{ .root = &key0 }, .{ .root = &val });
    _ = try trie.append(testing.allocator, .{ .root = &key1 }, .{ .root = &val });
    _ = try trie.append(testing.allocator, .{ .root = &key2 }, .{ .root = &val });

    try expectRebuildRoundtrip(trie, 0);
    try expectRebuildRoundtrip(trie, 1);
    try expectRebuildRoundtrip(trie, 2);
}

test "rebuildKey: nested with list roundtrip" {
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    var list_inner = [_]Node{.{ .variable = "y" }};
    var inner = [_]Node{ .{ .variable = "x" }, .{ .list = .{ .root = &list_inner } } };
    var key = [_]Node{.{ .pattern = .{ .root = &inner } }};
    var val = [_]Node{.{ .key = "V" }};
    _ = try trie.append(testing.allocator, .{ .root = &key }, .{ .root = &val });

    try expectRebuildRoundtrip(trie, 0);
}

test "rebuildKey: embedded trie roundtrip" {
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    var inner_trie = Trie{};
    defer inner_trie.deinit(testing.allocator);
    var inner_key0 = [_]Node{.{ .key = "A" }};
    var inner_val0 = [_]Node{.{ .key = "B" }};
    var inner_key1 = [_]Node{ .{ .key = "C" }, .{ .key = "D" } };
    var inner_val1 = [_]Node{.{ .key = "E" }};
    _ = try inner_trie.append(testing.allocator, .{ .root = &inner_key0 }, .{ .root = &inner_val0 });
    _ = try inner_trie.append(testing.allocator, .{ .root = &inner_key1 }, .{ .root = &inner_val1 });

    var key = [_]Node{ .{ .key = "X" }, .{ .trie = inner_trie }, .{ .key = "Y" } };
    var val = [_]Node{.{ .key = "V" }};
    _ = try trie.append(testing.allocator, .{ .root = &key }, .{ .root = &val });

    try expectRebuildRoundtrip(trie, 0);
}

test "rebuildKey: multiple nested tries roundtrip" {
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    var inner1 = Trie{};
    defer inner1.deinit(testing.allocator);
    var i1_key = [_]Node{.{ .key = "A" }};
    var i1_val = [_]Node{.{ .key = "B" }};
    _ = try inner1.append(testing.allocator, .{ .root = &i1_key }, .{ .root = &i1_val });

    var inner2 = Trie{};
    defer inner2.deinit(testing.allocator);
    var i2_key0 = [_]Node{.{ .key = "C" }};
    var i2_val0 = [_]Node{.{ .key = "D" }};
    var i2_key1 = [_]Node{.{ .key = "E" }};
    var i2_val1 = [_]Node{.{ .key = "F" }};
    _ = try inner2.append(testing.allocator, .{ .root = &i2_key0 }, .{ .root = &i2_val0 });
    _ = try inner2.append(testing.allocator, .{ .root = &i2_key1 }, .{ .root = &i2_val1 });

    var key = [_]Node{ .{ .trie = inner1 }, .{ .key = "X" }, .{ .trie = inner2 } };
    var val = [_]Node{.{ .key = "V" }};
    _ = try trie.append(testing.allocator, .{ .root = &key }, .{ .root = &val });

    try expectRebuildRoundtrip(trie, 0);
}

test "rebuildKey: height preserved" {
    // rebuildKey reconstructs keys/vars, which have height 0
    // This test verifies the basic roundtrip works
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    var key = [_]Node{ .{ .key = "A" }, .{ .variable = "x" } };
    var val = [_]Node{.{ .key = "V" }};
    _ = try trie.append(testing.allocator, .{ .root = &key }, .{ .root = &val });

    const rebuilt = try trie.rebuildKey(testing.allocator, 0);
    defer testing.allocator.free(rebuilt.root);
    try testing.expectEqual(@as(usize, 0), rebuilt.height);
}

// TODO: This test causes infinite recursion, needs height tracking fix
// test "evaluateComplete: Recursion2 - roundtrip unwrap" {
//     var trie = try Parser.parseTrie(testing.allocator, "A --> (A)\n(A) --> A");
//     defer trie.deinit(testing.allocator);
//
//     // First verify matching works
//     try expectMatch(testing.allocator, trie, "(A)", "A");
//
//     // Then check evaluation
//     try expectEval(testing.allocator, trie, "(A)", "A");
//     try expectEval(testing.allocator, trie, "A", "A");
// }

test "evaluateComplete: simple var_pattern unwrap" {
    // (*xs) --> *xs should unwrap the outer parens
    var trie = try Parser.parseTrie(testing.allocator, "(*xs) --> *xs");
    defer trie.deinit(testing.allocator);

    try expectEval(testing.allocator, trie, "(A)", "A");
    try expectEval(testing.allocator, trie, "(A, B)", "A, B");
    try expectEval(testing.allocator, trie, "(A, B, C)", "A, B, C");
}

test "Structural recursion: height tracking through evaluation" {
    // Simulate the evaluation of (1, 2, 3) with rules:
    // (x) --> x           (rule 0)
    // (x, *xs) --> x, (*xs)  (rule 1)
    //
    // Heights with new model (each op adds 1):
    // - "(1, 2, 3)": parens(1) + comma(1) + comma(1) = 3
    // - "1, (2, 3)": comma(1) + parens(1) + comma(1) = 3
    // - "(2, 3)": parens(1) + comma(1) = 2
    //
    // Step 1: (1, 2, 3) matches rule 1, x=1, *xs=(2, 3)
    // Rewrite to: 1, (2, 3) with height 3
    // is_structural: query.height(3) > rewritten.height(3) = false

    var trie = try Parser.parseTrie(testing.allocator, "(x) --> x\n(x, *xs) --> x, (*xs)");
    defer trie.deinit(testing.allocator);

    var query = try Parser.parse(testing.allocator, "(1, 2, 3)");
    defer query.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), query.height);

    // Match step
    var bindings = trie_mod.VarBindings{};
    defer bindings.deinit(testing.allocator);
    var match_result = try trie.match(testing.allocator, .{ .upper = trie.size() }, &bindings, query);
    defer match_result.deinit(testing.allocator);

    // Should match rule 1
    try testing.expectEqual(@as(usize, 1), match_result.match_index);
    try testing.expect(match_result.value != null);

    // Rewrite step
    var rewritten = try trie.rewrite(testing.allocator, match_result.value.?, &bindings);
    defer rewritten.deinit(testing.allocator);

    // Check structural recursion condition
    const is_structural_top = query.height > rewritten.height;
    try testing.expect(!is_structural_top); // 3 > 3 = false

    // Check the nested pattern inside the rewritten result
    // rewritten = [1, list([pattern(2, 3)])]
    try testing.expectEqual(@as(usize, 2), rewritten.root.len);
    try testing.expect(rewritten.root[1] == .list);

    const list_pattern = rewritten.root[1].list;
    try testing.expectEqual(@as(usize, 1), list_pattern.root.len);
    try testing.expect(list_pattern.root[0] == .pattern);

    const nested_pattern_node = list_pattern.root[0];
    // Node.height() returns the Pattern's height inside the node
    // (2, 3) = parens(1) + comma(1) = 2
    try testing.expectEqual(@as(usize, 2), nested_pattern_node.height());

    const nested_content = nested_pattern_node.pattern;
    try testing.expectEqual(@as(usize, 2), nested_content.height);

    // Structural recursion check: nested height 2 < query height 3
    const is_structural_nested = nested_pattern_node.height() < query.height;
    try testing.expect(is_structural_nested); // 2 < 3 = true
}

test "Pattern height: nested patterns" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try testing.expectEqual(@as(usize, 0), (try Parser.parse(alloc, "")).height);
    try testing.expectEqual(@as(usize, 0), (try Parser.parse(alloc, "A B")).height);
    try testing.expectEqual(@as(usize, 1), (try Parser.parse(alloc, "()")).height);
    try testing.expectEqual(@as(usize, 1), (try Parser.parse(alloc, ",")).height);
    try testing.expectEqual(@as(usize, 1), (try Parser.parse(alloc, "1,")).height);
    try testing.expectEqual(@as(usize, 1), (try Parser.parse(alloc, "1, 2")).height);
    try testing.expectEqual(@as(usize, 2), (try Parser.parse(alloc, "1, 2,")).height);
    try testing.expectEqual(@as(usize, 2), (try Parser.parse(alloc, "1,(2)")).height);
    try testing.expectEqual(@as(usize, 3), (try Parser.parse(alloc, "1,(2,3)")).height);
    try testing.expectEqual(@as(usize, 1), (try Parser.parse(alloc, "1 + 2")).height);
}
