const std = @import("std");
const Allocator = std.mem.Allocator;
const Node = @import("../sifu/node.zig").Node;
const trie_module = @import("../sifu/trie.zig");
const Trie = trie_module.Trie;
const Bound = trie_module.Bound;
const Pattern = trie_module.Pattern;
const VarBindings = trie_module.VarBindings;

pub fn descendUpper(
    active: bool,
    trie: Trie,
    bound: Bound,
    sub: Pattern,
    allocator: Allocator,
) Allocator.Error!?usize {}
