///
/// Created by Claude 4.6 from tree-sitter-sifu/grammar.js
/// commit b5feade973d991f19dadddc3e83bfe9f74ec611c
///
/// A recursive descent parser for Sifu. Follows the grammar defined in
/// tree-sitter-sifu/grammar.js.
///
/// Operator precedence (lowest to highest):
///   1. semicolon  ;
///   2. long_match ::  /  long_arrow -->
///   3. comma      ,
///   4. infix      <symbol>
///   5. match      :   /  arrow      ->
///   6. terms      (juxtaposition)
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;
const math = std.math;
const assert = std.debug.assert;
const trie_module = @import("sifu/trie.zig");
const Pattern = trie_module.Pattern;
const Node = trie_module.Node;
const Trie = trie_module.Trie;

const Oom = Allocator.Error;

// ---------------------------------------------------------------------------
// Token
// ---------------------------------------------------------------------------

pub const Tag = enum {
    key,
    variable,
    var_pattern,
    number,
    string,
    symbol,
    semicolon,
    long_match,
    long_arrow,
    comma,
    match,
    arrow,
    left_paren,
    right_paren,
    left_brace,
    right_brace,
    backtick,
    eof,
};

pub const Token = struct {
    tag: Tag,
    start: usize,
    end: usize,

    pub fn text(self: Token, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

// ---------------------------------------------------------------------------
// Lexer
// ---------------------------------------------------------------------------

source: []const u8,
pos: usize = 0,
current: Token = .{ .tag = .eof, .start = 0, .end = 0 },

pub fn init(source: []const u8) Self {
    var self = Self{ .source = source };
    self.current = self.advance();
    return self;
}

fn peek(self: Self) Tag {
    return self.current.tag;
}

fn peekToken(self: Self) Token {
    return self.current;
}

fn eat(self: *Self) Token {
    const tok = self.current;
    self.current = self.advance();
    return tok;
}

fn expect(self: *Self, tag: Tag) ?Token {
    if (self.current.tag == tag) return self.eat();
    return null;
}

fn advance(self: *Self) Token {
    self.skipExtras();
    if (self.pos >= self.source.len)
        return .{ .tag = .eof, .start = self.source.len, .end = self.source.len };

    const c = self.source[self.pos];

    // Single-character delimiters
    switch (c) {
        '(' => return self.single(.left_paren),
        ')' => return self.single(.right_paren),
        '{' => return self.single(.left_brace),
        '}' => return self.single(.right_brace),
        '`' => return self.single(.backtick),
        ';' => return self.single(.semicolon),
        '\n' => {
            // Skip trailing newlines (newline followed only by whitespace/newlines)
            var check_pos = self.pos + 1;
            while (check_pos < self.source.len) : (check_pos += 1) {
                const ch = self.source[check_pos];
                if (ch != ' ' and ch != '\t' and ch != '\r' and ch != '\n') break;
            } else {
                // Only whitespace/newlines until EOF - skip this newline
                self.pos += 1;
                return self.advance();
            }
            return self.single(.semicolon);
        },
        ',' => return self.single(.comma),
        '"' => return self.lexString(),
        else => {},
    }

    // VarPattern: * followed by lowercase
    if (c == '*' and self.pos + 1 < self.source.len and isLower(self.source[self.pos + 1]))
        return self.lexVarPattern();

    if (isUpper(c)) return self.lexKey();
    if (isLower(c)) return self.lexVariable();
    if (isDigit(c)) return self.lexNumber();
    if (isOpChar(c)) return self.lexOperator();

    // Skip unknown bytes
    self.pos += 1;
    return self.advance();
}

fn single(self: *Self, tag: Tag) Token {
    const start = self.pos;
    self.pos += 1;
    return .{ .tag = tag, .start = start, .end = self.pos };
}

fn skipExtras(self: *Self) void {
    while (self.pos < self.source.len) {
        const c = self.source[self.pos];
        if (c == ' ' or c == '\t' or c == '\r') {
            self.pos += 1;
        } else if (c == '#') {
            // Comment: skip to end of line (but not the newline itself)
            while (self.pos < self.source.len and self.source[self.pos] != '\n')
                self.pos += 1;
        } else break;
    }
}

fn lexKey(self: *Self) Token {
    const start = self.pos;
    self.pos += 1;
    while (self.pos < self.source.len and isIdentTail(self.source[self.pos]))
        self.pos += 1;
    return .{ .tag = .key, .start = start, .end = self.pos };
}

fn lexVariable(self: *Self) Token {
    const start = self.pos;
    self.pos += 1;
    while (self.pos < self.source.len and isIdentTail(self.source[self.pos]))
        self.pos += 1;
    return .{ .tag = .variable, .start = start, .end = self.pos };
}

fn lexVarPattern(self: *Self) Token {
    const start = self.pos;
    self.pos += 1; // skip *
    self.pos += 1; // skip first lowercase letter
    while (self.pos < self.source.len and isIdentTail(self.source[self.pos]))
        self.pos += 1;
    return .{ .tag = .var_pattern, .start = start, .end = self.pos };
}

fn lexNumber(self: *Self) Token {
    const start = self.pos;
    while (self.pos < self.source.len and isDigit(self.source[self.pos]))
        self.pos += 1;
    // Optional decimal part
    if (self.pos < self.source.len and self.source[self.pos] == '.') {
        if (self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1])) {
            self.pos += 1; // skip '.'
            while (self.pos < self.source.len and isDigit(self.source[self.pos]))
                self.pos += 1;
        }
    }
    return .{ .tag = .number, .start = start, .end = self.pos };
}

fn lexString(self: *Self) Token {
    const start = self.pos;
    self.pos += 1; // skip opening "
    while (self.pos < self.source.len) {
        if (self.source[self.pos] == '\\' and self.pos + 1 < self.source.len) {
            self.pos += 2; // skip escape sequence
        } else if (self.source[self.pos] == '"') {
            self.pos += 1; // skip closing "
            break;
        } else {
            self.pos += 1;
        }
    }
    return .{ .tag = .string, .start = start, .end = self.pos };
}

fn lexOperator(self: *Self) Token {
    const start = self.pos;
    // Accumulate all consecutive operator characters
    while (self.pos < self.source.len and isOpChar(self.source[self.pos]))
        self.pos += 1;
    const lit = self.source[start..self.pos];
    // Check for reserved operators (exact match on the full run)
    const tag: Tag = if (mem.eql(u8, lit, "-->"))
        .long_arrow
    else if (mem.eql(u8, lit, "->"))
        .arrow
    else if (mem.eql(u8, lit, "::"))
        .long_match
    else if (mem.eql(u8, lit, ":"))
        .match
    else
        .symbol;
    return .{ .tag = tag, .start = start, .end = self.pos };
}

fn isUpper(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}

fn isLower(c: u8) bool {
    return c >= 'a' and c <= 'z';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isIdentTail(c: u8) bool {
    return isUpper(c) or isLower(c) or isDigit(c) or c == '_';
}

fn isOpChar(c: u8) bool {
    return switch (c) {
        ':',
        '!',
        '@',
        '$',
        '%',
        '^',
        '&',
        '*',
        '+',
        '-',
        '=',
        '|',
        '<',
        '>',
        '?',
        '/',
        '\\',
        '~',
        => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Parser – produces Pattern / Node values
// ---------------------------------------------------------------------------

/// Parse the full source into a Pattern. Top-level entry point.
pub fn parsePattern(self: *Self, allocator: Allocator) Oom!Pattern {
    if (self.peek() == .eof) return .{};
    return self.parsePrec1(allocator);
}

/// Prec 1: semicolon (right-associative to match Tree-sitter grammar)
fn parsePrec1(self: *Self, allocator: Allocator) Oom!Pattern {
    // Handle leading semicolon (empty LHS)
    if (self.peek() == .semicolon) {
        _ = self.eat();
        const rhs = try self.parseOptionalPrec1(allocator);
        var nodes = try allocator.alloc(Node, 1);
        nodes[0] = Node{ .list = rhs };
        return patternOf(nodes, rhs.height);
    }

    const lhs = try self.parsePrec2(allocator);
    if (self.peek() != .semicolon) return lhs;

    // Consume semicolon and recursively parse rhs (right-associative)
    _ = self.eat();
    const rhs = try self.parseOptionalPrec1(allocator);

    var nodes = std.ArrayList(Node).empty;
    try nodes.appendSlice(allocator, lhs.root);
    allocator.free(lhs.root);
    try nodes.append(allocator, Node{ .list = rhs });
    const max_child = @max(lhs.height -| 1, rhs.height);
    return patternOf(try nodes.toOwnedSlice(allocator), max_child);
}

fn parseOptionalPrec1(self: *Self, allocator: Allocator) Oom!Pattern {
    if (!self.canStartExpr()) return .{};
    return self.parsePrec1(allocator);
}

fn parseOptionalPrec2(self: *Self, allocator: Allocator) Oom!Pattern {
    if (!self.canStartExpr()) return .{};
    return self.parsePrec2(allocator);
}

/// Prec 2: long_match :: / long_arrow --> (right-recursive for mixed ops)
fn parsePrec2(self: *Self, allocator: Allocator) Oom!Pattern {
    // Handle leading operator (empty LHS)
    if (self.peek() == .long_match or self.peek() == .long_arrow) {
        var nodes = std.ArrayList(Node).empty;
        const op = self.eat();
        const rhs = try self.parseOptionalPrec2(allocator);
        try nodes.append(allocator, wrapOp(op.tag, rhs));
        return patternOf(try nodes.toOwnedSlice(allocator), rhs.height);
    }

    const lhs = try self.parsePrec3(allocator);
    if (self.peek() != .long_match and self.peek() != .long_arrow) return lhs;

    var nodes = std.ArrayList(Node).empty;
    try nodes.appendSlice(allocator, lhs.root);
    allocator.free(lhs.root);

    const op = self.eat();
    const rhs = try self.parseOptionalPrec2(allocator);
    try nodes.append(allocator, wrapOp(op.tag, rhs));
    const max_child = @max(lhs.height -| 1, rhs.height);
    return patternOf(try nodes.toOwnedSlice(allocator), max_child);
}

/// Prec 3: comma (right-associative to match Tree-sitter grammar)
fn parsePrec3(self: *Self, allocator: Allocator) Oom!Pattern {
    if (self.peek() == .comma) {
        // Leading comma: empty lhs
        _ = self.eat();
        const rhs = try self.parseOptionalPrec3(allocator);
        var nodes = try allocator.alloc(Node, 1);
        nodes[0] = Node{ .list = rhs };
        return patternOf(nodes, rhs.height);
    }

    const lhs = try self.parsePrec4(allocator);
    if (self.peek() != .comma) return lhs;

    // Consume comma and recursively parse rhs (right-associative)
    _ = self.eat();
    const rhs = try self.parseOptionalPrec3(allocator);

    var nodes = std.ArrayList(Node).empty;
    try nodes.appendSlice(allocator, lhs.root);
    allocator.free(lhs.root);
    try nodes.append(allocator, Node{ .list = rhs });
    const max_child = @max(lhs.height -| 1, rhs.height);
    return patternOf(try nodes.toOwnedSlice(allocator), max_child);
}

fn parseOptionalPrec3(self: *Self, allocator: Allocator) Oom!Pattern {
    if (!self.canStartExpr()) return .{};
    return self.parsePrec3(allocator);
}

fn parseOptionalPrec4(self: *Self, allocator: Allocator) Oom!Pattern {
    if (!self.canStartExpr()) return .{};
    return self.parsePrec4(allocator);
}

/// Prec 4: infix (left-associative)
///   User-defined symbol operators. The symbol is prepended to the RHS as
///   a key inside an .infix node.
fn parsePrec4(self: *Self, allocator: Allocator) Oom!Pattern {
    const lhs = try self.parsePrec5(allocator);
    if (self.peek() != .symbol) return lhs;

    var nodes = std.ArrayList(Node).empty;
    try nodes.appendSlice(allocator, lhs.root);
    allocator.free(lhs.root);
    var max_child = lhs.height -| 1;

    while (self.peek() == .symbol) {
        const sym_tok = self.eat();
        const sym_text = sym_tok.text(self.source);
        const rhs = try self.parseOptionalPrec5(allocator);

        // Build infix pattern: [op_key, rhs_nodes...]
        // Key has height 0, so infix max_child = rhs.height - 1
        var infix_nodes = std.ArrayList(Node).empty;
        try infix_nodes.append(allocator, Node{ .key = sym_text });
        try infix_nodes.appendSlice(allocator, rhs.root);
        if (rhs.root.len > 0) allocator.free(rhs.root);
        const infix_height = rhs.height -| 1;
        try nodes.append(allocator, Node{
            .infix = patternOf(try infix_nodes.toOwnedSlice(allocator), infix_height),
        });
        max_child = @max(max_child, infix_height + 1);
    }
    return patternOf(try nodes.toOwnedSlice(allocator), max_child);
}

fn parseOptionalPrec5(self: *Self, allocator: Allocator) Oom!Pattern {
    if (!self.canStartExpr()) return .{};
    return self.parsePrec5(allocator);
}

/// Prec 5: match : / arrow -> (right-recursive for mixed ops)
fn parsePrec5(self: *Self, allocator: Allocator) Oom!Pattern {
    if (self.peek() == .match or self.peek() == .arrow) {
        var nodes = std.ArrayList(Node).empty;
        const op = self.eat();
        const rhs = try self.parseOptionalPrec5(allocator);
        try nodes.append(allocator, wrapOp(op.tag, rhs));
        return patternOf(try nodes.toOwnedSlice(allocator), rhs.height);
    }

    const lhs = try self.parseTerms(allocator);
    if (self.peek() != .match and self.peek() != .arrow) return lhs;

    var nodes = std.ArrayList(Node).empty;
    try nodes.appendSlice(allocator, lhs.root);
    allocator.free(lhs.root);

    const op = self.eat();
    const rhs = try self.parseOptionalPrec5(allocator);
    try nodes.append(allocator, wrapOp(op.tag, rhs));
    const max_child = @max(lhs.height -| 1, rhs.height);
    return patternOf(try nodes.toOwnedSlice(allocator), max_child);
}

/// Prec 6: terms (juxtaposition) – one or more terms
fn parseTerms(self: *Self, allocator: Allocator) Oom!Pattern {
    var nodes = std.ArrayList(Node).empty;
    var max_child: usize = 0;
    while (self.canStartTerm()) {
        const node = try self.parseTerm(allocator);
        max_child = @max(max_child, node.height());
        try nodes.append(allocator, node);
    }
    return patternOf(try nodes.toOwnedSlice(allocator), max_child);
}

fn parseTerm(self: *Self, allocator: Allocator) Oom!Node {
    const tok = self.eat();
    return switch (tok.tag) {
        .key, .number, .string => Node{ .key = tok.text(self.source) },
        .variable => Node{ .variable = tok.text(self.source) },
        .var_pattern => Node{ .variable = tok.text(self.source) },
        .left_paren => blk: {
            const inner = try self.parseInner(allocator, .right_paren);
            break :blk Node{ .pattern = inner };
        },
        .left_brace => blk: {
            const inner = try self.parseInner(allocator, .right_brace);
            const trie = try patternToTrie(allocator, inner);
            break :blk Node{ .trie = trie };
        },
        .backtick => blk: {
            const inner = try self.parseInner(allocator, .backtick);
            break :blk Node{ .pattern = inner };
        },
        else => Node{ .key = tok.text(self.source) },
    };
}

fn parseInner(self: *Self, allocator: Allocator, close: Tag) Oom!Pattern {
    if (self.peek() == close) {
        _ = self.eat();
        return .{};
    }
    const inner = try self.parsePrec1(allocator);
    _ = self.expect(close);
    return inner;
}

fn canStartTerm(self: Self) bool {
    return switch (self.current.tag) {
        .key,
        .variable,
        .var_pattern,
        .number,
        .string,
        .left_paren,
        .left_brace,
        .backtick,
        => true,
        else => false,
    };
}

fn canStartExpr(self: Self) bool {
    return self.canStartTerm() or
        self.current.tag == .match or
        self.current.tag == .arrow or
        self.current.tag == .long_match or
        self.current.tag == .long_arrow or
        self.current.tag == .symbol;
}

fn wrapOp(tag: Tag, rhs: Pattern) Node {
    return switch (tag) {
        .semicolon, .comma => Node{ .list = rhs },
        .long_match, .match => Node{ .match = rhs },
        .long_arrow, .arrow => Node{ .arrow = rhs },
        else => Node{ .pattern = rhs },
    };
}

/// Parse the inner content of a trie (without braces) into a Trie structure.
/// The source is expected to be semicolon-separated entries where each entry
/// is a key-value pair (with arrow) or just a key (value = key).
/// For example: `A -> B; C D -> E` becomes a trie with two entries.
pub fn parseTrie(allocator: Allocator, source: []const u8) Oom!Trie {
    var parser = Self.init(source);
    var pattern = try parser.parsePattern(allocator);
    defer pattern.deinit(allocator);
    return patternToTrie(allocator, pattern);
}

fn patternToTrie(allocator: Allocator, pattern: Pattern) Oom!Trie {
    var result = Trie{};

    if (pattern.root.len == 0) return result;

    // With right-associative parsing, multiple entries are nested:
    // "A -> 1; B -> 2" = [A, arrow([1]), list([B, arrow([2])])]
    // We need to recursively process the .list nodes that represent semicolons.
    //
    // Semicolons vs commas:
    // - Semicolons separate trie entries (have arrows in their contents)
    // - Commas are part of pattern structure (no arrows, or arrows nested deeper)
    //
    // Heuristic: A .list at the end of a pattern is a semicolon if it contains
    // an arrow at its top level.

    try appendEntryRecursive(&result, allocator, pattern);
    return result;
}

/// Recursively extract entries from a right-associative pattern.
/// If the pattern ends with a .list containing an arrow, that's a semicolon
/// separator - process the prefix as one entry and recurse on the list contents.
fn appendEntryRecursive(result: *Trie, allocator: Allocator, pattern: Pattern) Oom!void {
    if (pattern.root.len == 0) return;

    // Check if the last element is a .list that might be a semicolon
    const last_idx = pattern.root.len - 1;
    const last_node = pattern.root[last_idx];

    if (last_node == .list) {
        // Check if this list contains an arrow at its top level (semicolon separator)
        var is_semicolon = false;
        for (last_node.list.root) |inner| {
            if (inner == .arrow) {
                is_semicolon = true;
                break;
            }
        }

        if (is_semicolon) {
            // This is a semicolon: prefix is one entry, .list contents are more entries
            if (last_idx > 0) {
                try appendEntry(result, allocator, .{ .root = pattern.root[0..last_idx] });
            }
            // Recursively process the list contents
            try appendEntryRecursive(result, allocator, last_node.list);
            return;
        }
    }

    // No semicolon found - treat entire pattern as a single entry
    try appendEntry(result, allocator, pattern);
}

/// Appends a single entry to the trie. The entry_pattern may contain an arrow
/// indicating key -> value, or just be a pattern (which becomes key = value).
fn appendEntry(result: *Trie, allocator: Allocator, entry_pattern: Pattern) Oom!void {
    if (entry_pattern.root.len == 0) return;

    // Look for an arrow node to split key and value
    var arrow_index: ?usize = null;
    for (entry_pattern.root, 0..) |node, i| {
        if (node == .arrow) {
            arrow_index = i;
            break;
        }
    }

    if (arrow_index) |ai| {
        // Split at arrow: nodes before arrow are key, arrow's pattern is value
        const key = patternFromSlice(entry_pattern.root[0..ai]);
        const value = entry_pattern.root[ai].arrow;
        _ = try result.append(allocator, key, value);
    } else {
        // No arrow - pattern is both key and value
        _ = try result.append(allocator, entry_pattern, entry_pattern);
    }
}

fn patternOf(nodes: []Node, max_child_height: usize) Pattern {
    return .{ .root = nodes, .height = if (nodes.len > 0) max_child_height + 1 else 0 };
}

fn patternFromSlice(nodes: []Node) Pattern {
    var max_child: usize = 0;
    for (nodes) |n| {
        max_child = @max(max_child, n.height());
    }
    return .{ .root = nodes, .height = if (nodes.len > 0) max_child + 1 else 0 };
}

// ---------------------------------------------------------------------------
// Convenience
// ---------------------------------------------------------------------------

pub fn parse(allocator: Allocator, source: []const u8) Oom!Pattern {
    var parser = Self.init(source);
    return parser.parsePattern(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const NodeTag = enum { key, variable, var_pattern, pattern, infix, match, arrow, list, trie };

fn expectNodes(pattern: Pattern, expected_tags: []const NodeTag) !void {
    try testing.expectEqual(expected_tags.len, pattern.root.len);
    for (pattern.root, expected_tags) |node, expected_tag| {
        const actual_tag: NodeTag = switch (node) {
            .key => .key,
            .variable => |v| if (v.len > 0 and v[0] == '*') .var_pattern else .variable,
            .pattern => .pattern,
            .infix => .infix,
            .match => .match,
            .arrow => .arrow,
            .list => .list,
            .trie => .trie,
        };
        try testing.expectEqual(expected_tag, actual_tag);
    }
}

test "empty" {
    const p = try parse(testing.allocator, "");
    try testing.expectEqual(@as(usize, 0), p.root.len);
}

test "single key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "Foo");
    try testing.expectEqual(@as(usize, 1), p.root.len);
    try testing.expectEqualStrings("Foo", p.root[0].key);
}

test "juxtaposition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "A B C");
    try expectNodes(p, &.{ .key, .key, .key });
    try testing.expectEqualStrings("A", p.root[0].key);
    try testing.expectEqualStrings("B", p.root[1].key);
    try testing.expectEqualStrings("C", p.root[2].key);
}

test "variable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "x");
    try expectNodes(p, &.{.variable});
    try testing.expectEqualStrings("x", p.root[0].variable);
}

test "var_pattern" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "*x");
    try expectNodes(p, &.{.var_pattern});
    try testing.expectEqualStrings("*x", p.root[0].variable);
}

test "number" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "42");
    try expectNodes(p, &.{.key});
    try testing.expectEqualStrings("42", p.root[0].key);
}

test "decimal number" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "3.14");
    try expectNodes(p, &.{.key});
    try testing.expectEqualStrings("3.14", p.root[0].key);
}

test "string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "\"hello\"");
    try expectNodes(p, &.{.key});
    try testing.expectEqualStrings("\"hello\"", p.root[0].key);
}

test "arrow: A -> B" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "A -> B");
    // LHS flattened [A], then arrow([B])
    try expectNodes(p, &.{ .key, .arrow });
    try testing.expectEqualStrings("A", p.root[0].key);
    try testing.expectEqualStrings("B", p.root[1].arrow.root[0].key);
}

test "match: x : Int" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "x : Int");
    try expectNodes(p, &.{ .variable, .match });
    try testing.expectEqualStrings("x", p.root[0].variable);
    try testing.expectEqualStrings("Int", p.root[1].match.root[0].key);
}

test "match and arrow: x : Int -> x" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "x : Int -> x");
    // Prec 5 right-recursive: x, match([Int, arrow([x])])
    try expectNodes(p, &.{ .variable, .match });
    const match_pat = p.root[1].match;
    try testing.expectEqual(@as(usize, 2), match_pat.root.len);
    try testing.expectEqualStrings("Int", match_pat.root[0].key);
    try testing.expectEqualStrings("x", match_pat.root[1].arrow.root[0].variable);
}

test "long arrow: A --> B" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "A --> B");
    try expectNodes(p, &.{ .key, .arrow });
    try testing.expectEqualStrings("B", p.root[1].arrow.root[0].key);
}

test "long match: A :: B" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "A :: B");
    try expectNodes(p, &.{ .key, .match });
    try testing.expectEqualStrings("B", p.root[1].match.root[0].key);
}

test "comma: A , B , C" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "A , B , C");
    // Right-assoc: [A, list([B, list([C])])]
    try expectNodes(p, &.{ .key, .list });
    try testing.expectEqualStrings("A", p.root[0].key);
    try testing.expectEqualStrings("B", p.root[1].list.root[0].key);
    try expectNodes(p.root[1].list, &.{ .key, .list });
    try testing.expectEqualStrings("C", p.root[1].list.root[1].list.root[0].key);
}

test "semicolon: A ; B ; C" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "A ; B ; C");
    // Right-assoc: [A, list([B, list([C])])]
    try expectNodes(p, &.{ .key, .list });
    try testing.expectEqualStrings("A", p.root[0].key);
    try testing.expectEqualStrings("B", p.root[1].list.root[0].key);
    try expectNodes(p.root[1].list, &.{ .key, .list });
    try testing.expectEqualStrings("C", p.root[1].list.root[1].list.root[0].key);
}

test "nested pattern: (A B)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "(A B)");
    try expectNodes(p, &.{.pattern});
    const inner = p.root[0].pattern;
    try testing.expectEqual(@as(usize, 2), inner.root.len);
    try testing.expectEqualStrings("A", inner.root[0].key);
    try testing.expectEqualStrings("B", inner.root[1].key);
}

test "nested empty: ()" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "()");
    try expectNodes(p, &.{.pattern});
    try testing.expectEqual(@as(usize, 0), p.root[0].pattern.root.len);
}

test "mixed precedence: A B : C D -> E F" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "A B : C D -> E F");
    // [A, B, match([C, D, arrow([E, F])])]
    try expectNodes(p, &.{ .key, .key, .match });
    const match_pat = p.root[2].match;
    try testing.expectEqual(@as(usize, 3), match_pat.root.len);
    try testing.expectEqualStrings("C", match_pat.root[0].key);
    try testing.expectEqualStrings("D", match_pat.root[1].key);
    const arrow_pat = match_pat.root[2].arrow;
    try testing.expectEqual(@as(usize, 2), arrow_pat.root.len);
    try testing.expectEqualStrings("E", arrow_pat.root[0].key);
    try testing.expectEqualStrings("F", arrow_pat.root[1].key);
}

test "infix: 1 + 2" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "1 + 2");
    // [1, infix([+, 2])]
    try expectNodes(p, &.{ .key, .infix });
    try testing.expectEqualStrings("1", p.root[0].key);
    const infix_pat = p.root[1].infix;
    try testing.expectEqual(@as(usize, 2), infix_pat.root.len);
    try testing.expectEqualStrings("+", infix_pat.root[0].key);
    try testing.expectEqualStrings("2", infix_pat.root[1].key);
}

test "comment skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Newlines are semicolons, so "A # comment\nB" becomes "A; B"
    const p = try parse(arena.allocator(), "A # comment\nB");
    try expectNodes(p, &.{ .key, .list });
    try testing.expectEqualStrings("A", p.root[0].key);
    try testing.expectEqualStrings("B", p.root[1].list.root[0].key);
}

test "empty trie: {}" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "{}");
    try expectNodes(p, &.{.trie});
    try testing.expectEqual(@as(usize, 0), p.root[0].trie.size());
}

test "single entry trie: { A -> B }" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "{ A -> B }");
    try expectNodes(p, &.{.trie});
    const t = p.root[0].trie;
    try testing.expectEqual(@as(usize, 1), t.size());
    // Trie should have entry: A -> B
    try testing.expect(t.map.contains("A"));
}

test "multi-key entry trie: { A B -> C }" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "{ A B -> C }");
    try expectNodes(p, &.{.trie});
    const t = p.root[0].trie;
    try testing.expectEqual(@as(usize, 1), t.size());
    // Trie should have nested entry: A -> B -> value(C)
    try testing.expect(t.map.contains("A"));
    const a_trie = t.map.get("A").?;
    try testing.expect(a_trie.map.contains("B"));
}

test "multi-entry trie: { A -> B; C -> D }" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "{ A -> B; C -> D }");
    try expectNodes(p, &.{.trie});
    const t = p.root[0].trie;
    try testing.expectEqual(@as(usize, 2), t.size());
    try testing.expect(t.map.contains("A"));
    try testing.expect(t.map.contains("C"));
}

test "trie with variable: { x -> x }" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "{ x -> x }");
    try expectNodes(p, &.{.trie});
    const t = p.root[0].trie;
    try testing.expectEqual(@as(usize, 1), t.size());
    try testing.expect(t.map.contains("x"));
}

test "trie key-only entry: { A }" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "{ A }");
    try expectNodes(p, &.{.trie});
    const t = p.root[0].trie;
    try testing.expectEqual(@as(usize, 1), t.size());
    try testing.expect(t.map.contains("A"));
}

test "trie in expression: X { A -> B } Y" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "X { A -> B } Y");
    try expectNodes(p, &.{ .key, .trie, .key });
    try testing.expectEqualStrings("X", p.root[0].key);
    try testing.expectEqualStrings("Y", p.root[2].key);
    const t = p.root[1].trie;
    try testing.expectEqual(@as(usize, 1), t.size());
}

test "trie with 3 entries: { A -> 1; B -> 2; C -> 3 }" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "{ A -> 1; B -> 2; C -> 3 }");
    try expectNodes(p, &.{.trie});
    const t = p.root[0].trie;
    try testing.expectEqual(@as(usize, 3), t.size());
    try testing.expect(t.map.contains("A"));
    try testing.expect(t.map.contains("B"));
    try testing.expect(t.map.contains("C"));
}

test "parseTrie: comma with varpattern - A, *x --> *x" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var trie = try parseTrie(arena.allocator(), "A, *x --> *x");
    // Trie structure: A -> , -> *x (var) -> value(*x)
    try testing.expectEqual(@as(usize, 1), trie.size());
    try testing.expect(trie.map.contains("A"));
    const a_trie = trie.map.get("A").?;
    try testing.expect(a_trie.map.contains(","));
    const comma_trie = a_trie.map.get(",").?;
    // After comma, there should be a variable *x
    try testing.expect(comma_trie.var_branches.items.len > 0);
}
