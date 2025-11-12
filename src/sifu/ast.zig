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
            const node_kind = node.kind();

            // Skip newlines and comments
            if (std.mem.eql(u8, node_kind, "\n") or
                std.mem.eql(u8, node_kind, "comment"))
            {
                if (!child_cursor.gotoNextSibling()) break;
                continue;
            }

            // Process pattern nodes
            if (std.mem.eql(u8, node_kind, "pattern")) {
                const pattern = try astToPattern(allocator, source, node);
                // Append pattern to trie with no value (it's a top-level pattern)
                _ = try trie.append(allocator, pattern, null);
            }

            if (!child_cursor.gotoNextSibling()) break;
        }
    }

    return trie.*;
}

/// Parse a term node into a Node (recursive)
fn parseTermNode(
    allocator: Allocator,
    source: []const u8,
    node: AstNode,
) error{OutOfMemory}!?Node {
    const node_kind = node.kind();
    const start_byte = node.startByte();
    const end_byte = node.endByte();
    const text = source[start_byte..end_byte];

    // Ignore anonymous nodes (this info is stored in the enum type, like `arrow`)
    if (!node.isNamed())
        return null;

    const NodeKind = enum {
        key,
        variable,
        number,
        string,
        symbol,
        pattern,
        comma_expr,
        semicolon_expr,
        long_match,
        long_arrow,
        infix,
        short_match,
        short_arrow,
        nested_pattern,
        nested_trie,
    };

    const kind = std.meta.stringToEnum(NodeKind, node_kind) orelse {
        // TODO: ignore literal nodes like '->' when parsing builtins and other rules that use literals
        // return Node{ .key = text };
        // TODO: when above is complete, add this back when not in release mode
        return panic("Unhandled AST node type: {s}", .{node_kind});
    };

    return switch (kind) {
        .key, .number, .string, .symbol => Node{ .key = text },
        .variable => Node{ .variable = text },
        .pattern => .{ .pattern = try astToPattern(allocator, source, node) },
        .comma_expr => .{ .list = try astToPattern(allocator, source, node) },
        .semicolon_expr => .{ .list = try astToPattern(allocator, source, node) },
        .long_match => .{ .match = try astToPattern(allocator, source, node) },
        .long_arrow => .{ .arrow = try astToPattern(allocator, source, node) },
        .infix => .{ .infix = try astToPattern(allocator, source, node) },
        .short_match => .{ .match = try astToPattern(allocator, source, node) },
        .short_arrow => .{ .arrow = try astToPattern(allocator, source, node) },
        .nested_pattern => .{ .pattern = try astToPattern(allocator, source, node) },
        .nested_trie => .{ .trie = @panic("unimplemented\n") },
    };
}

/// Recursively parse a pattern node and its children
pub fn astToPattern(
    allocator: Allocator,
    source: []const u8,
    node: AstNode,
) error{OutOfMemory}!Pattern {
    print("Parsing pattern node of type '{s}' with {} children\n", .{ node.kind(), node.childCount() });
    var nodes = std.ArrayList(Node){};
    errdefer {
        for (nodes.items) |n| {
            n.deinit(allocator);
        }
        nodes.deinit(allocator);
    }
    var cursor = node.walk();
    var has_next = cursor.gotoFirstChild();
    while (has_next) {
        while (has_next) : (has_next = cursor.gotoNextSibling()) {
            const child = cursor.node();
            const child_type = child.kind();
            // Skip comments
            if (std.mem.eql(u8, child_type, "comment"))
                continue;
            // Recursively parse each child
            const trie_node = try parseTermNode(allocator, source, child) orelse {
                has_next = cursor.gotoFirstChild();
                continue;
            };
            try nodes.append(allocator, trie_node);
        }
        has_next = cursor.gotoParent();
        has_next = cursor.gotoNextSibling();
    }
    const node_slice = try nodes.toOwnedSlice(allocator);
    // Calculate max height
    var max_height: usize = 0;
    for (node_slice) |n| {
        const h = getNodeHeight(n);
        if (h > max_height)
            max_height = h;
    }
    return .{ .root = node_slice, .height = max_height + 1 };
}

fn getNodeHeight(node: Node) usize {
    return switch (node) {
        .pattern, .infix, .match, .arrow, .list => |p| p.height,
        .trie => 1,
        else => 0,
    };
}
