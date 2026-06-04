const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;
const Io = std.Io;
const Writer = Io.Writer;

const Pattern = @import("pattern.zig").Pattern;
const Trie = @import("trie.zig").Trie;

/// Nodes form the keys and values of a pattern type (its recursive structure
/// forces both to be the same type). In Sifu, it is also the structure given
/// to a source code entry (a `Node(Token)`). It encodes sequences, nesting,
/// and patterns. It could also be a simple type for optimization purposes. Sifu
/// maps the syntax described below to this data structure, but that syntax is
/// otherwise irrelevant. Any infix operator that isn't a builtin (match, arrow
/// or list) is parsed into a pattern. These are ordered in their precedence, which
/// is used during parsing.
/// A pattern (a list of nodes) Node.
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
    /// If the variable starts with '*', it matches patterns as a term
    /// (var_pattern behavior), needed for matching patterns with ops
    /// where the nested pattern is implicit.
    variable: []const u8,
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
    /// C -> 123`.
    arrow: Pattern,
    /// A single element in comma separated list, with the comma elided.
    /// Lists are operators that are recognized as separators for
    /// patterns.
    list: Pattern,
    /// A newline-separated entry. Like list/semicolon but uses newline
    /// for pretty-print isomorphism.
    newline: Pattern,
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
            inline .key, .variable => self,
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
            .key, .variable => {},
            .trie => |*trie| @constCast(trie).deinit(allocator),
            inline else => |*pattern| @constCast(pattern).deinit(allocator),
        }
    }

    pub fn eql(node: Node, other: Node) bool {
        return if (@intFromEnum(node) != @intFromEnum(other))
            false
        else switch (node) {
            .key => |key| mem.eql(u8, key, other.key),
            .variable => |variable| mem.eql(u8, variable, other.variable),
            .trie => |trie| trie.eql(other.trie),
            inline else => |pattern, tag| pattern
                .eql(@field(other, @tagName(tag))),
        };
    }
    pub fn ofKey(key: []const u8) Node {
        return .{ .key = key };
    }
    pub fn ofVar(variable: []const u8) Node {
        return .{ .variable = variable };
    }
    pub fn ofVarPattern(var_pattern: []const u8) Node {
        return .{ .variable = var_pattern };
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
            .key, .variable, .pattern, .trie => false,
            else => true,
        };
    }

    pub fn isCommaKey(self: Node) bool {
        return self == .key and mem.eql(u8, self.key, ",");
    }

    pub fn height(self: Node) usize {
        return switch (self) {
            .pattern, .infix, .match, .arrow, .list, .newline => |p| p.height,
            else => 0,
        };
    }

    pub fn formatSExp(
        self: Node,
        allocator: Allocator,
    ) ![]const u8 {
        var buff: std.ArrayList(u8) = try .initCapacity(allocator, 1024);
        defer buff.deinit(allocator);
        var writer = Io.Writer.fromArrayList(&buff);
        try self.writeSExp(&writer, null);
        return buff.toOwnedSlice(allocator);
    }

    pub fn writeSExp(
        self: *Node,
        writer: *Writer,
        optional_indent: ?usize,
    ) !void {
        for (0..optional_indent orelse 0) |_|
            try writer.writeByte(' ');
        switch (self.*) {
            .key => |key| _ = try writer.writeAll(key),
            .variable => |variable| try writer.writeAll(variable),
            .trie => |*trie| try trie.writeIndent(
                writer,
                optional_indent,
            ),
            .pattern => |pattern| {
                try writer.writeByte('(');
                try pattern.writeIndent(writer, optional_indent);
                try writer.writeByte(')');
            },
            // Don't write an s-exp as its redundant for ops
            inline else => |pattern, tag| {
                switch (tag) {
                    .arrow => try writer.writeAll("-> "),
                    .match => try writer.writeAll(": "),
                    .list => try writer.writeAll(", "),
                    .newline => try writer.writeByte('\n'),
                    else => {},
                }
                try pattern.writeIndent(writer, optional_indent);
            },
        }
    }
};
