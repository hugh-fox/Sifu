const std = @import("std");

test "Submodules" {
    _ = @import("Parser.zig");
    _ = @import("sifu/trie.zig");
    _ = @import("sifu/pattern.zig");
    _ = @import("sifu/node.zig");
    _ = @import("interpreter.zig");
    _ = @import("interpreter/comments.zig");
    _ = @import("interpreter/string.zig");
    _ = @import("interpreter/math.zig");
    // TODO
    // _ = @import("compiler.zig");
}
