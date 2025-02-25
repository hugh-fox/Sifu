/// The lexer for Sifu tries to make as few decisions as possible. Mostly,
/// it greedily lexes seperators like commas into their own ast nodes,
/// separates vars and vals based on the first character's case, and lexes
/// numbers. There are no errors, any utf-8 text is parsable.

// Parsing begins with a new `Pattern` ast node. Each term is lexed, parsed into
// a `Token`, then added  to the top-level `Ast`. Pattern construction happens
// after this, as does error reporting on invalid asts.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const util = @import("../util.zig");
const fsize = fsize;
const trie = @import("trie.zig");
const Ast = trie.AstType;
const Lit = Ast.Lit;
const syntax = @import("syntax.zig");
const Token = syntax.Token(usize);
const Type = syntax.Type;
const Set = util.Set;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const ArrayList = std.ArrayList;
const Order = std.math.Order;
const mem = std.mem;
const math = std.math;
const assert = std.debug.assert;
const panic = util.panic;
const print = util.print;
const detect_leaks = @import("build_options").detect_leaks;

pub fn Lexer(comptime Reader: type) type {
    return struct {
        pub const Self = @This();
        // Get the inferred error set of the reader without EndOfStream
        pub const Error = @typeInfo(@TypeOf(peekChar(undefined)))
            .ErrorUnion.error_set || Allocator.Error;

        /// A separate buffer to hold chars for the current token
        buff: ArrayList(u8),
        /// The position in the stream used as context
        pos: usize = 0,
        /// Current line in the source
        line: usize = 0,
        /// Current column in the source
        col: usize = 1,
        /// A single element buffer to hold a char for `peekChar`
        char: ?u8 = null,
        /// The reader providing input
        reader: Reader,

        /// Creates a new lexer using the given allocator
        pub fn init(allocator: Allocator, reader: Reader) Self {
            return .{
                .buff = ArrayList(u8).init(allocator),
                .reader = reader,
            };
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.reset();
            self.buff.clearRetainingCapacity();
        }

        pub fn deinit(self: *Self) void {
            self.reset();
            self.buff.deinit();
        }

        fn reset(self: *Self) void {
            self.* = Self{ .buff = self.buff, .reader = self.reader };
        }

        pub inline fn peek(
            self: *Self,
        ) !?Token {
            if (self.token == null)
                self.token = try self.next();

            print("peek: {s}\n", .{if (self.token) |t| t.lit else "null"});
            return self.token;
        }

        /// Caller owns the token, and must free using the allocator backing
        /// this arraylist (that was passed in init()).
        pub fn next(
            self: *Self,
        ) !?Token {
            const pos = self.pos;
            try self.skipSpace() orelse
                return null;
            const char = try self.nextChar() orelse
                return null;

            // Parse separators greedily. These can be vals or infixes, it
            // doesn't matter.
            const token_type: Type = switch (char) {
                '\n' => .NewLine,
                // escape (from pressing alt+enter in most shells)
                // 0x1B => .Comma,
                ',' => .Comma,
                ';' => .Semicolon,
                '(' => .LeftParen,
                ')' => .RightParen,
                '{' => .LeftBrace,
                '}' => .RightBrace,
                '*' => if (try self.peekChar()) |next_char|
                    if (isLower(next_char))
                        try self.var_pattern()
                    else
                        try self.op()
                else
                    .Infix,
                '+', '-' => if (try self.peekChar()) |next_char|
                    if (isDigit(next_char))
                        try self.integer()
                    else
                        try self.op()
                else
                    .Infix,
                '#' => try self.comment(),
                0xAA => panic("Buffer Overflow debug char (0xAA) consumed\n", .{}),
                else => if (isSep(char))
                    .Name
                else if (isOp(char))
                    try self.op()
                else if (isUpper(char) or char == '@')
                    try self.value()
                else if (isLower(char) or char == '_' or char == '$')
                    try self.variable()
                else if (isDigit(char))
                    try self.integer()
                else
                    // This is a debug error only, as we shouldn't encounter an error
                    // during lexing
                    panic(
                        \\Lexer Bug: Unknown character '{c}' (0x{X}) at line {}, col {}.
                        \\Note: Unicode not supported yet.
                    , .{ char, char, self.line, self.col }),
            };
            return Token{
                .type = token_type,
                .lit = try self.buff.toOwnedSlice(),
                .context = pos,
            };
        }

        /// Lex until a newline. Doesn't return the newline token. Returns null
        /// if no tokens are left. Returns an empty array if one or more
        /// newlines were parsed exclusively.
        pub fn nextLine(
            self: *Self,
            line: *ArrayList(Token),
        ) !?void {
            while (try self.next()) |token| {
                if (token.type == .NewLine)
                    return;

                try line.append(token);
            }
            return null;
        }

        fn peekChar(self: *Self) !?u8 {
            // Avoid using switch here as different readers have different error
            // sets, and we can't assume they have other cases
            self.char = self.char orelse
                self.reader.readByte() catch |e| return if (e == error.EndOfStream)
                null
            else
                e;
            return self.char.?;
        }

        /// Advances one character, reading it into the current token list
        /// buff unless it is a special character, which don't need allocation.
        /// Should be used after peekChar.
        inline fn consume(self: *Self) Error!void {
            switch (self.char orelse
                panic("Consume called without a char\n", .{})) {
                ' ', '\t', '\r', '\n', ',', '(', ')', '{', '}' => {},
                else => |char| {
                    self.pos += 1;
                    if (char == '\n') {
                        self.col = 1;
                        self.line += 1;
                    } else self.col += 1;
                    try self.buff.append(char);
                },
            }
            self.char = null;
        }

        /// Advances one character. Basically just `peekChar` followed by
        /// `consume`.
        fn nextChar(self: *Self) !?u8 {
            const char = try self.peekChar() orelse
                return null;
            try self.consume();
            return char;
        }

        /// Skips whitespace except for newlines until a non-whitespace
        /// character is found. Not guaranteed to skip anything. Newlines are
        /// separators, and thus treated as tokens. Returns null on eof.
        inline fn skipSpace(self: *Self) !?void {
            while (try self.peekChar()) |char| {
                switch (char) {
                    // Clear the char buffer
                    ' ', '\t', '\r' => try self.consume(),
                    else => return,
                }
            } else return null;
        }

        inline fn nextIdent(self: *Self) Error!void {
            while (try self.peekChar()) |next_char|
                if (isIdent(next_char))
                    try self.consume()
                else
                    break;
        }

        inline fn value(self: *Self) !Type {
            try self.nextIdent();
            return .Name;
        }

        inline fn variable(self: *Self) !Type {
            try self.nextIdent();
            return .Var;
        }

        inline fn var_pattern(self: *Self) !Type {
            try self.nextIdent();
            return .VarPattern;
        }

        /// Reads the next infix characters
        inline fn op(self: *Self) Error!Type {
            // The first character of the op
            const pos = self.buff.items.len - 1;
            while (try self.peekChar()) |next_char|
                if (isOp(next_char))
                    try self.consume()
                else
                    break;

            const lit = self.buff.items[pos..];
            const kind: Type = if (mem.eql(u8, lit, ":"))
                .Match
            else if (mem.eql(u8, lit, "::"))
                .LongMatch
            else if (mem.eql(u8, lit, "->"))
                .Arrow
            else if (mem.eql(u8, lit, "-->"))
                .LongArrow
            else
                .Infix;

            // Clear any builtin tokens, they don't need allocating
            switch (kind) {
                .Infix => {},
                else => self.buff.shrinkRetainingCapacity(pos),
            }
            return kind;
        }

        /// Reads the next digits and/or any underscores
        inline fn integer(self: *Self) Error!Type {
            while (try self.peekChar()) |next_char|
                if (isDigit(next_char) or next_char == '_')
                    try self.consume()
                else
                    break;

            return .I;
        }

        /// Reads the next characters as number. `parseFloat` only throws
        /// `InvalidCharacter`, so this function cannot fail.
        inline fn float(self: *Self) Error!Type {
            self.int();
            if (try self.peekChar() == '.') {
                try self.consume();
                self.int();
            }

            return .F;
        }

        /// Reads a value wrapped in double-quotes from the current character. If no
        /// matching quote is found, reads until EOF.
        inline fn string(self: *Self) Error!Type {
            while (try self.peekChar() != '"')
                try self.consume();

            return .Str;
        }

        /// Reads until the end of the line or EOF
        inline fn comment(self: *Self) Error!Type {
            while (try self.peekChar()) |next_char|
                if (next_char != '\n')
                    try self.consume()
                else
                    // Newlines that terminate comments are also terms, so no
                    // `consume` here
                    break;

            return .Comment;
        }

        /// Returns true if the given character is a digit. Does not include
        /// underscores.
        inline fn isDigit(char: u8) bool {
            return switch (char) {
                '0'...'9' => true,
                else => false,
            };
        }

        inline fn isUpper(char: u8) bool {
            return switch (char) {
                'A'...'Z' => true,
                else => false,
            };
        }

        inline fn isLower(char: u8) bool {
            return switch (char) {
                'a'...'z' => true,
                else => false,
            };
        }

        inline fn isSep(char: u8) bool {
            return switch (char) {
                ',', ';', '(', ')', '[', ']', '{', '}', '"', '\'', '`' => true,
                else => false,
            };
        }

        inline fn isOp(char: u8) bool {
            return switch (char) {
                // zig fmt: off
                '.', ':', '-', '+', '=', '<', '>', '%', '^',
                '*', '&', '|', '/', '\\', '@', '!', '?', '~',
                // zig fmt: on
                => true,
                else => false,
            };
        }

        inline fn isSpace(char: u8) bool {
            return char == ' ' or
                char == '\t' or
                char == '\n';
        }

        inline fn isIdent(char: u8) bool {
            return !(isSpace(char) or isSep(char));
        }
    };
}

const testing = std.testing;
const meta = std.meta;
const io = std.io;
const streams = @import("../streams.zig").streams;
const err_stream = streams.err_stream;

fn expectEqualTokens(
    comptime input: []const u8,
    expecteds: []const []const u8,
) !void {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var fbs = io.fixedBufferStream(input);
    const reader = fbs.reader();
    var lex = Lexer(@TypeOf(reader)).init(arena.allocator(), reader);

    for (expecteds) |expected| {
        const next_token = (try lex.next()).?;
        try err_stream.print("{s}\n", .{next_token.lit});
        try testing.expectEqualStrings(
            expected,
            next_token.lit,
        );
    }
}

test "Term: Names" {
    const input =
        \\A B C
        \\Word-43
        \\Word-asd-_9182--+
        \\Random123
        \\Ssag-123+d
    ;
    const expecteds = &.{
        "A",         "B",  "C",                 "\n",
        "Word-43",   "\n", "Word-asd-_9182--+", "\n",
        "Random123", "\n", "Ssag-123+d",
    };
    try expectEqualTokens(input, expecteds);
}

test "Term: Name and Infix splitting" {
    const input = "\t\n\n\t\r\r\t\t  -Sd+-\t\n\t  +>-VB-NM+\t\n";
    const expecteds = &.{
        "\n", "\n",  "-",      "Sd+-",
        "\n", "+>-", "VB-NM+", "\n",
    };
    try expectEqualTokens(input, expecteds);
}

test "Term: Vars" {
    const input =
        \\a word-43 word-asd-+_9182-
        \\random123
        \\_sd
    ;
    const expecteds = &.{
        "a",         "word-43", "word-asd-+_9182-", "\n",
        "random123", "\n",      "_sd",
    };
    try expectEqualTokens(input, expecteds);
}

test "Term: Not Vars" {
    const input =
        \\Asdf
        \\-Word-43-
        \\Word-asd-+_2-
        \\Random_123_
    ;
    const expecteds = &.{
        "Asdf", "\n",            "-",  "Word-43-",
        "\n",   "Word-asd-+_2-", "\n", "Random_123_",
    };
    try expectEqualTokens(input, expecteds);
}

test "Term: comma seperators" {
    const input =
        \\As,dr,f
        \\-Wor,d-4,3-
        \\Word-,asd-,+_2-
        \\Rando,m_123_\
        \\
    ;
    const expecteds = &.{
        "As", ",",   "dr",    ",",     "f",    "\n",
        "-",  "Wor", ",",     "d-4",   ",",    "3",
        "-",  "\n",  "Word-", ",",     "asd-", ",",
        "+",  "_2-", "\n",    "Rando", ",",    "m_123_\\",
        "\n",
    };
    try expectEqualTokens(input, expecteds);
}
