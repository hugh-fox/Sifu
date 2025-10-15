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
const Node = @import("trie.zig").Node;
const Trie = @import("trie.zig").Trie;
const Pattern = @import("trie.zig").Pattern;

pub const AstNode = union(enum) {
    key: []const u8,
    variable: []const u8,
    var_pattern: []const u8,
    pattern: []const AstNode,
    infix: struct {
        op: []const u8,
        expr: []const AstNode,
    },
    match: []const AstNode,
    arrow: []const AstNode,
    list: []const AstNode,
    trie: []const []const AstNode,

    fn deinitSlice(slice: []const AstNode, allocator: Allocator) void {
        for (slice) |*node| {
            var n = node.*;
            n.deinit(allocator);
        }
        allocator.free(slice);
    }

    pub fn deinit(self: *AstNode, allocator: Allocator) void {
        switch (self.*) {
            .pattern => |nodes| {
                for (nodes) |*node| {
                    var n = node.*;
                    n.deinit(allocator);
                }
                allocator.free(nodes);
            },
            .infix => |nodes| {
                allocator.free(nodes.op);
                deinitSlice(nodes.expr, allocator);
                allocator.free(nodes.expr);
            },
            .match, .arrow => |nodes| {
                deinitSlice(nodes, allocator);
                allocator.free(nodes);
            },
            .list, .trie => |nodes| {
                // for (nodes) |*node| {
                //     var n = node.*;
                //     n.deinit(allocator);
                // }
                deinitSlice(nodes, allocator);
                allocator.free(nodes);
            },
            else => {},
        }
    }
};

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
pub fn astNodeToTrie(allocator: Allocator, ast: AstNode) error{OutOfMemory}!Node {
    return switch (ast) {
        .key => |k| Node{ .key = k },
        .variable => |v| Node{ .variable = v },
        .var_pattern => |vp| Node{ .var_pattern = vp },
        .pattern => |nodes| {
            const pattern = try astSliceToPattern(allocator, nodes);
            return Node{ .pattern = pattern };
        },
        .infix => |inf| {
            const expr_node = try astSliceToPattern(allocator, inf.expr);
            return Node{ .infix = expr_node };
        },
        .match => |expr| {
            const expr_node = try astSliceToPattern(allocator, expr);
            return Node{ .match = expr_node };
        },
        .arrow => |expr| {
            const expr_node = try astSliceToPattern(allocator, expr);
            return Node{ .arrow = expr_node };
        },
        .list => |expr| {
            const expr_node = try astSliceToPattern(allocator, expr);
            return Node{ .list = expr_node };
        },
        .trie => |nodes| {
            var trie = Trie{};
            for (nodes) |node| {
                const len = node.len;
                if (len > 0 and node[len - 1] == .arrow)
                    try trie.append(
                        allocator,
                        Pattern{
                            .root = node[0 .. len - 2],
                            // TOOD: replace this with a counter
                            .height = 0,
                        },
                        node[len - 1],
                    );
                try trie.append(allocator, node, null);
            }
            return Node{ .trie = trie };
        },
    };
}

fn getNodeHeight(node: Node) usize {
    return switch (node) {
        .pattern, .infix, .match, .arrow, .list => |p| p.height,
        .trie => 1,
        else => 0,
    };
}
