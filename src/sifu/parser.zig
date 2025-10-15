const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Order = std.math.Order;
const syntax = @import("syntax.zig");
const Type = syntax.Type;
const Span = syntax.Span;
const Token = syntax.Token;
const AstNode = @import("ast.zig").AstNode;

const Precedence = enum(u8) {
    None = 0,
    Semicolon = 1,
    LongOps = 2, // LongMatch, LongArrow
    Comma = 3,
    Infix = 4,
    ShortOps = 5, // Match, Arrow

    fn fromType(t: Type) Precedence {
        return switch (t) {
            .Semicolon => .Semicolon,
            .LongMatch, .LongArrow => .LongOps,
            .Comma => .Comma,
            .Infix => .Infix,
            .Match, .Arrow => .ShortOps,
            else => .None,
        };
    }

    fn isOperator(t: Type) bool {
        return switch (t) {
            .Semicolon, .LongMatch, .LongArrow, .Comma, .Infix, .Match, .Arrow => true,
            else => false,
        };
    }
};

pub const Parser = struct {
    tokens: []const Token(Span),
    pos: usize,
    allocator: Allocator,

    pub const Error = Allocator.Error || error{
        UnexpectedEndOfInput,
        ExpectedRightParen,
    };

    pub fn init(allocator: Allocator, tokens: []const Token(Span)) Parser {
        return .{
            .tokens = tokens,
            .pos = 0,
            .allocator = allocator,
        };
    }

    fn peek(self: *Parser) ?Token(Span) {
        if (self.pos >= self.tokens.len) return null;
        return self.tokens[self.pos];
    }

    fn advance(self: *Parser) ?Token(Span) {
        const tok = self.peek();
        if (tok != null) self.pos += 1;
        return tok;
    }

    fn isAtEnd(self: *Parser) bool {
        return self.pos >= self.tokens.len;
    }

    fn skipNewlines(self: *Parser) void {
        while (self.peek()) |tok| {
            if (tok.type != .NewLine) break;
            _ = self.advance();
        }
    }

    // Check if next token (after newlines) is an operator
    fn peekAfterNewlines(self: *Parser) ?Token(Span) {
        const saved_pos = self.pos;
        defer self.pos = saved_pos;

        self.skipNewlines();
        return self.peek();
    }

    pub fn parse(self: *Parser) !AstNode {
        return try self.parseTrie();
    }

    // TODO: call parseNestedTrie instead of duplicating logic
    fn parseTrie(self: *Parser) !AstNode {
        var patterns = ArrayList([]const AstNode){};
        defer patterns.deinit(self.allocator);

        self.skipNewlines();

        while (!self.isAtEnd()) {
            const tok = self.peek() orelse break;

            switch (tok.type) {
                .RightBrace, .RightParen => break,
                else => {
                    const pattern = try self.parsePattern(.None);
                    try patterns.append(
                        self.allocator,
                        pattern,
                    );
                    self.skipNewlines();
                },
            }
        }

        return AstNode{ .trie = try patterns.toOwnedSlice(self.allocator) };
    }

    fn parsePattern(self: *Parser, min_prec: Precedence) Error![]const AstNode {
        var terms = ArrayList(AstNode){};

        // Parse LHS terms until we hit an operator
        while (!self.isAtEnd()) {
            const tok = self.peek() orelse break;

            // Check if this is an operator
            if (Precedence.isOperator(tok.type)) {
                break;
            }

            // Check for newline - only break if not followed by operator
            if (tok.type == .NewLine) {
                const next = self.peekAfterNewlines();
                if (next == null or !Precedence.isOperator(next.?.type)) {
                    break;
                }
                self.skipNewlines();
                continue;
            }

            // Closing delimiters
            switch (tok.type) {
                .RightBrace, .RightParen => break,
                else => {},
            }

            const term = try self.parseTerm();
            try terms.append(self.allocator, term);
        }

        while (!self.isAtEnd()) {
            self.skipNewlines();

            const tok = self.peek() orelse break;

            if (!Precedence.isOperator(tok.type)) break;

            const prec = Precedence.fromType(tok.type);
            if (@intFromEnum(prec) <= @intFromEnum(min_prec)) break;

            _ = self.advance();

            // Parse RHS with higher precedence
            const rhs = try self.parseOperatorRhs(tok.type, prec);

            try terms.append(
                self.allocator,
                rhs,
            );
            try terms.append(self.allocator, rhs);
        }

        return terms.toOwnedSlice(self.allocator);
    }

    fn parseOperatorRhs(self: *Parser, op_type: Type, prec: Precedence) !AstNode {
        self.skipNewlines();

        // Check for singleton case: nested trie that begins and ends
        // with operator or closing token
        const start_tok = self.peek();
        const is_nested_start = if (start_tok) |t|
            t.type == .LeftBrace
        else
            false;

        if (is_nested_start) {
            const saved_pos = self.pos;
            const nested = try self.parseTerm();

            // Check if we immediately hit operator/closing after nested term
            self.skipNewlines();
            const is_singleton = if (self.peek()) |t|
                Precedence.isOperator(t.type) or
                    t.type == .RightBrace or
                    t.type == .NewLine
            else
                true;

            if (is_singleton) {
                // Return singleton directly
                return nested;
            } else {
                // Not singleton, reparse as pattern
                self.pos = saved_pos;
            }
        }

        // Parse as pattern with higher precedence
        const next_prec: Precedence = @enumFromInt(@intFromEnum(prec) + 1);
        const rhs = try self.parsePattern(next_prec);

        return self.makeOperatorNode(op_type, rhs);
    }

    fn makeOperatorNode(self: *Parser, op_type: Type, expr: []const AstNode) AstNode {
        _ = self;
        return switch (op_type) {
            .Match => AstNode{ .match = expr },
            .Arrow => AstNode{ .arrow = expr },
            .LongMatch => AstNode{ .match = expr },
            .LongArrow => AstNode{ .arrow = expr },
            .Comma => AstNode{ .list = expr },
            .Semicolon => AstNode{ .list = expr },
            else => unreachable,
        };
    }

    fn parseTerm(self: *Parser) !AstNode {
        const tok = self.advance() orelse
            return AstNode{ .pattern = &.{} }; // Empty pattern on EOF

        return switch (tok.type) {
            .Name => AstNode{ .key = tok.lit },
            .Var => AstNode{ .variable = tok.lit },
            .VarPattern => AstNode{ .var_pattern = tok.lit },
            .Str, .I, .U, .F => AstNode{ .key = tok.lit },
            .LeftBrace => try self.parseNestedTrie(),
            .LeftParen => try self.parseNestedPattern(),
            .Comment => try self.parseTerm(), // Skip comments
            .Comma => @panic("Unexpected comma"),
            .Semicolon => @panic("Unexpected semicolon"),
            .NewLine => @panic("Unexpected newline"),
            .Match => @panic("Unexpected match"),
            .Arrow => @panic("Unexpected arrow"),
            .LongMatch => @panic("Unexpected long match"),
            .LongArrow => @panic("Unexpected long arrow"),
            .RightBrace => @panic("Unexpected right brace"),
            .RightParen => @panic("Unexpected right paren"),
            .Infix => blk: {
                const expr = try self.parsePattern(.LongOps);
                break :blk AstNode{ .infix = .{ .op = tok.lit, .expr = expr } };
            },
        };
    }

    fn parseNestedTrie(self: *Parser) !AstNode {
        self.skipNewlines();

        var patterns = ArrayList([]const AstNode){};
        defer patterns.deinit(self.allocator);

        while (!self.isAtEnd()) {
            const tok = self.peek() orelse
                return error.UnexpectedEndOfInput;

            if (tok.type == .RightBrace) {
                _ = self.advance();
                break;
            }

            const pattern = try self.parsePattern(.None);
            try patterns.append(self.allocator, pattern);
            self.skipNewlines();
        }

        return AstNode{ .trie = try patterns.toOwnedSlice(self.allocator) };
    }

    fn parseNestedPattern(self: *Parser) !AstNode {
        self.skipNewlines();

        const pattern = try self.parsePattern(.None);

        const tok = self.peek() orelse return error.UnexpectedEndOfInput;
        if (tok.type != .RightParen) return error.ExpectedRightParen;
        _ = self.advance();

        return AstNode{ .pattern = pattern };
    }
};

/// Read all of stdin and parse it as an AstNode
pub fn parseFile(allocator: Allocator, tokens: []const Token(Span)) !AstNode {
    var parser = Parser.init(allocator, tokens);
    return try parser.parse();
}
