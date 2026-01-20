const std = @import("std");
const testing = std.testing;
const ArenaAllocator = std.heap.ArenaAllocator;
const Trie = @import("sifu/trie.zig").Trie;
const Node = @import("sifu/trie.zig").Node;
const Pattern = @import("sifu/trie.zig").Pattern;

test "Submodules" {}

test "equal strings with different pointers or pos should be equal" {
    const str1 = "abc";
    const str2 = try testing.allocator.dupe(u8, str1);
    defer testing.allocator.free(str2);

    const node1 = Node.ofKey(str1);
    const node2 = Node.ofKey(str2);

    try testing.expect(node1.eql(node2));
}

test "equal contexts with different values should not be equal" {
    const node1 = Node.ofKey("Foo");
    const node2 = Node.ofKey("Bar");

    try testing.expect(!node1.eql(node2));
}

test "Pattern: simple vals" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Build key: Aa Bb Cc
    const key_nodes = try allocator.alloc(Node, 3);
    key_nodes[0] = Node.ofKey("Aa");
    key_nodes[1] = Node.ofKey("Bb");
    key_nodes[2] = Node.ofKey("Cc");
    const key = Pattern{ .root = key_nodes, .height = 1 };

    // Build value: 123
    const val_nodes = try allocator.alloc(Node, 1);
    val_nodes[0] = Node.ofKey("123");
    const val = Pattern{ .root = val_nodes, .height = 1 };

    var actual = Trie{};
    var expected = Trie{};

    // Append into actual and expected
    _ = try actual.append(allocator, key, val);
    _ = try expected.append(allocator, key, val);

    try testing.expect(expected.eql(actual));

    // Test branching: add Aa Bb2 -> 456
    const key2_nodes = try allocator.alloc(Node, 2);
    key2_nodes[0] = Node.ofKey("Aa");
    key2_nodes[1] = Node.ofKey("Bb2");
    const key2 = Pattern{ .root = key2_nodes, .height = 1 };

    const val2_nodes = try allocator.alloc(Node, 1);
    val2_nodes[0] = Node.ofKey("456");
    const val2 = Pattern{ .root = val2_nodes, .height = 1 };

    _ = try expected.append(allocator, key2, val2);
    try testing.expect(!expected.eql(actual));
    _ = try actual.append(allocator, key2, val2);
    try testing.expect(expected.eql(actual));

    // Verify match returns value
    var res = try actual.match(allocator, 0, .{}, key);
    defer res.deinit(allocator);
    try testing.expect(res.value orelse null != null);
    try testing.expect(res.value.?.eql(val));
}
