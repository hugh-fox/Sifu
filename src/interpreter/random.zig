//! The random evaluation mode: like `lower`, but matches from a random in-range
//! rule index instead of the lowest, so independent runs can fire different rules.

const std = @import("std");
const Bound = @import("../sifu/trie.zig").Bound;

var prng: ?std.Random.DefaultPrng = null;

fn rng() std.Random {
    if (prng == null) {
        var local: u8 = 0; // ASLR makes the stack address vary between runs
        prng = std.Random.DefaultPrng.init(@intFromPtr(&local));
    }
    return prng.?.random();
}

/// A random index within `bound` (`[lower, upper)`), or null once the level has
/// settled (the lower bound reached the upper). Used by `EvalCtx.pickIndex` when
/// the `.random` mode is active.
pub fn pickIndex(bound: Bound) ?usize {}
