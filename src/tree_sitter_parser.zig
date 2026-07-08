/// This file converts tree-sitter's parser output into Sifu's AST.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const mem = std.mem;
const math = std.math;
const Order = math.Order;
const Wyhash = std.hash.Wyhash;
const array_hash_map = std.array_hash_map;
const AutoContext = std.array_hash_map.AutoContext;
const StringContext = std.array_hash_map.StringContext;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const DoublyLinkedList = std.DoublyLinkedList;
const assert = std.debug.assert;
const panic = std.debug.panic;
const verbose_errors = @import("build_options").verbose_errors;
const debug_mode = @import("builtin").mode == .Debug;
const Trie = @import("sifu/trie.zig").Trie;
const Pattern = @import("sifu/trie.zig").Pattern;
const Node = @import("sifu/trie.zig").Node;
const debug = std.log.debug;

pub const parser = @import("tree_sitter_sifu");
const Ast = parser.Tree;
const AstNode = parser.Node;
const AstCursor = parser.TreeCursor;

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
// TODO: handle mismatching parentheses
pub fn astToPattern(
    allocator: Allocator,
    source: []const u8,
    node: AstNode,
) error{OutOfMemory}!Pattern {
    const node_kind = node.kind();

    // debug("Parsing node of type '{s}' with {} children", .{ node_kind, node.childCount() });

    // Check if this is an operator node
    const is_operator = mem.eql(u8, node_kind, "semicolon") or
        mem.eql(u8, node_kind, "newline_sep") or
        mem.eql(u8, node_kind, "long_match") or
        mem.eql(u8, node_kind, "long_arrow") or
        mem.eql(u8, node_kind, "comma") or
        mem.eql(u8, node_kind, "indent_group") or
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
            debug("  Unwrapping nested_pattern, child kind {s}", .{child.kind()});
            return try astToPattern(allocator, source, child);
        }
    }

    // Handle non-operator nodes by flattening their children
    var nodes = std.ArrayList(Node).empty;
    errdefer {
        for (nodes.items) |n| n.deinit(allocator);
        nodes.deinit(allocator);
    }
    var max_child: usize = 0;

    var cursor = node.walk();
    if (cursor.gotoFirstChild()) {
        while (true) {
            const child = cursor.node();
            // Parse the child
            if (try parseTermNode(allocator, source, child)) |parsed_node| {
                max_child = @max(max_child, parsed_node.height());
                try nodes.append(allocator, parsed_node);
            } else if (child.isNamed()) {
                // Operator node - recurse and append result nodes directly
                const sub_pattern = try astToPattern(allocator, source, child);
                defer allocator.free(sub_pattern.root);
                max_child = @max(max_child, sub_pattern.height -| 1);
                try nodes.appendSlice(allocator, sub_pattern.root);
            }

            if (!cursor.gotoNextSibling()) break;
        }
    }

    const node_slice = try nodes.toOwnedSlice(allocator);
    return .{ .root = node_slice, .height = if (node_slice.len > 0) max_child + 1 else 0 };
}

fn parseOperatorNode(
    allocator: Allocator,
    source: []const u8,
    node: AstNode,
    node_kind: []const u8,
) error{OutOfMemory}!Pattern {
    // debug("Parsing operator '{s}'", .{node_kind});
    var nodes = std.ArrayList(Node).empty;
    errdefer {
        for (nodes.items) |n| n.deinit(allocator);
        nodes.deinit(allocator);
    }
    // For built-in operators without operands, all three of these are null
    var lhs_node: ?AstNode = null;
    var rhs_node: ?AstNode = null;
    var op_symbol: ?[]const u8 = null;
    // Literal separating whitespace for newline_sep/indent_group, kept so the
    // printer can reproduce the exact layout.
    var ws: []const u8 = "";

    // Extract LHS, RHS, and operator symbol (for infix)
    var cursor = node.walk();
    if (cursor.gotoFirstChild()) {
        while (true) {
            const child = cursor.node();
            const field_name = cursor.fieldName();

            if (field_name) |fname| {
                // debug("  Field '{s}': {s}", .{ fname, child.kind() });
                if (mem.eql(u8, fname, "lhs")) {
                    lhs_node = child;
                } else if (mem.eql(u8, fname, "rhs")) {
                    rhs_node = child;
                } else if (mem.eql(u8, fname, "op")) {
                    const start = child.startByte();
                    const end = child.endByte();
                    op_symbol = source[start..end];
                }
            } else if (mem.eql(u8, child.kind(), "newline") or
                mem.eql(u8, child.kind(), "indent"))
            {
                // Literal separating whitespace (newline + indentation).
                ws = source[child.startByte()..child.endByte()];
            }

            if (!cursor.gotoNextSibling()) break;
        }
    }
    // Distribute LHS into the array
    var max_child: usize = 0;
    if (lhs_node) |lhs| {
        var lhs_pattern = try astToPattern(allocator, source, lhs);
        defer lhs_pattern.deinit(allocator);
        max_child = lhs_pattern.height -| 1;
        for (lhs_pattern.root) |lhs_child| {
            try nodes.append(allocator, try lhs_child.copy(allocator));
        }
    }
    // Create RHS wrapper node
    var rhs_pattern = if (rhs_node) |rhs|
        try astToPattern(allocator, source, rhs)
    else
        Pattern{ .root = &[_]Node{}, .height = 0 };

    // Determine the wrapper type based on operator
    const wrapper_node = convertRHS(allocator, node_kind, op_symbol, ws, &rhs_pattern) catch |e| {
        panic("Error converting RHS for operator '{s}': {}", .{ node_kind, e });
    };
    // try nodes.append(allocator, Node{ .pattern = lhs_pattern });
    // debug("wrapper node type {s}", .{@tagName(wrapper_node)});
    max_child = @max(max_child, wrapper_node.height());
    try nodes.append(allocator, wrapper_node);

    const node_slice = try nodes.toOwnedSlice(allocator);
    // debug("Operator result: {} nodes, height {}", .{ node_slice.len, max_child });
    return .{ .root = node_slice, .height = max_child + 1 };
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
        var_pattern,
        number,
        string,
        symbol,
        nested_pattern,
        nested_trie,
        quote,
        comment,
    };

    const kind = std.meta.stringToEnum(NodeKind, node_kind) orelse {
        // For operator nodes at term level, return null and let caller handle
        return null;
    };

    return switch (kind) {
        .key, .number, .string, .symbol => Node{ .constant = text },
        .variable => Node{ .variable = text },
        .var_pattern => Node{ .variable = text },
        .comment => Node{ .comment = text },
        .nested_pattern => Node{ .pattern = try astToPattern(allocator, source, node) },
        .nested_trie => Node{ .trie = try astToTrie(allocator, source, node.childByFieldName("inner")) },
        .quote => Node{ .pattern = try astToPattern(allocator, source, node) },
    };
}

fn convertRHS(
    allocator: Allocator,
    node_kind: []const u8,
    op_symbol: ?[]const u8,
    ws: []const u8,
    rhs_pattern: *Pattern,
) !Node {
    _ = allocator;
    // For most operators, we consume the pattern by moving it into the Node.
    // For infix, we copy the contents and must free the original.
    if (mem.eql(u8, node_kind, "terms")) {
        defer rhs_pattern.* = .{};
        return Node{ .pattern = rhs_pattern.* };
    } else if (mem.eql(u8, node_kind, "semicolon")) {
        defer rhs_pattern.* = .{};
        return Node{ .list = rhs_pattern.* };
    } else if (mem.eql(u8, node_kind, "newline_sep")) {
        defer rhs_pattern.* = .{};
        return Node{ .newline = .{ .ws = ws, .rhs = rhs_pattern.* } };
    } else if (mem.eql(u8, node_kind, "comma")) {
        defer rhs_pattern.* = .{};
        return Node{ .list = rhs_pattern.* };
    } else if (mem.eql(u8, node_kind, "indent_group")) {
        defer rhs_pattern.* = .{};
        return Node{ .indent = .{ .ws = ws, .rhs = rhs_pattern.* } };
    } else if (mem.eql(u8, node_kind, "long_match") or mem.eql(u8, node_kind, "match")) {
        defer rhs_pattern.* = .{};
        return Node{ .match = rhs_pattern.* };
    } else if (mem.eql(u8, node_kind, "long_arrow") or mem.eql(u8, node_kind, "arrow")) {
        defer rhs_pattern.* = .{};
        return Node{ .arrow = rhs_pattern.* };
    } else if (mem.eql(u8, node_kind, "infix")) {
        // The operator symbol is stored out-of-band; the operands move into
        // the node's rhs pattern (consumed like the other operators above).
        defer rhs_pattern.* = .{};
        return Node{ .infix = .{ .op = op_symbol orelse "", .rhs = rhs_pattern.* } };
    } else {
        defer rhs_pattern.* = .{};
        return Node{ .pattern = .{ .root = &[_]Node{}, .height = 0 } };
    }
}

fn astToTrie(
    allocator: Allocator,
    source: []const u8,
    inner_node: ?AstNode,
) error{OutOfMemory}!Trie {
    var trie = Trie{};
    errdefer trie.deinit(allocator);
    if (inner_node) |node|
        try appendAstEntries(allocator, source, &trie, node);
    return trie;
}

fn isEntrySeparator(kind: []const u8) bool {
    return mem.eql(u8, kind, "semicolon") or
        mem.eql(u8, kind, "newline_sep") or
        mem.eql(u8, kind, "comma") or
        mem.eql(u8, kind, "indent_group");
}

/// Walk a brace body straight into the trie, splitting at the separator nodes
/// the grammar already provides instead of materializing the whole body as a
/// Pattern. Each leaf entry becomes its own small Pattern and is handed to
/// `Trie.appendEntry` — the same entry semantics the Zig parser uses, so both
/// arrive at the same trie.
fn appendAstEntries(
    allocator: Allocator,
    source: []const u8,
    trie: *Trie,
    node: AstNode,
) error{OutOfMemory}!void {
    if (isEntrySeparator(node.kind())) {
        if (node.childByFieldName("lhs")) |lhs|
            try appendAstEntries(allocator, source, trie, lhs);
        if (node.childByFieldName("rhs")) |rhs|
            try appendAstEntries(allocator, source, trie, rhs);
        return;
    }
    var entry = try astToPattern(allocator, source, node);
    defer entry.deinit(allocator);
    try trie.appendEntry(allocator, entry);
}

