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
    char: u8,
    match: Pattern,
    arrow: Pattern,
    list: Pattern,
    /// A single element in a semicolon separated list, with the `;` elided.
    /// Distinct from `.list` (comma): a lower-precedence separator that prints
    /// as `;` and matches on its own `;` key, but is otherwise evaluated like a
    /// list.
    semicolon: Pattern,
    /// A newline-separated entry. Evaluated like list/semicolon but carries the
    /// literal newline whitespace for pretty-print isomorphism.
    newline: Sep,
    /// An indentation-grouped entry. Evaluated like a comma/list but carries the
    /// literal newline + indentation whitespace, printed as a deeper-indented
    /// group, for pretty-print isomorphism (the WAT folded form).
    indent: Sep,
    /// An expression in braces.
    trie: Trie,
    /// A source comment (`# ...` up to end of line, `#` included). Comments
    /// are preserved as nodes so the parse is layout-faithful; they carry no
    /// semantics and are removed before matching by interpreter comments.step.
    comment: []const u8,

    /// Performs a deep copy, resulting in a Node the same size as the
    /// original. Does not deep copy keys or vars.
    /// The copy should be freed with `deinit`.
    pub fn copy(
        self: Node,
        allocator: Allocator,
    ) Allocator.Error!Node {
        return switch (self) {
            inline .constant, .char, .variable, .comment => self,
            .pattern => |p| Node.ofPattern(try p.copy(allocator)),
            .infix => |inf| Node{ .infix = .{ .op = inf.op, .rhs = try inf.rhs.copy(allocator) } },
            inline .newline, .indent => |sep, tag| @unionInit(
                Node,
                @tagName(tag),
                .{ .ws = sep.ws, .rhs = try sep.rhs.copy(allocator) },
            ),
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
            .constant, .char, .variable, .comment => {},
            .trie => |*trie| @constCast(trie).deinit(allocator),
            .infix => |*inf| @constCast(&inf.rhs).deinit(allocator),
            .newline, .indent => |*sep| @constCast(&sep.rhs).deinit(allocator),
            inline else => |*pattern| @constCast(pattern).deinit(allocator),
        }
    }

    pub fn eql(node: Node, other: Node) bool {
        return if (@intFromEnum(node) != @intFromEnum(other))
            false
        else switch (node) {
            .constant => |constant| mem.eql(u8, constant, other.constant),
            .char => |c| mem.eql(u8, c, other.char),
            .variable => |variable| mem.eql(u8, variable, other.variable),
            .comment => |comment| mem.eql(u8, comment, other.comment),
            .trie => |trie| trie.eql(other.trie),
            .infix => |inf| mem.eql(u8, inf.op, other.infix.op) and
                inf.rhs.eql(other.infix.rhs),
            // Whitespace is layout-only; compare the following pattern.
            .newline => |sep| sep.rhs.eql(other.newline.rhs),
            .indent => |sep| sep.rhs.eql(other.indent.rhs),
            inline else => |pattern, tag| pattern
                .eql(@field(other, @tagName(tag))),
        };
    }
    pub fn ofConstant(constant: []const u8) Node {
        return .{ .constant = constant };
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
    pub fn ofComment(comment: []const u8) Node {
        return .{ .comment = comment };
    }

    pub fn createConstant(
        allocator: Allocator,
        constant: []const u8,
    ) Allocator.Error!*Node {
        const node = try allocator.create(Node);
        node.* = Node{ .constant = constant };
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
            .constant, .char, .variable, .comment, .pattern, .trie => false,
            else => true,
        };
    }

    pub fn isCommaConstant(self: Node) bool {
        return self == .constant and mem.eql(u8, self.constant, ",");
    }

    pub fn height(self: Node) usize {
        return switch (self) {
            .pattern, .match, .arrow, .list, .semicolon => |p| p.height,
            .newline, .indent => |sep| sep.rhs.height,
            .infix => |inf| inf.rhs.height,
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
            .constant => |constant| _ = try writer.writeAll(constant),
            .char => |c| try writer.writeAll(c),
            .variable => |variable| try writer.writeAll(variable),
            .comment => |comment| try writer.writeAll(comment),
            .trie => |*trie| try trie.writeIndent(
                writer,
                optional_indent,
            ),
            .pattern => |pattern| {
                try writer.writeByte('(');
                try pattern.writeIndent(writer, optional_indent);
                try writer.writeByte(')');
            },
            // Write the operator symbol followed by its operands (if any),
            // mirroring how infixes appear in source (`a + b`).
            .infix => |inf| {
                try writer.writeAll(inf.op);
                if (inf.rhs.root.len > 0) {
                    try writer.writeByte(' ');
                    try inf.rhs.writeIndent(writer, optional_indent);
                }
            },
            // Whitespace separators reproduce their literal layout, then the
            // pattern that follows.
            .newline, .indent => |sep| {
                try writer.writeAll(sep.ws);
                try sep.rhs.writeIndent(writer, optional_indent);
            },
            // Don't write an s-exp as its redundant for ops
            inline else => |pattern, tag| {
                switch (tag) {
                    .arrow => try writer.writeAll("-> "),
                    .match => try writer.writeAll(": "),
                    .list => try writer.writeAll(", "),
                    .semicolon => try writer.writeAll("; "),
                    else => {},
                }
                try pattern.writeIndent(writer, optional_indent);
            },
        }
    }
};
