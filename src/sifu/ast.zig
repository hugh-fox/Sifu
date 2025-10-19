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

/// Convert an AstNode to a Trie
pub fn astNodeToTrie(allocator: Allocator, ast: *parser.Tree) error{OutOfMemory}!Trie {
    print("{s}\n", .{try ast.rootNode().toSexp(allocator)});

    var cursor = ast.walk();
    var queue = ArrayList(AstCursor){};
    defer queue.deinit(allocator);

    try queue.append(allocator, cursor);

    var idx: usize = 0;
    while (idx < queue.items.len) {
        var current = queue.items[idx];
        current.node().format(streams.err) catch unreachable;
        print("{s}: \n", .{current.node().kind()});

        if (current.gotoFirstChild()) {
            try queue.append(allocator, current);
            while (current.gotoNextSibling()) {
                try queue.append(allocator, current);
            }
        }
        if (!cursor.gotoParent()) break;
        try queue.append(allocator, current);

        idx += 1;
    }

    return Trie{};
    // return switch (cursor.fieldName() orelse "") {
    //     .key => |k| Node{ .key = k },
    //     .variable => |v| Node{ .variable = v },
    //     .var_pattern => |vp| Node{ .var_pattern = vp },
    //     .pattern => |nodes| {
    //         const pattern = try astSliceToPattern(allocator, nodes);
    //         return Node{ .pattern = pattern };
    //     },
    //     .infix => |inf| {
    //         const expr_node = try astSliceToPattern(allocator, inf.expr);
    //         return Node{ .infix = expr_node };
    //     },
    //     .match => |expr| {
    //         const expr_node = try astSliceToPattern(allocator, expr);
    //         return Node{ .match = expr_node };
    //     },
    //     .arrow => |expr| {
    //         const expr_node = try astSliceToPattern(allocator, expr);
    //         return Node{ .arrow = expr_node };
    //     },
    //     .list => |expr| {
    //         const expr_node = try astSliceToPattern(allocator, expr);
    //         return Node{ .list = expr_node };
    //     },
    //     .trie => |nodes| {
    //         var trie = Trie{};
    //         for (nodes) |node| {
    //             const len = node.len;
    //             if (len > 0 and node[len - 1] == .arrow)
    //                 try trie.append(
    //                     allocator,
    //                     Pattern{
    //                         .root = node[0 .. len - 2],
    //                         // TOOD: replace this with a counter
    //                         .height = 0,
    //                     },
    //                     node[len - 1],
    //                 );
    //             try trie.append(allocator, node, null);
    //         }
    //         return Node{ .trie = trie };
    //     },
    // };
}

fn getNodeHeight(node: Node) usize {
    return switch (node) {
        .pattern, .infix, .match, .arrow, .list => |p| p.height,
        .trie => 1,
        else => 0,
    };
}
