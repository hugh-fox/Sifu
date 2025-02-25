const std = @import("std");
const Allocator = std.mem.Allocator;
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
const Trie = @import("trie.zig").Trie;

/// Describes the height and width of an Pattern (the level of nesting and
/// length of the root array respectively)
pub const Dimension = struct {
    height: usize,
    width: usize,
};

/// Nodes form the keys and values of a pattern type (its recursive structure
/// forces both to be the same type). In Sifu, it is also the structure given
/// to a source code entry (a `Node(Token)`). It encodes sequences, nesting,
/// and patterns. It could also be a simple type for optimization purposes. Sifu
/// maps the syntax described below to this data structure, but that syntax is
/// otherwise irrelevant. Any infix operator that isn't a builtin (match, arrow
/// or list) is parsed into a pattern. These are ordered in their precedence, which
/// is used during parsing.
pub const Pattern = struct {
    root: []const Node = &.{},
    height: usize = 1, // patterns have a height because they are a branch

    pub fn isEmpty(self: Pattern) bool {
        return self.root.len == 0;
    }

    /// A pattern (a list of nodes) Node with its height cached.
    pub const Node = union(enum) {
        /// A unique constant, literal values. Uniqueness when in a pattern
        /// arises from NodeMap referencing the same value multiple times
        /// (based on Literal.eql).
        key: []const u8,
        /// A Var matches and stores a locally-unique key. During rewriting,
        /// whenever the key is encountered again, it is rewritten to this
        /// pattern's value. A Var pattern matches anything, including nested
        /// patterns. It only makes sense to match anything after trying to
        /// match something specific, so Vars always successfully match (if
        /// there is a Var) after a Key or Subpat match fails.
        variable: []const u8,
        /// Variables that match patterns as a term. These are only strictly
        /// needed for matching patterns with ops, where the nested patterns
        /// is implicit.
        var_pattern: []const u8,
        /// Spaces separated juxtaposition, or lists/parens for nested patterns.
        /// Infix operators add their rhs as a nested patterns after themselves.
        pattern: Pattern,
        /// The list following a non-builtin operator.
        infix: Pattern,
        /// A postfix encoded match pattern, i.e. `x : Int -> x * 2` where
        /// some node (`x`) must match some subpattern (`Int`) in order for
        /// the rest of the match to continue. Like infixes, the patterns to
        /// the left form their own subpatterns, stored here, but the `:` token
        /// is elided.
        match: Pattern,
        /// A postfix encoded arrow expression denoting a rewrite, i.e. `A B
        /// C -> 123`. This includes "long" versions of ops, which have same
        /// semantics, but only play a in part parsing/printing. Parsing
        /// shouldn't concern this abstract data structure, and there is
        /// enough information preserved such that during printing, the
        /// correct precedence operator can be recreated.
        arrow: Pattern,
        /// TODO: remove. These are here temporarily until the parser is
        /// refactored to determine precedence by tracking tokens instead of
        /// nodes. The pretty printer must also then reconstruct the correct
        /// tokens based on the precedence needed to preserve a given Ast's
        /// structure.
        long_match: Pattern,
        long_arrow: Pattern,
        long_list: Pattern,
        /// A single element in comma separated list, with the comma elided.
        /// Lists are operators that are recognized as separators for
        /// patterns.
        list: Pattern,
        /// An expression in braces.
        trie: Trie,

        /// Performs a deep copy, resulting in a Node the same size as the
        /// original. Does not deep copy keys or vars.
        /// The copy should be freed with `deinit`.
        pub fn copy(
            self: Node,
            allocator: Allocator,
        ) Allocator.Error!Node {
            return switch (self) {
                inline .key, .variable, .var_pattern => self,
                .pattern => |p| Node.ofPattern(try p.copy(allocator)),
                inline else => |pattern, tag| @unionInit(
                    Node,
                    @tagName(tag),
                    try pattern.copy(allocator),
                ),
            };
        }

        // Same as copy but allocates the root
        pub fn clone(self: Node, allocator: Allocator) !*Node {
            const self_copy = try allocator.create(Node);
            self_copy.* = try self.copy(allocator);
            return self_copy;
        }

        pub fn destroy(self: *Node, allocator: Allocator) void {
            self.deinit(allocator);
            allocator.destroy(self);
        }

        pub fn deinit(self: Node, allocator: Allocator) void {
            switch (self) {
                .key, .variable, .var_pattern => {},
                .trie => |*trie| @constCast(trie).deinit(allocator),
                inline else => |pattern| pattern.deinit(allocator),
            }
        }

        pub const hash = util.hashFromHasherUpdate(Node);

        pub fn hasherUpdate(self: Node, hasher: anytype) void {
            hasher.update(&mem.toBytes(@intFromEnum(self)));
            switch (self) {
                // Variables are always the same hash in patterns (in
                // varmaps they need unique hashes)
                // TODO: differentiate between repeated and unique vars
                .key, .variable, .var_pattern => |slice| hasher.update(
                    &mem.toBytes(slice),
                ),
                .pattern => |pattern| pattern.hasherUpdate(hasher),
                inline else => |pattern, tag| {
                    switch (tag) {
                        .arrow, .long_arrow => hasher.update("->"),
                        .match, .long_match => hasher.update(":"),
                        .list => hasher.update(","),
                        else => {},
                    }
                    pattern.hasherUpdate(hasher);
                },
            }
        }

        pub fn eql(node: Node, other: Node) bool {
            return if (@intFromEnum(node) != @intFromEnum(other))
                false
            else switch (node) {
                .key => |key| mem.eql(key, other.key),
                // TODO: make exact comparisons work with single place
                // pattern in hashmaps
                // .variable => |v| Ctx.eql(undefined, v, other.variable, undefined),
                .variable => other == .variable,
                .var_pattern => other == .var_pattern,
                .trie => |trie| trie.eql(other.trie),
                inline else => |pattern| pattern.eql(other.pattern),
            };
        }
        pub fn ofKey(key: []const u8) Node {
            return .{ .key = key };
        }
        pub fn ofVar(variable: []const u8) Node {
            return .{ .variable = variable };
        }
        pub fn ofVarPattern(var_pattern: []const u8) Node {
            return .{ .var_pattern = var_pattern };
        }

        pub fn ofPattern(pattern: Pattern) Node {
            return .{ .pattern = pattern };
        }

        pub fn createKey(
            allocator: Allocator,
            key: []const u8,
        ) Allocator.Error!*Node {
            const node = try allocator.create(Node);
            node.* = Node{ .key = key };
            return node;
        }

        /// Lifetime of `pattern` must be longer than this Node.
        pub fn createPattern(
            allocator: Allocator,
            pattern: Pattern,
        ) Allocator.Error!*Node {
            const node = try allocator.create(Node);
            node.* = Node{ .pattern = pattern };
            return node;
        }

        pub fn isOp(self: Node) bool {
            return switch (self) {
                .key, .variable, .pattern, .var_pattern, .trie => false,
                else => true,
            };
        }

        /// Compares by value, not by len, pos, or pointers.
        pub fn order(self: Node, other: Node) Order {
            const ord = math.order(@intFromEnum(self), @intFromEnum(other));
            return if (ord == .eq)
                switch (self) {
                    .pattern => |pattern| util.orderWith(
                        pattern,
                        other.pattern,
                        Node.order,
                    ),
                    .variable => |v| mem.order(u8, v, other.variable),
                    .key => |key| key.order(other.key),
                    .pattern => |pattern| pattern.order(other.pattern),
                }
            else
                ord;
        }

        pub fn writeSExp(
            self: Node,
            writer: anytype,
            optional_indent: ?usize,
        ) !void {
            for (0..optional_indent orelse 0) |_|
                try writer.writeByte(' ');
            switch (self) {
                .key => |key| _ = try util.genericWrite(key, writer),
                .variable, .var_pattern => |variable| {
                    _ = try util.genericWrite(variable, writer);
                },
                .trie => |trie| try trie.writeIndent(
                    writer,
                    optional_indent,
                ),
                .pattern => |pattern| {
                    try writer.writeByte('(');
                    // Ignore top level parens
                    try pattern.writeIndent(writer, optional_indent);
                    try writer.writeByte(')');
                },
                inline else => |pattern, tag| {
                    switch (tag) {
                        .arrow => try writer.writeAll("-> "),
                        .match => try writer.writeAll(": "),
                        .long_arrow => try writer.writeAll("--> "),
                        .long_match => try writer.writeAll(":: "),
                        .list => try writer.writeAll(", "),
                        else => {},
                    }
                    // Don't write an s-exp as its redundant for ops
                    try pattern.writeIndent(writer, optional_indent);
                },
            }
        }
    };

    pub fn writeIndent(
        self: Pattern,
        writer: anytype,
        optional_indent: ?usize,
    ) @TypeOf(writer).Error!void {
        const slice = self.root;
        if (slice.len == 0)
            return;
        // print("tag: {s}\n", .{@tagName(pattern[0])});
        try slice[0].writeSExp(writer, optional_indent);
        if (slice.len == 1) {
            return;
        } else for (slice[1 .. slice.len - 1]) |pattern| {
            // print("tag: {s}\n", .{@tagName(pattern)});
            try writer.writeByte(' ');
            try pattern.writeSExp(writer, optional_indent);
        }
        try writer.writeByte(' ');
        // print("tag: {s}\n", .{@tagName(pattern[pattern.len - 1])});
        try slice[slice.len - 1]
            .writeSExp(writer, optional_indent);
    }

    pub fn write(
        self: Pattern,
        writer: anytype,
    ) !void {
        return self.writeIndent(writer, 0);
    }

    pub fn toString(self: Pattern, allocator: Allocator) ![]const u8 {
        var buff = std.ArrayList(u8).init(allocator);
        try self.write(buff.writer());
        return buff.toOwnedSlice();
    }

    pub fn copy(self: Pattern, allocator: Allocator) !Pattern {
        const pattern_copy = try allocator.alloc(Node, self.root.len);
        for (self.root, pattern_copy) |pattern, *node_copy|
            node_copy.* = try pattern.copy(allocator);

        return Pattern{
            .root = pattern_copy,
            .height = self.height,
        };
    }
    pub fn clone(self: Pattern, allocator: Allocator) !*Pattern {
        const pattern_copy_ptr = try allocator.create(Pattern);
        pattern_copy_ptr.* = try self.copy(allocator);

        return pattern_copy_ptr;
    }

    // Clears all memory and resets this Pattern's root to an empty pattern.
    pub fn deinit(pattern: Pattern, allocator: Allocator) void {
        for (pattern.root) |*node| {
            @constCast(node).deinit(allocator);
        }
        allocator.free(pattern.root);
    }

    pub fn destroy(self: *Pattern, allocator: Allocator) void {
        self.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn eql(self: Pattern, other: Pattern) bool {
        return self.height == other.height and
            self.root.len == other.root.len and
            for (self.root, other.root) |pattern, other_pattern|
        {
            if (!pattern.eql(other_pattern))
                break false;
        } else true;
    }

    pub fn hasherUpdate(self: Pattern, hasher: anytype) void {
        // Height isn't hashed because it wouldn't add any new
        // information
        for (self.root) |pattern|
            pattern.hasherUpdate(hasher);
    }
};

const Token = @import("syntax.zig").Token;
test "simple ast to pattern" {
    const term = Token{
        .type = .Name,
        .lit = "My-Token",
        .context = 0,
    };
    _ = term;
    const ast = Pattern.Node{
        .key = .{
            .type = .Name,
            .lit = "Some-Other-Token",
            .context = 20,
        },
    };
    _ = ast;
    // _ = Pattern.ofTokenType(term, ast);
}

test "Token equality" {
    const t1 = Token{
        .type = .Name,
        .lit = "Asdf",
        .context = 0,
    };
    const t2 = Token{
        .type = .Name,
        .lit = "Asdf",
        .context = 1,
    };

    try testing.expect(t1.eql(t2));
    try testing.expectEqual(t1.hash(), t2.hash());
}
