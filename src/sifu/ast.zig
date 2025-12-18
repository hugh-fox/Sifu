const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
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

pub fn astNodeToTrie(
    allocator: Allocator,
    source: []const u8,
    ast: *parser.Tree,
) error{OutOfMemory}!Trie {
    var trie = try Trie.create(allocator);
    errdefer trie.deinit(allocator);

    const root_node = ast.rootNode();
    var child_cursor = root_node.walk();

    if (child_cursor.gotoFirstChild()) {
        while (true) {
            const node = child_cursor.node();
            const node_kind = node.kind();

            if (mem.eql(u8, node_kind, "\n") or
                mem.eql(u8, node_kind, "comment"))
            {
                if (!child_cursor.gotoNextSibling()) break;
                continue;
            }

            if (mem.eql(u8, node_kind, "pattern")) {
                const pattern = try astToPattern(allocator, source, node);
                _ = try trie.append(allocator, pattern, null);
            }

            if (!child_cursor.gotoNextSibling()) break;
        }
    }

    return trie.*;
}

/// Recursively parse a pattern node and its children
pub fn astToPattern(
    allocator: Allocator,
    source: []const u8,
    node: AstNode,
) error{OutOfMemory}!Pattern {
    const node_kind = node.kind();

    print("Parsing node of type '{s}' with {} children\n", .{ node_kind, node.childCount() });

    // Check if this is an operator node
    const is_operator = mem.eql(u8, node_kind, "semicolon") or
        mem.eql(u8, node_kind, "long_match") or
        mem.eql(u8, node_kind, "long_arrow") or
        mem.eql(u8, node_kind, "comma") or
        mem.eql(u8, node_kind, "infix") or
        mem.eql(u8, node_kind, "match") or
        mem.eql(u8, node_kind, "arrow");

    if (is_operator) {
        return try parseOperatorNode(allocator, source, node, node_kind);
    }

    // For terms, we need to look at their single child
    // since the grammar wraps everything in optional(_op)
    if ((mem.eql(u8, node_kind, "nested_pattern"))) {
        if (node.childByFieldName("inner")) |child| {
            print("  Unwrapping nested_pattern, child kind {s}\n", .{child.kind()});
            return try astToPattern(allocator, source, child);
        }
    }

    // Handle non-operator nodes by flattening their children
    var nodes = std.ArrayList(Node){};
    errdefer {
        for (nodes.items) |n| n.deinit(allocator);
        nodes.deinit(allocator);
    }

    var cursor = node.walk();
    if (cursor.gotoFirstChild()) {
        while (true) {
            const child = cursor.node();
            const child_kind = child.kind();

            // Skip comments
            if (mem.eql(u8, child_kind, "comment")) {
                if (!cursor.gotoNextSibling()) break;
                continue;
            }

            // Parse the child
            if (try parseTermNode(allocator, source, child)) |parsed_node| {
                try nodes.append(allocator, parsed_node);
            }

            if (!cursor.gotoNextSibling()) break;
        }
    }

    const node_slice = try nodes.toOwnedSlice(allocator);
    var max_height: usize = 0;
    for (node_slice) |n| {
        const h = getNodeHeight(n);
        if (h > max_height) max_height = h;
    }

    return .{ .root = node_slice, .height = max_height + 1 };
}

fn parseOperatorNode(
    allocator: Allocator,
    source: []const u8,
    node: AstNode,
    node_kind: []const u8,
) error{OutOfMemory}!Pattern {
    print("Parsing operator '{s}'\n", .{node_kind});

    var nodes = std.ArrayList(Node){};
    errdefer {
        for (nodes.items) |n| n.deinit(allocator);
        nodes.deinit(allocator);
    }

    var lhs_node: ?AstNode = null;
    var rhs_node: ?AstNode = null;
    var op_symbol: ?[]const u8 = null;

    // Extract LHS, RHS, and operator symbol (for infix)
    var cursor = node.walk();
    if (cursor.gotoFirstChild()) {
        while (true) {
            const child = cursor.node();
            const field_name = cursor.fieldName();

            if (field_name) |fname| {
                print("  Field '{s}': {s}\n", .{ fname, child.kind() });
                if (mem.eql(u8, fname, "lhs")) {
                    lhs_node = child;
                } else if (mem.eql(u8, fname, "rhs")) {
                    rhs_node = child;
                } else if (mem.eql(u8, fname, "op")) {
                    const start = child.startByte();
                    const end = child.endByte();
                    op_symbol = source[start..end];
                }
            }

            if (!cursor.gotoNextSibling()) break;
        }
    }

    // Distribute LHS into the array
    if (lhs_node) |lhs| {
        const lhs_pattern = try astToPattern(allocator, source, lhs);
        for (lhs_pattern.root) |lhs_child| {
            try nodes.append(allocator, try lhs_child.copy(allocator));
        }
    }

    // Create RHS wrapper node
    const rhs_pattern = if (rhs_node) |rhs|
        try astToPattern(allocator, source, rhs)
    else
        Pattern{ .root = &[_]Node{}, .height = 0 };

    // Determine the wrapper type based on operator
    const wrapper_node = convertRHS(allocator, node_kind, op_symbol, rhs_pattern) catch |e| {
        panic("Error converting RHS for operator '{s}': {}", .{ node_kind, e });
    };

    try nodes.append(allocator, wrapper_node);

    const node_slice = try nodes.toOwnedSlice(allocator);
    var max_height: usize = 0;
    for (node_slice) |n| {
        const h = getNodeHeight(n);
        if (h > max_height) max_height = h;
    }

    print("Operator result: {} nodes, height {}\n", .{ node_slice.len, max_height });
    return .{ .root = node_slice, .height = max_height + 1 };
}

fn parseTermNode(
    allocator: Allocator,
    source: []const u8,
    node: AstNode,
) error{OutOfMemory}!?Node {
    const node_kind = node.kind();
    const start_byte = node.startByte();
    const end_byte = node.endByte();
    const text = source[start_byte..end_byte];

    if (!node.isNamed()) return null;

    const NodeKind = enum {
        key,
        variable,
        number,
        string,
        symbol,
        nested_pattern,
        nested_trie,
        quote,
    };

    const kind = std.meta.stringToEnum(NodeKind, node_kind) orelse {
        // For operator nodes at term level, recurse
        return Node{ .pattern = try astToPattern(allocator, source, node) };
    };

    return switch (kind) {
        .key, .number, .string, .symbol => Node{ .key = text },
        .variable => Node{ .variable = text },
        .nested_pattern => Node{ .pattern = try astToPattern(allocator, source, node) },
        .nested_trie => Node{ .trie = @panic("nested_trie unimplemented") },
        .quote => Node{ .pattern = try astToPattern(allocator, source, node) },
    };
}

fn getNodeHeight(node: Node) usize {
    return switch (node) {
        .pattern, .infix, .match, .arrow, .list => |p| p.height,
        .trie => 1,
        else => 0,
    };
}

fn convertRHS(
    allocator: Allocator,
    node_kind: []const u8,
    op_symbol: ?[]const u8,
    rhs_pattern: Pattern,
) !Node {
    return if (mem.eql(u8, node_kind, "terms"))
        Node{ .pattern = rhs_pattern }
    else if (mem.eql(u8, node_kind, "semicolon"))
        Node{ .list = rhs_pattern }
    else if (mem.eql(u8, node_kind, "comma"))
        Node{ .list = rhs_pattern }
    else if (mem.eql(u8, node_kind, "long_match") or mem.eql(u8, node_kind, "match"))
        Node{ .match = rhs_pattern }
    else if (mem.eql(u8, node_kind, "long_arrow") or mem.eql(u8, node_kind, "arrow"))
        Node{ .arrow = rhs_pattern }
    else if (mem.eql(u8, node_kind, "infix")) blk: {
        // For infix, include the operator symbol in the pattern
        var infix_nodes = std.ArrayList(Node){};
        errdefer {
            for (infix_nodes.items) |n| n.deinit(allocator);
            infix_nodes.deinit(allocator);
        }
        if (op_symbol) |sym| {
            try infix_nodes.append(allocator, Node{ .key = sym });
        }
        for (rhs_pattern.root) |rhs_child| {
            try infix_nodes.append(allocator, try rhs_child.copy(allocator));
        }
        const infix_slice = try infix_nodes.toOwnedSlice(allocator);
        var max_h: usize = 0;
        for (infix_slice) |n| {
            const h = getNodeHeight(n);
            if (h > max_h) max_h = h;
        }
        break :blk Node{ .infix = .{ .root = infix_slice, .height = max_h + 1 } };
    } else Node{ .pattern = .{ .root = &[_]Node{}, .height = 0 } };
}
