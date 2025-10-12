/// This file contains the specific instantiated versions of the langauge's
/// general types.
const std = @import("std");
const ArrayList = std.ArrayList; // Update import

test "Submodules" {
    // These file names are not checked by the compiler
    _ = @import("sifu/syntax.zig");
    _ = @import("sifu/Lexer.zig");
    _ = @import("sifu/parser.zig");
    _ = @import("sifu/trie.zig");
}
