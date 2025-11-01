const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList; // Update import
const mem = std.mem;
const math = std.math;
const util = @import("../util.zig");
const Order = math.Order;
const Wyhash = std.hash.Wyhash;
const array_hash_map = std.array_hash_map;
const AutoContext = std.array_hash_map.AutoContext;
const StringContext = std.array_hash_map.StringContext;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const DoublyLinkedList = std.DoublyLinkedList;
const print = util.print;
const first = util.first;
const last = util.last;
const streams = util.streams;
const assert = std.debug.assert;
const panic = util.panic;
const verbose_errors = @import("build_options").verbose_errors;
const debug_mode = @import("builtin").mode == .Debug;
const testing = @import("testing");
const Ast = parser.Tree;
const AstNode = parser.Node;
const AstCursor = parser.TreeCursor;
const Trie = @import("trie.zig").Trie;
const Pattern = @import("trie.zig").Pattern;
const Node = @import("trie.zig").Node;

pub const parser = @import("tree_sitter_sifu");

pub fn astSliceToPattern(
    allocator: Allocator,
    ast: []const AstNode,
) error{OutOfMemory}!Pattern {
    var nodes = try allocator.alloc(Node, ast.len);
    for (ast, 0..) |node, i| {
        nodes[i] = try astNodeToTrie(allocator, node);
    }
    var max_height: usize = 0;
    for (nodes) |node| {
        const h = getNodeHeight(node);
        if (h > max_height) max_height = h;
    }
    return .{ .root = nodes, .height = max_height + 1 };
}

// print("{s}\n", .{try ast.rootNode().toSexp(allocator)});/// Convert an AstNode to a Trie
pub fn astNodeToTrie(
    allocator: Allocator,
    source: []const u8,
    ast: *parser.Tree,
) error{OutOfMemory}!Trie {
    var trie = try Trie.create(allocator);
    errdefer trie.deinit(allocator);

    const root_node = ast.rootNode();

    // Process all top-level patterns in the source file
    var child_cursor = root_node.walk();

    if (child_cursor.gotoFirstChild()) {
        while (true) {
            const node = child_cursor.node();
            const node_type = node.kind();

            // Skip newlines and comments
            if (std.mem.eql(u8, node_type, "\n") or
                std.mem.eql(u8, node_type, "comment"))
            {
                if (!child_cursor.gotoNextSibling()) break;
                continue;
            }

            // Process pattern nodes
            if (std.mem.eql(u8, node_type, "pattern")) {
                const pattern = try astNodeToPattern(allocator, source, node);
                defer pattern.deinit(allocator);

                // Append pattern to trie with no value (it's a top-level pattern)
                _ = try trie.append(allocator, pattern, null);
            }

            if (!child_cursor.gotoNextSibling()) break;
        }
    }

    return trie.*;
}

/// Parse a pattern node into a Pattern
pub fn astNodeToPattern(
    allocator: Allocator,
    source: []const u8,
    node: AstNode,
) error{OutOfMemory}!Pattern {
    var nodes = std.ArrayList(Node){};
    errdefer {
        for (nodes.items) |n| {
            n.deinit(allocator);
        }
        nodes.deinit(allocator);
    }

    var cursor = node.walk();

    if (cursor.gotoFirstChild()) {
        while (true) {
            const child = cursor.node();
            const trie_node = try parseTermNode(allocator, source, child);
            try nodes.append(allocator, trie_node);

            if (!cursor.gotoNextSibling()) break;
        }
    }

    const node_slice = try nodes.toOwnedSlice(allocator);

    // Calculate max height
    var max_height: usize = 0;
    for (node_slice) |n| {
        const h = getNodeHeight(n);
        if (h > max_height) max_height = h;
    }

    return .{ .root = node_slice, .height = max_height + 1 };
}

/// Parse a term node into a Node
fn parseTermNode(
    allocator: Allocator,
    source: []const u8,
    node: AstNode,
) error{OutOfMemory}!Node {
    const node_type = node.kind();
    const start_byte = node.startByte();
    const end_byte = node.endByte();
    print("{}..{}\n", .{ start_byte, end_byte });
    streams.err.flush() catch unreachable;
    const text = source[start_byte..end_byte];

    // Keys (uppercase identifiers)
    if (std.mem.eql(u8, node_type, "key")) {
        return Node.ofKey(text);
    }

    // Variables (lowercase identifiers)
    if (std.mem.eql(u8, node_type, "var")) {
        return Node.ofVar(text);
    }

    // Numbers, strings, symbols - treat as keys
    if (std.mem.eql(u8, node_type, "number") or
        std.mem.eql(u8, node_type, "string") or
        std.mem.eql(u8, node_type, "symbol"))
    {
        return Node.ofKey(text);
    }
    // Operators - parse as patterns
    if (std.mem.eql(u8, node_type, "comma_expr") or
        std.mem.eql(u8, node_type, "semicolon_expr") or
        std.mem.eql(u8, node_type, "long_match") or
        std.mem.eql(u8, node_type, "long_arrow") or
        std.mem.eql(u8, node_type, "infix") or
        std.mem.eql(u8, node_type, "short_match") or
        std.mem.eql(u8, node_type, "short_arrow"))
    {
        const pattern = try astNodeToPattern(allocator, source, node);
        return Node.ofPattern(pattern);
    }

    // Nested structures
    if (std.mem.eql(u8, node_type, "nested_pattern") or
        std.mem.eql(u8, node_type, "nested_trie"))
    {
        const pattern = try astNodeToPattern(allocator, source, node);
        return Node.ofPattern(pattern);
    }

    // Default: treat as key
    return Node.ofKey(text);
}

fn getNodeHeight(node: Node) usize {
    return switch (node) {
        .pattern, .infix, .match, .arrow, .list => |p| p.height,
        .trie => 1,
        else => 0,
    };
}
