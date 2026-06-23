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
const comments = @import("interpreter/comments.zig");
const chars = @import("sifu/chars.zig");

const Oom = Allocator.Error;

// ---------------------------------------------------------------------------
// Token
// ---------------------------------------------------------------------------

pub const Tag = enum {
    constant,
    variable,
    var_pattern,
    number,
    string,
    single_string,
    symbol,
    comment,
    semicolon,
    newline,
    indent,
    comma,
    long_match,
    long_arrow,
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
/// Nesting depth of `(`/`{`. Newlines only act as line-continuation when
/// indented at the top level (depth 0); inside brackets they always separate.
bracket_depth: usize = 0,

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
        '#' => return self.lexComment(),
        '(' => {
            self.bracket_depth += 1;
            return self.single(.left_paren);
        },
        ')' => {
            self.bracket_depth -|= 1;
            return self.single(.right_paren);
        },
        '{' => {
            self.bracket_depth += 1;
            return self.single(.left_brace);
        },
        '}' => {
            self.bracket_depth -|= 1;
            return self.single(.right_brace);
        },
        '`' => return self.single(.backtick),
        ';' => return self.single(.semicolon),
        '\n' => return self.lexWhitespace(),
        ',' => return self.single(.comma),
        '"' => return self.lexString(),
        '\'' => return self.lexSingleString(),
        else => {},
    }

    if (isDigit(c)) return self.lexNumber();

    // A leading `$` glued directly to an identifier (e.g. `$x`, `$problem_id`)
    // is a constant, not a variable: the `$` lets otherwise variable-looking
    // (lowercase) names be treated as literal keys. A lone `$` or `$ name`
    // (space) stays an operator symbol.
    if (c == '$' and self.pos + 1 < self.source.len and isIdentStart(self.source[self.pos + 1]))
        return self.lexDollarConstant();

    // Identifiers may carry a leading run of `-`/`_` (e.g. `-Const`, `_x`),
    // mirroring the grammar's key/variable/var_pattern regexes. What follows the
    // prefix decides the kind: `*`+lowercase -> var_pattern (underscores only in
    // the prefix), uppercase -> key/constant, lowercase -> variable. A bare `_`
    // is itself a key. Anything else starting with `-`/`*` is an operator.
    // Bytes outside ASCII (UTF-8 multibyte sequences, e.g. CJK) are ordinary
    // identifier characters, lexed as a constant like an uppercase letter.
    if (c >= 0x80) return self.lexConstant();
    if (c == '_' or c == '-' or c == '*' or isUpper(c) or isLower(c)) {
        var i = self.pos;
        while (i < self.source.len and (self.source[i] == '-' or self.source[i] == '_'))
            i += 1;
        const prefix = self.source[self.pos..i];
        if (i + 1 < self.source.len and self.source[i] == '*' and
            isLower(self.source[i + 1]) and !hasDash(prefix))
            return self.lexVarPattern();
        if (i < self.source.len and isUpper(self.source[i])) return self.lexConstant();
        if (i < self.source.len and isLower(self.source[i])) return self.lexVariable();
        if (c == '_') return self.lexConstant(); // bare `_` key
    }
    if (isOpChar(c)) return self.lexOperator();

    // Skip unknown bytes
    self.pos += 1;
    return self.advance();
}

/// Lex a whitespace separator starting at a newline. Consumes the run of
/// newlines and horizontal whitespace (including blank lines) up to the next
/// code byte or comment, mirroring the grammar's `_newline`/`_indent` tokens:
/// the run is an `indent` if it ends with indentation (the next line is
/// indented), otherwise a flush `newline`. The full run is the token text so
/// the printer can reproduce the exact layout.
fn lexWhitespace(self: *Self) Token {
    const start = self.pos;
    while (self.pos < self.source.len) : (self.pos += 1) {
        const c = self.source[self.pos];
        if (c != '\n' and c != '\r' and c != ' ' and c != '\t') break;
    }
    const last = self.source[self.pos - 1];
    const tag: Tag = if (last == ' ' or last == '\t') .indent else .newline;
    return .{ .tag = tag, .start = start, .end = self.pos };
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
        } else break;
    }
}

/// Lex a comment token spanning `#` to the end of the line (the trailing
/// `\n` is left for the newline handler). A trailing `\r` is excluded.
fn lexComment(self: *Self) Token {
    const start = self.pos;
    while (self.pos < self.source.len and self.source[self.pos] != '\n')
        self.pos += 1;
    var end = self.pos;
    if (end > start and self.source[end - 1] == '\r') end -= 1;
    return .{ .tag = .comment, .start = start, .end = end };
}

/// Consume an identifier body: any run of identifier characters and dashes.
/// Dashes are ordinary identifier characters here, so `I32-Const`, `-Const`,
/// and `Const-` are all single identifiers. They are only told apart from the
/// `-`/`->`/`-->` operators by spaces, since whitespace ends the token.
fn scanIdentTail(self: *Self) void {
    while (self.pos < self.source.len) : (self.pos += 1) {
        const c = self.source[self.pos];
        if (!isIdentTail(c) and c != '-') break;
    }
}

fn lexConstant(self: *Self) Token {
    const start = self.pos;
    self.scanIdentTail();
    return .{ .tag = .constant, .start = start, .end = self.pos };
}

fn lexVariable(self: *Self) Token {
    const start = self.pos;
    self.scanIdentTail();
    return .{ .tag = .variable, .start = start, .end = self.pos };
}

// `$name`: a constant whose body is an ordinary identifier. The `$` is kept in
// the token text so it round-trips.
fn lexDollarConstant(self: *Self) Token {
    const start = self.pos;
    self.pos += 1; // skip the leading `$`
    self.scanIdentTail();
    return .{ .tag = .constant, .start = start, .end = self.pos };
}

fn lexVarPattern(self: *Self) Token {
    const start = self.pos;
    while (self.pos < self.source.len and self.source[self.pos] == '_')
        self.pos += 1; // leading underscores
    self.pos += 1; // skip *
    self.pos += 1; // skip first lowercase letter
    self.scanIdentTail();
    return .{ .tag = .var_pattern, .start = start, .end = self.pos };
}

fn hasDash(prefix: []const u8) bool {
    return mem.indexOfScalar(u8, prefix, '-') != null;
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
    return self.lexQuoted('"', .string);
}

// Single-quoted strings (`'...'`) are a distinct token from double-quoted
// strings, kept apart so source like SQL string literals round-trips faithfully.
fn lexSingleString(self: *Self) Token {
    return self.lexQuoted('\'', .single_string);
}

fn lexQuoted(self: *Self, quote: u8, tag: Tag) Token {
    const start = self.pos;
    self.pos += 1; // skip opening quote
    while (self.pos < self.source.len) {
        if (self.source[self.pos] == '\\' and self.pos + 1 < self.source.len) {
            self.pos += 2; // skip escape sequence
        } else if (self.source[self.pos] == quote) {
            self.pos += 1; // skip closing quote
            break;
        } else {
            self.pos += 1;
        }
    }
    return .{ .tag = tag, .start = start, .end = self.pos };
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
    return isUpper(c) or isLower(c) or isDigit(c) or c == '_' or c >= 0x80;
}

// The character that may immediately follow `$` to form a variable.
fn isIdentStart(c: u8) bool {
    return isUpper(c) or isLower(c) or isDigit(c) or c == '_' or c >= 0x80;
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
        // Brackets are ordinary symbol characters, not special syntax: the
        // evaluator implements lists itself by matching them like identifiers.
        '[',
        ']',
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

/// Builds the wrapper node for a separator token. A comma produces a `.list`, a
/// semicolon a `.semicolon`; a newline/indent produces a `.newline`/`.indent`
/// carrying the literal whitespace, so the printer reproduces the exact layout.
fn sepNode(self: *Self, tok: Token, rhs: Pattern) Node {
    return switch (tok.tag) {
        .newline => Node{ .newline = .{ .ws = tok.text(self.source), .rhs = incrementHeight(rhs) } },
        .indent => Node{ .indent = .{ .ws = tok.text(self.source), .rhs = incrementHeight(rhs) } },
        .semicolon => Node{ .semicolon = incrementHeight(rhs) },
        else => Node{ .list = incrementHeight(rhs) },
    };
}

fn isPrec1Sep(tag: Tag) bool {
    return tag == .semicolon or tag == .newline;
}

/// Prec 1: semicolon `;` / newline (right-associative to match the grammar).
fn parsePrec1(self: *Self, allocator: Allocator) Oom!Pattern {
    // Handle leading separator (empty LHS)
    if (isPrec1Sep(self.peek())) {
        const sep = self.eat();
        const rhs = try self.parseOptionalPrec1(allocator);
        var nodes = try allocator.alloc(Node, 1);
        nodes[0] = self.sepNode(sep, rhs);
        return patternOf(nodes, rhs.height + 1);
    }

    const lhs = try self.parsePrec2(allocator);
    if (!isPrec1Sep(self.peek())) return lhs;

    // Consume separator and recursively parse rhs (right-associative)
    const sep = self.eat();
    const rhs = try self.parseOptionalPrec1(allocator);

    var nodes = std.ArrayList(Node).empty;
    try nodes.appendSlice(allocator, lhs.root);
    allocator.free(lhs.root);
    try nodes.append(allocator, self.sepNode(sep, rhs));
    const max_child = @max(lhs.height, rhs.height + 1);
    return patternOf(try nodes.toOwnedSlice(allocator), max_child);
}

fn parseOptionalPrec1(self: *Self, allocator: Allocator) Oom!Pattern {
    return self.parsePrec1(allocator);
}

fn parseOptionalPrec2(self: *Self, allocator: Allocator) Oom!Pattern {
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
        return patternOf(try nodes.toOwnedSlice(allocator), rhs.height + 1);
    }

    const lhs = try self.parsePrec3(allocator);
    if (self.peek() != .long_match and self.peek() != .long_arrow) return lhs;

    var nodes = std.ArrayList(Node).empty;
    try nodes.appendSlice(allocator, lhs.root);
    allocator.free(lhs.root);

    const op = self.eat();
    const rhs = try self.parseOptionalPrec2(allocator);
    try nodes.append(allocator, wrapOp(op.tag, rhs));
    const max_child = @max(lhs.height, rhs.height + 1);
    return patternOf(try nodes.toOwnedSlice(allocator), max_child);
}

fn isPrec3Sep(tag: Tag) bool {
    return tag == .comma or tag == .indent;
}

/// Prec 3: comma `,` / indent (right-associative to match the grammar).
fn parsePrec3(self: *Self, allocator: Allocator) Oom!Pattern {
    if (isPrec3Sep(self.peek())) {
        // Leading separator: empty lhs
        const sep = self.eat();
        const rhs = try self.parseOptionalPrec3(allocator);
        var nodes = try allocator.alloc(Node, 1);
        nodes[0] = self.sepNode(sep, rhs);
        return patternOf(nodes, rhs.height + 1);
    }

    const lhs = try self.parsePrec4(allocator);
    if (!isPrec3Sep(self.peek())) return lhs;

    // Consume separator and recursively parse rhs (right-associative)
    const sep = self.eat();
    const rhs = try self.parseOptionalPrec3(allocator);

    var nodes = std.ArrayList(Node).empty;
    try nodes.appendSlice(allocator, lhs.root);
    allocator.free(lhs.root);
    try nodes.append(allocator, self.sepNode(sep, rhs));
    const max_child = @max(lhs.height, rhs.height + 1);
    return patternOf(try nodes.toOwnedSlice(allocator), max_child);
}

fn parseOptionalPrec3(self: *Self, allocator: Allocator) Oom!Pattern {
    return self.parsePrec3(allocator);
}

fn parseOptionalPrec4(self: *Self, allocator: Allocator) Oom!Pattern {
    return self.parsePrec4(allocator);
}

/// Prec 4: infix (left-associative)
///   User-defined symbol operators. The symbol is stored in the .infix node's
///   `op` field, with the operands kept as its `rhs` pattern.
fn parsePrec4(self: *Self, allocator: Allocator) Oom!Pattern {
    const lhs = try self.parsePrec5(allocator);
    if (self.peek() != .symbol) return lhs;

    var nodes = std.ArrayList(Node).empty;
    try nodes.appendSlice(allocator, lhs.root);
    allocator.free(lhs.root);
    var max_child = lhs.height;

    while (self.peek() == .symbol) {
        const sym_tok = self.eat();
        const sym_text = sym_tok.text(self.source);
        const rhs = try self.parseOptionalPrec5(allocator);

        // Store the operator out-of-band, with the operands as the rhs pattern.
        const infix_node = Node{ .infix = .{ .op = sym_text, .rhs = incrementHeight(rhs) } };
        try nodes.append(allocator, infix_node);
        max_child = @max(max_child, infix_node.height());
    }
    return patternOf(try nodes.toOwnedSlice(allocator), max_child);
}

fn parseOptionalPrec5(self: *Self, allocator: Allocator) Oom!Pattern {
    return self.parsePrec5(allocator);
}

/// Prec 5: match : / arrow -> (right-recursive for mixed ops)
fn parsePrec5(self: *Self, allocator: Allocator) Oom!Pattern {
    if (self.peek() == .match or self.peek() == .arrow) {
        var nodes = std.ArrayList(Node).empty;
        const op = self.eat();
        const rhs = try self.parseOptionalPrec5(allocator);
        try nodes.append(allocator, wrapOp(op.tag, rhs));
        return patternOf(try nodes.toOwnedSlice(allocator), rhs.height + 1);
    }

    const lhs = try self.parseTerms(allocator);
    if (self.peek() != .match and self.peek() != .arrow) return lhs;

    var nodes = std.ArrayList(Node).empty;
    try nodes.appendSlice(allocator, lhs.root);
    allocator.free(lhs.root);

    const op = self.eat();
    const rhs = try self.parseOptionalPrec5(allocator);
    try nodes.append(allocator, wrapOp(op.tag, rhs));
    const max_child = @max(lhs.height, rhs.height + 1);
    return patternOf(try nodes.toOwnedSlice(allocator), max_child);
}

/// Prec 6: terms (juxtaposition) – one or more terms
fn parseTerms(self: *Self, allocator: Allocator) Oom!Pattern {
    var nodes = std.ArrayList(Node).empty;
    var max_child: usize = 0;
    while (self.canStartTerm()) {
        // String literals decompose into one constant node per character, so
        // both parsers key the trie on characters rather than whole strings.
        if (self.current.tag == .string or self.current.tag == .single_string) {
            const tok = self.eat();
            try chars.appendStringChars(allocator, &nodes, tok.text(self.source));
            continue;
        }
        const node = try self.parseTerm(allocator);
        max_child = @max(max_child, node.height());
        try nodes.append(allocator, node);
    }
    return patternOf(try nodes.toOwnedSlice(allocator), max_child);
}

fn parseTerm(self: *Self, allocator: Allocator) Oom!Node {
    const tok = self.eat();
    return switch (tok.tag) {
        .constant, .number, .string, .single_string => Node{ .constant = tok.text(self.source) },
        .variable => Node{ .variable = tok.text(self.source) },
        .var_pattern => Node{ .variable = tok.text(self.source) },
        .comment => Node{ .comment = tok.text(self.source) },
        .left_paren => blk: {
            const inner = try self.parseInner(allocator, .right_paren);
            break :blk Node{ .pattern = incrementHeight(inner) };
        },
        .left_brace => blk: {
            var inner = try self.parseInner(allocator, .right_brace);
            defer inner.deinit(allocator);
            const trie = try patternToTrie(allocator, inner);
            break :blk Node{ .trie = trie };
        },
        .backtick => blk: {
            const inner = try self.parseInner(allocator, .backtick);
            break :blk Node{ .pattern = incrementHeight(inner) };
        },
        else => Node{ .constant = tok.text(self.source) },
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
        .constant,
        .variable,
        .var_pattern,
        .number,
        .string,
        .single_string,
        .comment,
        .left_paren,
        .left_brace,
        .backtick,
        => true,
        else => false,
    };
}

fn incrementHeight(p: Pattern) Pattern {
    return .{ .root = p.root, .height = p.height + 1 };
}

fn wrapOp(tag: Tag, rhs: Pattern) Node {
    return switch (tag) {
        .semicolon => Node{ .semicolon = incrementHeight(rhs) },
        .comma => Node{ .list = incrementHeight(rhs) },
        .long_match, .match => Node{ .match = incrementHeight(rhs) },
        .long_arrow, .arrow => Node{ .arrow = incrementHeight(rhs) },
        else => Node{ .pattern = incrementHeight(rhs) },
    };
}

/// Parse the inner content of a trie (without braces) into a Trie structure.
/// The source is expected to be semicolon-separated entries where each entry
/// is a constant-value pair (with arrow) or just a constant (value = constant).
/// For example: `A -> B; C D -> E` becomes a trie with two entries.
pub fn parseTrie(allocator: Allocator, source: []const u8) Oom!Trie {
    var parser = Self.init(source);
    var pattern = try parser.parsePattern(allocator);
    defer pattern.deinit(allocator);
    return patternToTrie(allocator, pattern);
}

pub fn patternToTrie(allocator: Allocator, pattern: Pattern) Oom!Trie {
    var result = Trie{};
    try appendEntryRecursive(&result, allocator, pattern);
    return result;
}

/// Recursively extract entries from a right-associative pattern, splitting on
/// the trailing separator at each level and handing each entry to
/// `Trie.appendEntry` (the shared entry semantics). A trailing `.newline`/
/// `.indent`/`.list` separates entries.
fn appendEntryRecursive(result: *Trie, allocator: Allocator, pattern: Pattern) Oom!void {
    if (pattern.root.len == 0) return;

    // A leading newline/indent group is an empty-lhs entry separator: inside
    // braces the body opens with the indentation of its first entry, so the
    // group wraps the real entries with any trailing separator following it.
    // Recurse into the group and then the rest (the comma list at prec 3 stays
    // within an entry, so only newline/indent are split here, not `.list`).
    switch (pattern.root[0]) {
        .newline, .indent => |sep| {
            try appendEntryRecursive(result, allocator, sep.rhs);
            if (pattern.root.len > 1)
                try appendEntryRecursive(result, allocator, Pattern.fromSlice(pattern.root[1..]));
            return;
        },
        else => {},
    }

    // A trailing separator splits entries: prefix is one entry, contents more.
    const last_idx = pattern.root.len - 1;
    const sep_contents: ?Pattern = switch (pattern.root[last_idx]) {
        .list, .semicolon => |p| p,
        .newline, .indent => |sep| sep.rhs,
        else => null,
    };

    if (sep_contents) |contents| {
        const prefix = pattern.root[0..last_idx];
        // An indented line continues a trailing arrow/match whose value is still
        // empty (only comments): the continuation folds in as that value rather
        // than starting a new entry. A complete entry (non-empty value, e.g. the
        // `X -> 1` lines inside a brace body) is not folded, so its indented
        // sibling stays a separate entry.
        if (last_idx > 0 and pattern.root[last_idx] == .indent and
            try foldContinuation(result, allocator, prefix, contents))
            return;
        if (last_idx > 0) switch (prefix[last_idx - 1]) {
            // A prefix ending in a newline/indent group is itself unfinished
            // structure (e.g. an indent group trailed by an empty newline);
            // reprocess it so the inner separator splits or folds. A trailing
            // `.list` (comma) stays within the entry, so handle it as one entry.
            .newline, .indent => try appendEntryRecursive(result, allocator, Pattern.fromSlice(prefix)),
            else => try result.appendEntry(allocator, Pattern.fromSlice(prefix)),
        };
        try appendEntryRecursive(result, allocator, contents);
        return;
    }

    // No separator found - treat entire pattern as a single entry
    try result.appendEntry(allocator, pattern);
}

/// Folds an indented continuation `contents` into the trailing arrow/match of
/// `prefix` when that operator's value is still empty (only comments). Returns
/// true when it folded (the caller is done), false to fall back to the normal
/// entry split. Only the continuation's first entry becomes the value; any
/// further separated entries are appended normally.
fn foldContinuation(result: *Trie, allocator: Allocator, prefix: []Node, contents: Pattern) Oom!bool {
    const op = prefix[prefix.len - 1];
    const op_value: Pattern = switch (op) {
        .arrow, .match => |p| p,
        else => return false,
    };
    for (op_value.root) |node| if (node != .comment) return false;

    // Split the continuation at its first separator: the leading part is the
    // folded value, the rest (if any) stays as following entries.
    var split: usize = contents.root.len;
    for (contents.root, 0..) |node, i| switch (node) {
        .list, .semicolon, .newline, .indent => {
            split = i;
            break;
        },
        else => {},
    };

    var value = std.ArrayList(Node).empty;
    try value.appendSlice(allocator, op_value.root);
    try value.appendSlice(allocator, contents.root[0..split]);
    const merged_value = incrementHeight(Pattern.fromSlice(try value.toOwnedSlice(allocator)));

    var entry = try allocator.alloc(Node, prefix.len);
    @memcpy(entry[0 .. prefix.len - 1], prefix[0 .. prefix.len - 1]);
    entry[prefix.len - 1] = switch (op) {
        .arrow => Node{ .arrow = merged_value },
        else => Node{ .match = merged_value },
    };
    try result.appendEntry(allocator, Pattern.fromSlice(entry));

    if (split < contents.root.len)
        try appendEntryRecursive(result, allocator, Pattern.fromSlice(contents.root[split..]));
    return true;
}

fn patternOf(nodes: []Node, max_child_height: usize) Pattern {
    return .{ .root = nodes, .height = max_child_height };
}

fn patternFromSlice(nodes: []Node) Pattern {
    var max_child: usize = 0;
    for (nodes) |n| {
        max_child = @max(max_child, n.height());
    }
    return .{ .root = nodes, .height = max_child };
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

const NodeTag = enum { constant, char, variable, var_pattern, comment, pattern, infix, match, arrow, list, semicolon, newline, indent, trie };

fn expectNodes(pattern: Pattern, expected_tags: []const NodeTag) !void {
    try testing.expectEqual(expected_tags.len, pattern.root.len);
    for (pattern.root, expected_tags) |node, expected_tag| {
        const actual_tag: NodeTag = switch (node) {
            .constant => .constant,
            .char => .char,
            .variable => |v| if (v.len > 0 and v[0] == '*') .var_pattern else .variable,
            .comment => .comment,
            .pattern => .pattern,
            .infix => .infix,
            .match => .match,
            .arrow => .arrow,
            .list => .list,
            .semicolon => .semicolon,
            .newline => .newline,
            .indent => .indent,
            .trie => .trie,
        };
        try testing.expectEqual(expected_tag, actual_tag);
    }
}

test "empty" {
    const p = try parse(testing.allocator, "");
    try testing.expectEqual(@as(usize, 0), p.root.len);
}

test "single constant" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "Foo");
    try testing.expectEqual(@as(usize, 1), p.root.len);
    try testing.expectEqualStrings("Foo", p.root[0].constant);
}

test "juxtaposition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "A B C");
    try expectNodes(p, &.{ .constant, .constant, .constant });
    try testing.expectEqualStrings("A", p.root[0].constant);
    try testing.expectEqualStrings("B", p.root[1].constant);
    try testing.expectEqualStrings("C", p.root[2].constant);
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
    try expectNodes(p, &.{.constant});
    try testing.expectEqualStrings("42", p.root[0].constant);
}

test "decimal number" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "3.14");
    try expectNodes(p, &.{.constant});
    try testing.expectEqualStrings("3.14", p.root[0].constant);
}

test "string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // String literals decompose into one char node per character.
    const p = try parse(arena.allocator(), "\"hello\"");
    try expectNodes(p, &.{ .char, .char, .char, .char, .char });
    try testing.expectEqualStrings("h", p.root[0].char);
    try testing.expectEqualStrings("o", p.root[4].char);
}

test "arrow: A -> B" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "A -> B");
    // LHS flattened [A], then arrow([B])
    try expectNodes(p, &.{ .constant, .arrow });
    try testing.expectEqualStrings("A", p.root[0].constant);
    try testing.expectEqualStrings("B", p.root[1].arrow.root[0].constant);
}

test "match: x : Int" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "x : Int");
    try expectNodes(p, &.{ .variable, .match });
    try testing.expectEqualStrings("x", p.root[0].variable);
    try testing.expectEqualStrings("Int", p.root[1].match.root[0].constant);
}

test "match and arrow: x : Int -> x" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "x : Int -> x");
    // Prec 5 right-recursive: x, match([Int, arrow([x])])
    try expectNodes(p, &.{ .variable, .match });
    const match_pat = p.root[1].match;
    try testing.expectEqual(@as(usize, 2), match_pat.root.len);
    try testing.expectEqualStrings("Int", match_pat.root[0].constant);
    try testing.expectEqualStrings("x", match_pat.root[1].arrow.root[0].variable);
}

test "long arrow: A --> B" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "A --> B");
    try expectNodes(p, &.{ .constant, .arrow });
    try testing.expectEqualStrings("B", p.root[1].arrow.root[0].constant);
}

test "long match: A :: B" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "A :: B");
    try expectNodes(p, &.{ .constant, .match });
    try testing.expectEqualStrings("B", p.root[1].match.root[0].constant);
}

test "comma: A , B , C" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "A , B , C");
    // Right-assoc: [A, list([B, list([C])])]
    try expectNodes(p, &.{ .constant, .list });
    try testing.expectEqualStrings("A", p.root[0].constant);
    try testing.expectEqualStrings("B", p.root[1].list.root[0].constant);
    try expectNodes(p.root[1].list, &.{ .constant, .list });
    try testing.expectEqualStrings("C", p.root[1].list.root[1].list.root[0].constant);
}

test "semicolon: A ; B ; C" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "A ; B ; C");
    // Right-assoc: [A, semicolon([B, semicolon([C])])]. Semicolons are their
    // own node type, distinct from comma lists.
    try expectNodes(p, &.{ .constant, .semicolon });
    try testing.expectEqualStrings("A", p.root[0].constant);
    try testing.expectEqualStrings("B", p.root[1].semicolon.root[0].constant);
    try expectNodes(p.root[1].semicolon, &.{ .constant, .semicolon });
    try testing.expectEqualStrings("C", p.root[1].semicolon.root[1].semicolon.root[0].constant);
}

test "incrementHeight pattern: (A B)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "(A B)");
    try expectNodes(p, &.{.pattern});
    const inner = p.root[0].pattern;
    try testing.expectEqual(@as(usize, 2), inner.root.len);
    try testing.expectEqualStrings("A", inner.root[0].constant);
    try testing.expectEqualStrings("B", inner.root[1].constant);
}

test "incrementHeight empty: ()" {
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
    try expectNodes(p, &.{ .constant, .constant, .match });
    const match_pat = p.root[2].match;
    try testing.expectEqual(@as(usize, 3), match_pat.root.len);
    try testing.expectEqualStrings("C", match_pat.root[0].constant);
    try testing.expectEqualStrings("D", match_pat.root[1].constant);
    const arrow_pat = match_pat.root[2].arrow;
    try testing.expectEqual(@as(usize, 2), arrow_pat.root.len);
    try testing.expectEqualStrings("E", arrow_pat.root[0].constant);
    try testing.expectEqualStrings("F", arrow_pat.root[1].constant);
}

test "infix: 1 + 2" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "1 + 2");
    // [1, infix(+, [2])]
    try expectNodes(p, &.{ .constant, .infix });
    try testing.expectEqualStrings("1", p.root[0].constant);
    const infix = p.root[1].infix;
    try testing.expectEqualStrings("+", infix.op);
    try testing.expectEqual(@as(usize, 1), infix.rhs.root.len);
    try testing.expectEqualStrings("2", infix.rhs.root[0].constant);
}

test "comment preserved as node" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Comments are kept as nodes; the newline still separates entries.
    // "A # comment\nB" becomes [A, comment, list([B])].
    const p = try parse(arena.allocator(), "A # comment\nB");
    try expectNodes(p, &.{ .constant, .comment, .newline });
    try testing.expectEqualStrings("A", p.root[0].constant);
    try testing.expectEqualStrings("# comment", p.root[1].comment);
    try testing.expectEqualStrings("B", p.root[2].newline.rhs.root[0].constant);
}

test "empty trie: {}" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "{}");
    try expectNodes(p, &.{.trie});
    try testing.expectEqual(@as(usize, 0), p.root[0].trie.length());
}

test "single entry trie: { A -> B }" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "{ A -> B }");
    try expectNodes(p, &.{.trie});
    const t = p.root[0].trie;
    try testing.expectEqual(@as(usize, 1), t.length());
    // Trie should have entry: A -> B
    try testing.expect(t.getToken("A") != null);
}

test "multi-constant entry trie: { A B -> C }" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "{ A B -> C }");
    try expectNodes(p, &.{.trie});
    const t = p.root[0].trie;
    try testing.expectEqual(@as(usize, 1), t.length());
    // Trie should have incrementHeight entry: A -> B -> value(C)
    try testing.expect(t.getToken("A") != null);
    const a_trie = t.getToken("A").?;
    try testing.expect(a_trie.getToken("B") != null);
}

test "multi-entry trie: { A -> B; C -> D }" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "{ A -> B; C -> D }");
    try expectNodes(p, &.{.trie});
    const t = p.root[0].trie;
    try testing.expectEqual(@as(usize, 2), t.length());
    try testing.expect(t.getToken("A") != null);
    try testing.expect(t.getToken("C") != null);
}

test "trie with variable: { x -> x }" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "{ x -> x }");
    try expectNodes(p, &.{.trie});
    const t = p.root[0].trie;
    try testing.expectEqual(@as(usize, 1), t.length());
    try testing.expect(t.var_map.contains("x"));
}

test "trie constant-only entry: { A }" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "{ A }");
    try expectNodes(p, &.{.trie});
    const t = p.root[0].trie;
    try testing.expectEqual(@as(usize, 1), t.length());
    try testing.expect(t.getToken("A") != null);
}

test "trie in expression: X { A -> B } Y" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "X { A -> B } Y");
    try expectNodes(p, &.{ .constant, .trie, .constant });
    try testing.expectEqualStrings("X", p.root[0].constant);
    try testing.expectEqualStrings("Y", p.root[2].constant);
    const t = p.root[1].trie;
    try testing.expectEqual(@as(usize, 1), t.length());
}

test "trie with 3 entries: { A -> 1; B -> 2; C -> 3 }" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "{ A -> 1; B -> 2; C -> 3 }");
    try expectNodes(p, &.{.trie});
    const t = p.root[0].trie;
    try testing.expectEqual(@as(usize, 3), t.length());
    try testing.expect(t.getToken("A") != null);
    try testing.expect(t.getToken("B") != null);
    try testing.expect(t.getToken("C") != null);
}

test "parseTrie: comma with varpattern - A, *x --> *x" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var trie = try parseTrie(arena.allocator(), "A, *x --> *x");
    // Trie structure: A -> , -> *x (var) -> value(*x)
    try testing.expectEqual(@as(usize, 1), trie.length());
    try testing.expect(trie.getToken("A") != null);
    const a_trie = trie.getToken("A").?;
    try testing.expect(a_trie.getToken(",") != null);
    const comma_trie = a_trie.getToken(",").?;
    // After comma, there should be a variable *x
    try testing.expect(comma_trie.var_branches.items.len > 0);
}

test "parseTrie: mixed operators" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Entry 1: list of 3 (A, B->C, D) --> E
    // Entry 2: F --> G
    const trie = try parseTrie(arena.allocator(), "A, B -> C, D --> E; F --> G");
    try testing.expectEqual(@as(usize, 2), trie.length());
    try testing.expect(trie.getToken("A") != null);
    try testing.expect(trie.getToken("F") != null);
}

test "multiline: newlines separate entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Newlines evaluate like semicolons but produce distinct .newline nodes
    const p = try parse(arena.allocator(), "A\nB\nC");
    // [A, newline([B, newline([C])])]
    try expectNodes(p, &.{ .constant, .newline });
    try testing.expectEqualStrings("A", p.root[0].constant);
    try testing.expectEqualStrings("B", p.root[1].newline.rhs.root[0].constant);
    try expectNodes(p.root[1].newline.rhs, &.{ .constant, .newline });
    try testing.expectEqualStrings("C", p.root[1].newline.rhs.root[1].newline.rhs.root[0].constant);
}

test "multiline: trailing arrow is empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Arrow at end of line has empty RHS, newline separates
    const p = try parse(arena.allocator(), "A ->\nB");
    // [A, arrow([]), newline([B])]
    try expectNodes(p, &.{ .constant, .arrow, .newline });
    try testing.expectEqualStrings("A", p.root[0].constant);
    try testing.expectEqual(@as(usize, 0), p.root[1].arrow.root.len);
    try testing.expectEqualStrings("B", p.root[2].newline.rhs.root[0].constant);
}

test "multiline: trailing comma separates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Comma (prec 3) has empty RHS, newline (prec 1) separates B
    const p = try parse(arena.allocator(), "A,\nB");
    // [A, list([]), newline([B])] - comma with empty, then newline with B
    try expectNodes(p, &.{ .constant, .list, .newline });
    try testing.expectEqualStrings("A", p.root[0].constant);
    try testing.expectEqual(@as(usize, 0), p.root[1].list.root.len);
    try testing.expectEqualStrings("B", p.root[2].newline.rhs.root[0].constant);
}

test "multiline: trailing long arrow is empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "A -->\nB");
    // [A, arrow([]), newline([B])]
    try expectNodes(p, &.{ .constant, .arrow, .newline });
    try testing.expectEqualStrings("A", p.root[0].constant);
    try testing.expectEqual(@as(usize, 0), p.root[1].arrow.root.len);
    try testing.expectEqualStrings("B", p.root[2].newline.rhs.root[0].constant);
}

test "multiline: trailing match is empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "x :\nInt");
    // [x, match([]), newline([Int])]
    try expectNodes(p, &.{ .variable, .match, .newline });
    try testing.expectEqualStrings("x", p.root[0].variable);
    try testing.expectEqual(@as(usize, 0), p.root[1].match.root.len);
    try testing.expectEqualStrings("Int", p.root[2].newline.rhs.root[0].constant);
}

test "multiline: trie with newline entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const trie = try parseTrie(arena.allocator(), "A -> 1\nB -> 2");
    try testing.expectEqual(@as(usize, 2), trie.length());
    try testing.expect(trie.getToken("A") != null);
    try testing.expect(trie.getToken("B") != null);
}

test "multiline: trie with trailing arrow has empty value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Arrow at end of line has empty value, B is separate entry
    const trie = try parseTrie(arena.allocator(), "A ->\nB");
    try testing.expectEqual(@as(usize, 2), trie.length());
    try testing.expect(trie.getToken("A") != null);
    try testing.expect(trie.getToken("B") != null);
    // A's value should be empty
    const a_value = trie.getIndexOrNull(0).?;
    try testing.expectEqual(@as(usize, 0), a_value.root.len);
}

test "multiline: comment after trailing op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Comment after a trailing operator is kept as the arrow's only (comment)
    // child. The next line is not indented, so B remains a separate entry.
    const p = try parse(arena.allocator(), "A -> # value is B\nB");
    // [A, arrow([comment]), newline([B])]
    try expectNodes(p, &.{ .constant, .arrow, .newline });
    try testing.expectEqualStrings("A", p.root[0].constant);
    try testing.expectEqual(@as(usize, 1), p.root[1].arrow.root.len);
    try testing.expect(p.root[1].arrow.root[0] == .comment);
    try testing.expectEqualStrings("B", p.root[2].newline.rhs.root[0].constant);
}

test "multiline: multiple newlines are separate entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Consecutive blank lines collapse into a single newline separator
    const p = try parse(arena.allocator(), "A\n\nB");
    // [A, newline([B])]
    try expectNodes(p, &.{ .constant, .newline });
    try testing.expectEqualStrings("B", p.root[1].newline.rhs.root[0].constant);
}

test "multiline: multi-line pattern without continuation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Each line is a separate entry (no line continuation)
    const src =
        \\Map fn () -> ()
        \\Map fn (x, *xs) --> fn x, Map fn (*xs)
    ;
    const trie = try parseTrie(arena.allocator(), src);
    try testing.expectEqual(@as(usize, 2), trie.length());
    try testing.expect(trie.getToken("Map") != null);
}

test "multiline: newlines and semicolons produce same structure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Newlines and semicolons are distinct nodes (.newline vs .semicolon) for
    // pretty-print isomorphism, but separate entries the same way.
    const with_newline = try parse(arena.allocator(), "A\nB");
    const with_semicolon = try parse(arena.allocator(), "A; B");

    try expectNodes(with_newline, &.{ .constant, .newline });
    try expectNodes(with_semicolon, &.{ .constant, .semicolon });
    try testing.expectEqualStrings("A", with_newline.root[0].constant);
    try testing.expectEqualStrings("A", with_semicolon.root[0].constant);
    try testing.expectEqualStrings("B", with_newline.root[1].newline.rhs.root[0].constant);
    try testing.expectEqualStrings("B", with_semicolon.root[1].semicolon.root[0].constant);
}

test "multiline: trailing operators do not continue" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Single line vs multiline produce different structures
    const single_line = try parse(arena.allocator(), "A -> B");
    const with_newline = try parse(arena.allocator(), "A ->\nB");

    // Single line: [A, arrow([B])]
    try expectNodes(single_line, &.{ .constant, .arrow });
    try testing.expectEqualStrings("B", single_line.root[1].arrow.root[0].constant);

    // Multiline: [A, arrow([]), newline([B])]
    try expectNodes(with_newline, &.{ .constant, .arrow, .newline });
    try testing.expectEqual(@as(usize, 0), with_newline.root[1].arrow.root.len);
    try testing.expectEqualStrings("B", with_newline.root[2].newline.rhs.root[0].constant);
}

fn parseAndMatch(allocator: std.mem.Allocator, trie: Trie, query_str: []const u8) !?Pattern {
    var query = try parse(allocator, query_str);
    defer query.deinit(allocator);
    var term_bindings = trie_module.VarBindings{};
    defer term_bindings.deinit(allocator);
    var result = try trie.match(allocator, .{ .upper = trie.length() }, &term_bindings, query);
    defer result.deinit(allocator);
    if (result.value) |val| {
        return try val.copy(allocator);
    }
    return null;
}

fn expectMatch(allocator: std.mem.Allocator, trie: Trie, query_str: []const u8, expected_str: []const u8) !void {
    const result = try parseAndMatch(allocator, trie, query_str);
    try testing.expect(result != null);
    var result_mut = result.?;
    defer result_mut.deinit(allocator);
    var expected = try parse(allocator, expected_str);
    defer expected.deinit(allocator);
    try testing.expect(result_mut.eql(expected));
}

fn expectNoMatch(allocator: std.mem.Allocator, trie: Trie, query_str: []const u8) !void {
    const result = try parseAndMatch(allocator, trie, query_str);
    try testing.expect(result == null);
}

test "parseTrie and match: simple vals" {
    var trie1 = try parseTrie(testing.allocator, "Aa Bb Cc -> 123");
    defer trie1.deinit(testing.allocator);
    var trie2 = try parseTrie(testing.allocator, "Aa Bb Cc -> 123");
    defer trie2.deinit(testing.allocator);
    try testing.expect(trie1.eql(trie2));

    // Test branching: add Aa Bb2 -> 456
    var trie_with_branch = try parseTrie(testing.allocator, "Aa Bb Cc -> 123; Aa Bb2 -> 456");
    defer trie_with_branch.deinit(testing.allocator);
    try testing.expect(!trie1.eql(trie_with_branch));

    // Verify match returns value
    try expectMatch(testing.allocator, trie1, "Aa Bb Cc", "123");
}

test "parseTrie and match: single constant-value pair" {
    var trie = try parseTrie(testing.allocator, "A -> B");
    defer trie.deinit(testing.allocator);
    try expectMatch(testing.allocator, trie, "A", "B");
}

test "parseTrie and match: multiple entries with semicolon" {
    var trie = try parseTrie(testing.allocator, "A -> B; C -> D");
    defer trie.deinit(testing.allocator);
    try expectMatch(testing.allocator, trie, "A", "B");
    try expectMatch(testing.allocator, trie, "C", "D");
}

test "parseTrie and match: multi-token constant" {
    var trie = try parseTrie(testing.allocator, "A B C -> X");
    defer trie.deinit(testing.allocator);
    try expectMatch(testing.allocator, trie, "A B C", "X");
}

test "parseTrie and match: entry without arrow" {
    var trie = try parseTrie(testing.allocator, "Foo");
    defer trie.deinit(testing.allocator);
    try expectMatch(testing.allocator, trie, "Foo", "Foo");
}

test "parseTrie and match: empty input" {
    const trie = try parseTrie(testing.allocator, "");
    // Shouldn't be anything to free here
    try expectNoMatch(testing.allocator, trie, "anything");
}

test "parseTrie and match: roundtrip" {
    var trie = try parseTrie(testing.allocator, "A -> B; B -> A; A -> B");
    defer trie.deinit(testing.allocator);
    try expectMatch(testing.allocator, trie, "A", "B");
    try expectMatch(testing.allocator, trie, "B", "A");
}

test "Parser structure: x, y --> y, x" {
    var zig_pattern = try parse(testing.allocator, "x, y --> y, x");
    defer zig_pattern.deinit(testing.allocator);

    // Due to precedence (comma=3 > long_arrow=2), this parses as: (x, y) --> (y, x)
    // Which gives: [variable(x), list([variable(y)]), arrow([variable(y), list([variable(x)])])]
    try testing.expectEqual(@as(usize, 3), zig_pattern.root.len);
    try testing.expect(zig_pattern.root[0] == .variable);
    try testing.expect(zig_pattern.root[1] == .list);
    try testing.expect(zig_pattern.root[2] == .arrow);
}

test "Parser structure: A, B" {
    var zig_pattern = try parse(testing.allocator, "A, B");
    defer zig_pattern.deinit(testing.allocator);

    // Zig parser should produce: [constant(A), list([constant(B)])]
    try testing.expectEqual(@as(usize, 2), zig_pattern.root.len);
    try testing.expect(zig_pattern.root[0] == .constant);
    try testing.expect(zig_pattern.root[1] == .list);
    try testing.expectEqual(@as(usize, 1), zig_pattern.root[1].list.root.len);
}

test "Parse structure: comma lists" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // A, B, C should be: [A, list([B, list([C])])]
    const abc = try parse(allocator, "A, B, C");
    try testing.expectEqual(@as(usize, 2), abc.root.len);
    try testing.expect(abc.root[0] == .constant);
    try testing.expectEqualStrings("A", abc.root[0].constant);
    try testing.expect(abc.root[1] == .list);
    const bc_list = abc.root[1].list;
    try testing.expectEqual(@as(usize, 2), bc_list.root.len);
    try testing.expect(bc_list.root[0] == .constant);
    try testing.expectEqualStrings("B", bc_list.root[0].constant);
    try testing.expect(bc_list.root[1] == .list);
    const c_list = bc_list.root[1].list;
    try testing.expectEqual(@as(usize, 1), c_list.root.len);
    try testing.expect(c_list.root[0] == .constant);
    try testing.expectEqualStrings("C", c_list.root[0].constant);

    // B, C should be: [B, list([C])]
    const bc = try parse(allocator, "B, C");
    try testing.expectEqual(@as(usize, 2), bc.root.len);
    try testing.expect(bc.root[0] == .constant);
    try testing.expectEqualStrings("B", bc.root[0].constant);
    try testing.expect(bc.root[1] == .list);
    const c_inner = bc.root[1].list;
    try testing.expectEqual(@as(usize, 1), bc.height);
    try testing.expectEqual(@as(usize, 1), c_inner.height);
}
