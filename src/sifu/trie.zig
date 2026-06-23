const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const mem = std.mem;
const math = std.math;
const assert = std.debug.assert;
const panic = std.debug.panic;
const Order = math.Order;
const ArenaAllocator = std.heap.ArenaAllocator;
const debug = std.log.debug;
const sort = std.sort;
const Io = std.Io;
const Writer = Io.Writer;

pub const Node = @import("node.zig").Node;
pub const Pattern = @import("pattern.zig").Pattern;

/// Constants (and all structural separators) are keyed by individual bytes:
/// a token like `Foo` is the path `F` -> `o` -> `o` -> ` ` (a trailing space
/// delimits one token from the next, mirroring how the source separates them).
/// Byte keys need no duped/owned key memory, unlike whole-string keys.
pub const HashMap = std.AutoHashMapUnmanaged(u8, Trie);
/// Variables remain keyed by their whole name: a variable matches an entire
/// subject term ("match anything"), which has no per-byte meaning.
pub const VarMap = std.StringHashMapUnmanaged(Trie);
pub const GetOrPutResult = HashMap.GetOrPutResult;

const ByteEntry = HashMap.Entry;
const VarEntry = VarMap.Entry;

/// A byte branch and its child trie entry from the byte map.
const ByteBranchNode = struct {
    entry: ByteEntry,
    // Index of this branch within the child entry's branch list. Necessary for
    // efficient lookups by index.
    next_index: usize,

    pub fn this(branch_node: ByteBranchNode) *Trie {
        return branch_node.entry.value_ptr;
    }
};

/// A variable branch and its child trie entry from the var map.
const VarBranchNode = struct {
    entry: VarEntry,
    next_index: usize,

    pub fn this(branch_node: VarBranchNode) *Trie {
        return branch_node.entry.value_ptr;
    }
};

/// A single index and its next pointer in the trie. The union disambiguates
/// between values and the next variable/constant byte. Constant bytes are
/// borrowed from the byte map, variables from the var map.
/// Variables starting with '*' have var_pattern behavior.
const Branch = union(enum) {
    constant: ByteBranchNode,
    variable: VarBranchNode,
    value: Pattern,

    pub fn isVarPattern(branch: Branch) bool {
        return switch (branch) {
            .variable => |branch_node| branch_node.entry.key_ptr.*.len > 0 and
                branch_node.entry.key_ptr.*[0] == '*',
            else => false,
        };
    }

    pub fn this(self: Branch) ?*Trie {
        switch (self) {
            .value => return null,
            inline else => |branch_node| return branch_node.this(),
        }
    }
};

const IndexBranch = struct {
    usize, // Canonical trie index
    Branch,
};

pub const BranchList = ArrayList(IndexBranch);

/// For directing evaluations to completion. Initially, lower bound begins
/// at 0, for the upper bound, the length of the pattern (inclusive/exclusive
/// respectively).
pub const Bound = struct { lower: usize = 0, upper: usize };

/// Keeps track of which vars and var_pattern are bound to what part of an
/// expression given during matching.
pub const VarBindings = std.StringHashMapUnmanaged(Node);

/// Maps terms to the next trie, if there is one. These form the branches of the
/// trie for a specific level of nesting. Each Constant is in the map is unique, but
/// they can be repeated in separate indices. Therefore this stores its own next
/// Self pointer, and the indices for each constant.
///
/// Keys must be efficiently iterable, but that is provided by the index map
/// anyways so an array map isn't needed for the trie's hashmap.
///
/// The tries that for types that are shared (variables and nested pattern/tries)
/// are encoded by a layer of pointer indirection in their respective fields
/// here.
pub const Trie = struct {
    pub const Self = @This();

    map: HashMap = .{},
    var_map: VarMap = .{},
    /// When non-empty, this node is the delimiter leaf that ends a token whose
    /// bytes spell `token` (a constant or structural separator). The string is
    /// borrowed (from source or a comptime literal), so reconstruction hands
    /// back whole tokens cheaply without re-lexing the byte path.
    token: []const u8 = &.{},
    constant_branches: BranchList = .empty,
    var_branches: BranchList = .empty,
    value_branches: BranchList = .empty,
    /// Nesting level of this trie (0 at the root, +1 per nested branch). The
    /// same notion of `height` as on `Pattern`. TODO: implement height caching.
    height: usize = 0,

    /// The results of matching a trie exactly (vars are matched literally
    /// instead of by building up a pattern of their possible values)
    pub const ExactPrefix = struct {
        len: usize,
        index: ?usize, // Null if no prefix
        leaf: Self,
    };

    /// Asserts that the index exists.
    pub fn getIndex(self: Self, index: usize) Pattern {
        return self.getIndexOrNull(index) orelse
            panic("Index {} doesn't exist\n", .{index});
    }
    /// Returns null if the index doesn't exist in the trie.
    /// Note that this isn't O(m) where m is the constant length of the index.
    pub fn getIndexOrNull(self: Self, index: usize) ?Pattern {
        var current = &self;
        var branch: Branch = undefined;
        const bound = Bound{ .lower = index, .upper = index + 1 };
        while (current.findNext(bound)) |next| {
            _, branch = next;
            current = branch.this() orelse
                return branch.value;
        }
        return null;
    }

    /// Rebuilds the constant for a given index as a flat pattern of constants/variables.
    /// Special delimiters like `(`, `)`, `,`, etc. appear as regular constant nodes.
    pub fn rebuildConstant(
        self: Self,
        allocator: Allocator,
        index: usize,
    ) Allocator.Error!Pattern {
        var nodes = ArrayList(Node).empty;
        errdefer nodes.deinit(allocator);

        try self.rebuildConstantInner(allocator, index, &nodes);

        const root = try nodes.toOwnedSlice(allocator);
        var max_child: usize = 0;
        for (root) |n| max_child = @max(max_child, n.height());
        return Pattern{ .root = root, .height = max_child };
    }

    fn rebuildConstantInner(
        self: Self,
        allocator: Allocator,
        index: usize,
        nodes: *ArrayList(Node),
    ) Allocator.Error!void {
        var current = self;
        const bound = Bound{ .lower = index, .upper = index + 1 };
        while (true) {
            // Follow a constant byte branch. A whole token is spelled across
            // several bytes; emit it only when we reach its delimiter leaf
            // (the node carrying the stored token).
            if (findNextInBranches(current.constant_branches.items, bound)) |kb| {
                const found_index, const branch = kb;
                if (found_index == index) {
                    current = branch.constant.entry.value_ptr.*;
                    if (current.token.len != 0)
                        try nodes.append(allocator, .{ .constant = current.token });
                    continue;
                }
            }
            // Then check vars (whole-name branches).
            if (findNextInBranches(current.var_branches.items, bound)) |vb| {
                const found_index, const branch = vb;
                if (found_index == index) {
                    try nodes.append(allocator, .{ .variable = branch.variable.entry.key_ptr.* });
                    current = branch.variable.entry.value_ptr.*;
                    continue;
                }
            }
            return;
        }
    }

    /// Deep copy a trie by value, as well as Constants and Variables.
    /// Use deinit to free.
    // TODO: optimize by allocating top level maps of same size and then
    // use putAssumeCapacity
    // TODO: use iterator instead of manually copying
    pub fn copy(self: Self, allocator: Allocator) Allocator.Error!Self {
        var result = Self{ .height = self.height };

        // Copy the byte map entries
        var keys_iter = self.map.iterator();
        while (keys_iter.next()) |entry|
            try result.map.putNoClobber(
                allocator,
                entry.key_ptr.*,
                try entry.value_ptr.*.copy(allocator),
            );

        // Copy the var map entries (keyed by whole variable name)
        var var_iter = self.var_map.iterator();
        while (var_iter.next()) |entry|
            try result.var_map.putNoClobber(
                allocator,
                entry.key_ptr.*,
                try entry.value_ptr.*.copy(allocator),
            );

        // Copy the token markers on the leaf, if any.
        result.token = self.token;

        // Copy the branch lists. Each branch holds a map Entry pointing at the
        // source map, so rebuild it against the copied map or the pointers
        // dangle once the source is freed.
        try result.constant_branches.ensureTotalCapacity(allocator, self.constant_branches.items.len);
        for (self.constant_branches.items) |index_branch| {
            const idx, const branch = index_branch;
            const entry = result.map.getEntry(branch.constant.entry.key_ptr.*).?;
            result.constant_branches.appendAssumeCapacity(.{ idx, .{ .constant = .{
                .entry = entry,
                .next_index = branch.constant.next_index,
            } } });
        }
        try result.var_branches.ensureTotalCapacity(allocator, self.var_branches.items.len);
        for (self.var_branches.items) |index_branch| {
            const idx, const branch = index_branch;
            const entry = result.var_map.getEntry(branch.variable.entry.key_ptr.*).?;
            result.var_branches.appendAssumeCapacity(.{ idx, .{ .variable = .{
                .entry = entry,
                .next_index = branch.variable.next_index,
            } } });
        }

        // Value branches contain Patterns that need deep copying
        try result.value_branches.ensureTotalCapacity(allocator, self.value_branches.items.len);
        for (self.value_branches.items) |index_branch| {
            const idx, const branch = index_branch;
            const copied_value = try branch.value.copy(allocator);
            result.value_branches.appendAssumeCapacity(.{ idx, .{ .value = copied_value } });
        }

        return result;
    }

    /// Deep copy a trie pointer, returning a pointer to new memory. Use
    /// destroy to free.
    pub fn clone(self: *Self, allocator: Allocator) !*Self {
        const clone_ptr = try allocator.create(Self);
        clone_ptr.* = try self.copy(allocator);
        return clone_ptr;
    }

    /// Frees all memory recursively, leaving the Trie in an undefined
    /// state. The `self` pointer must have been allocated with `allocator`.
    /// The opposite of `clone`.
    pub fn destroy(self: *Self, allocator: Allocator) void {
        self.deinit(allocator);
        allocator.destroy(self);
    }

    /// The opposite of `copy`. Trie owns copies of all patterns stored via
    /// append, so this frees all values and internal structures.
    pub fn deinit(self: *Self, allocator: Allocator) void {
        // Recursively deinit child tries (each entry in map, once)
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.map.deinit(allocator);

        // Recursively deinit child tries reached through variables
        var var_iter = self.var_map.iterator();
        while (var_iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.var_map.deinit(allocator);

        // Deinit values
        for (self.value_branches.items) |*index_branch| {
            _, var branch = index_branch.*;
            branch.value.deinit(allocator);
        }

        self.constant_branches.deinit(allocator);
        self.var_branches.deinit(allocator);
        self.value_branches.deinit(allocator);
        self.* = .{};
    }

    /// Tries are equal if they have the same literals, sub-arrays and
    /// sub-tries and if their variables are equal.
    pub fn eql(self: Self, other: Self) bool {
        if (self.map.count() != other.map.count())
            return false;
        if (self.var_map.count() != other.var_map.count())
            return false;
        // Byte map entries are keyed by individual bytes; look each up in the
        // other map rather than relying on iteration order.
        var map_iter = self.map.iterator();
        while (map_iter.next()) |entry| {
            const other_value = other.map.get(entry.key_ptr.*) orelse
                return false;
            if (!entry.value_ptr.eql(other_value))
                return false;
        }
        var var_iter = self.var_map.iterator();
        while (var_iter.next()) |entry| {
            const other_value = other.var_map.get(entry.key_ptr.*) orelse
                return false;
            if (!entry.value_ptr.eql(other_value))
                return false;
        }
        return true;
    }

    pub fn create(allocator: Allocator) !*Self {
        const result = try allocator.create(Self);
        result.* = Self{};
        return result;
    }

    /// Walk a literal `bytes` path through the byte map and return the final
    /// byte's entry together with the trie it leads to, or null if any byte is
    /// missing. Used by both constant and separator matching.
    fn getByteEntry(self: *const Self, bytes: []const u8) ?struct { ByteEntry, *Trie } {
        var current: *const Self = self;
        var entry: ByteEntry = undefined;
        for (bytes) |byte| {
            entry = current.map.getEntry(byte) orelse return null;
            current = entry.value_ptr;
        }
        return .{ entry, entry.value_ptr };
    }

    /// Match an identifier constant (its bytes plus the delimiter) and find the
    /// lowest index at or after `bound` continuing past it.
    fn getBranch(
        self: Trie,
        bound: Bound,
        constant: []const u8,
    ) ?IndexBranchTrie {
        const entry, const child_trie = self.getByteEntry(constant) orelse {
            debug("Constant '{s}' not found in map", .{constant});
            return null;
        };
        // Consume the inter-token delimiter following the identifier.
        const delim_entry = child_trie.map.getEntry(delim) orelse return null;
        const leaf = delim_entry.value_ptr;
        const index, _ = leaf.findNext(bound) orelse {
            debug("Constant {s} found, but no branches at or after bound {}", .{ constant, bound });
            return null;
        };
        if (index < bound.lower)
            panic("Index {} is less than bound {}\n", .{ index, bound });
        return .{
            .index = index,
            .branch = .{ .constant = .{ .entry = entry, .next_index = 0 } },
            .trie = leaf,
        };
    }

    /// Follows `trie` for each trie matching structure as well as value.
    /// Does not require allocation because variable branches are not
    /// explored, but rather followed. This is an exact match, so variables
    /// only match variables and a subtrie will be returned. This pointer
    /// is valid unless reassigned in `pat`.
    /// If trie is empty the same `pat` pointer will be returned. If
    /// the entire `pattern` is a prefix, a pointer to the last pat will be
    /// returned instead of null.
    /// `trie` isn't modified.
    pub fn getTerm(
        trie: Self,
        node: Node,
    ) ?Self {
        return switch (node) {
            inline .constant, .char => |constant| trie.getToken(constant),
            .variable => |variable| trie.var_map.get(variable),
            .pattern => |sub_pattern| blk: {
                var current = trie.getToken("(") orelse
                    break :blk null;
                for (sub_pattern.root) |sub_node|
                    current = current.getTerm(sub_node) orelse
                        break :blk null;
                break :blk current.getToken(")");
            },
            .arrow, .match, .list => panic("unimplemented", .{}),
            else => panic("unimplemented", .{}),
        };
    }

    /// Return a pointer to the last trie in `pat` after the longest path
    /// following `pattern`
    pub fn getPrefix(
        trie: Self,
        pattern: Pattern,
    ) ExactPrefix {
        var current = trie;
        const index: usize = undefined; // TODO
        // Follow the longest branch that exists
        const prefix_len = for (pattern.root, 0..) |node, i| {
            current = current.getTerm(node) orelse
                break i;
        } else pattern.root.len;

        return .{ .len = prefix_len, .index = index, .leaf = current };
    }

    pub fn get(
        trie: Self,
        pattern: Pattern,
    ) ?Self {
        const prefix = trie.getPrefix(pattern);
        return if (prefix.len == pattern.root.len)
            prefix.leaf
        else
            null;
    }

    /// Inter-token delimiter byte appended after each identifier constant so a
    /// token can't be confused with the prefix of a longer one (`Foo` vs
    /// `Foobar`). Mirrors the whitespace the source already uses to separate
    /// tokens. Structural separators (`(`, `->`, `,` ...) are matched byte-exact
    /// without it.
    const delim = ' ';

    /// Follow or create a single byte branch, recording `index` on it.
    fn getOrPutByte(
        trie: *Self,
        allocator: Allocator,
        index: usize,
        byte: u8,
    ) !*Self {
        const entry = try trie.map
            .getOrPutValue(allocator, byte, Self{ .height = trie.height + 1 });
        const next = entry.value_ptr;
        try trie.constant_branches.append(
            allocator,
            IndexBranch{ index, .{
                .constant = .{
                    .entry = entry,
                    .next_index = next.constant_branches.items.len,
                },
            } },
        );
        return next;
    }

    /// Append a token (a constant or structural separator): each of its bytes
    /// followed by the delimiter. The delimiter leaf records the whole token so
    /// reconstruction can hand it back without re-lexing.
    fn ensureToken(
        trie: *Self,
        allocator: Allocator,
        index: usize,
        token: []const u8,
    ) Allocator.Error!*Self {
        var next = trie;
        for (token) |byte|
            next = try next.getOrPutByte(allocator, index, byte);
        next = try next.getOrPutByte(allocator, index, delim);
        if (next.token.len == 0) next.token = token;
        return next;
    }

    fn getOrPutVar(
        trie: *Self,
        allocator: Allocator,
        index: usize,
        variable: []const u8,
    ) !*Self {
        const entry = try trie.var_map
            .getOrPutValue(allocator, variable, Self{});
        const next = entry.value_ptr;
        try trie.var_branches.append(
            allocator,
            IndexBranch{ index, .{
                .variable = .{
                    .entry = entry,
                    .next_index = next.var_branches.items.len,
                },
            } },
        );
        return next;
    }

    /// Follow a token (bytes plus delimiter), read-only; null if absent.
    pub fn getToken(trie: Self, token: []const u8) ?Self {
        var current = trie;
        for (token) |byte|
            current = current.map.get(byte) orelse return null;
        return current.map.get(delim);
    }

    /// Follows or creates a path as necessary in the trie and
    /// indices. Only adds branches, not values.
    fn ensurePathTerm(
        trie: *Self,
        allocator: Allocator,
        index: usize,
        term: Node,
    ) Allocator.Error!*Self {
        return switch (term) {
            inline .constant, .char => |constant| blk: {
                debug("ensureConstant: {*} put {s} at index {}", .{ trie, constant, index });
                const next = try trie.ensureToken(allocator, index, constant);
                break :blk next;
            },
            .variable => |variable| try trie
                .getOrPutVar(allocator, index, variable),
            // Comments are stripped before trie construction; skip defensively.
            .comment => trie,
            .pattern => |sub_pat| blk: {
                var next = try trie.ensureToken(allocator, index, "(");
                next = try next.ensurePath(allocator, index, sub_pat);
                next = try next.ensureToken(allocator, index, ")");
                break :blk next;
            },
            .trie => |sub_trie| blk: {
                var next = try trie.ensureToken(allocator, index, "{");

                const indices = try sub_trie.valueIndices(allocator);
                defer allocator.free(indices);

                for (indices, 0..) |entry_idx, i| {
                    if (i > 0) {
                        next = try next.ensureToken(allocator, index, ",");
                    }

                    const constant_pat = try sub_trie.rebuildConstant(allocator, entry_idx);
                    defer allocator.free(constant_pat.root);

                    const value = sub_trie.getIndexOrNull(entry_idx) orelse continue;

                    next = try next.ensurePath(allocator, index, constant_pat);
                    next = try next.ensureToken(allocator, index, "->");
                    next = try next.ensurePath(allocator, index, value);
                }

                next = try next.ensureToken(allocator, index, "}");
                break :blk next;
            },
            .list => |comma| blk: {
                var next = try trie.ensureToken(allocator, index, ",");
                next = try next.ensurePath(allocator, index, comma);
                break :blk next;
            },
            .semicolon => |semi| blk: {
                var next = try trie.ensureToken(allocator, index, ";");
                next = try next.ensurePath(allocator, index, semi);
                break :blk next;
            },
            .indent => |ind| blk: {
                var next = try trie.ensureToken(allocator, index, ",");
                next = try next.ensurePath(allocator, index, ind.rhs);
                break :blk next;
            },
            .newline => |nl| blk: {
                var next = try trie.ensureToken(allocator, index, "\n");
                next = try next.ensurePath(allocator, index, nl.rhs);
                break :blk next;
            },
            .infix => |inf| blk: {
                // The operator symbol becomes bytes on the path, followed by
                // its operands, matching how lists/arrows are flattened.
                var next = try trie.ensureToken(allocator, index, inf.op);
                next = try next.ensurePath(allocator, index, inf.rhs);
                break :blk next;
            },
            .match => |sub_pat| blk: {
                var next = try trie.ensureToken(allocator, index, ":");
                next = try next.ensurePath(allocator, index, sub_pat);
                break :blk next;
            },
            .arrow => |sub_pat| blk: {
                var next = try trie.ensureToken(allocator, index, "->");
                next = try next.ensurePath(allocator, index, sub_pat);
                break :blk next;
            },
        };
    }

    /// Creates the necessary branches and constant entries in the trie for
    /// pattern, and returns a pointer to the branch at the end of the path.
    /// While similar to a hashmap's getOrPut function, ensurePath always
    /// adds a new index, asserting that it did not already exist. There is
    /// no getOrPut equivalent for tries because they are append-only.
    ///
    /// The index must not already be in the trie.
    /// Pattern are copied.
    /// Returns a pointer to the updated trie node. If the given pattern is
    /// empty (0 len), the returned constant and index are undefined.
    fn ensurePath(
        trie: *Self,
        allocator: Allocator,
        index: usize,
        pattern: Pattern,
    ) !*Self {
        var current = trie;
        for (pattern.root) |node| {
            current = try current.ensurePathTerm(allocator, index, node);
        }
        return current;
    }

    /// Add a node to the trie by following `constants`, wrapping them into an
    /// Pattern of Nodes.
    /// Allocations:
    /// - The value, if given, is allocated and copied recursively
    /// Freeing should be done with `destroy` or `deinit`, depending on
    /// how `self` was allocated
    pub fn appendConstant(
        self: *Self,
        allocator: Allocator,
        constant: []const []const u8,
        value: Pattern,
    ) Allocator.Error!*Self {
        const root = try allocator.alloc(Node, constant.len);
        defer allocator.free(root);
        for (root, constant) |*node, token|
            node.* = Node.ofConstant(token);

        return self.append(allocator, Pattern{ .root = root, .height = 0 }, value);
    }

    // TODO: change return type to void
    pub fn append(
        trie: *Self,
        allocator: Allocator,
        pattern: Pattern,
        optional_value: ?Pattern,
    ) Allocator.Error!*Self {
        debug("Appending to {*}", .{trie});
        // The length of values will be the next entry index after insertion
        const index = trie.length();
        var current = trie;
        current = try current.ensurePath(allocator, index, pattern);
        // If there isn't a value, use the pattern as the value instead.
        // Trie owns a copy of the value.
        const value = try (optional_value orelse pattern).copy(allocator);
        debug(
            "Added value of len {} at index {} and branch index {} on trie {*}",
            .{ value.root.len, index, current.value_branches.items.len, current },
        );
        try current.value_branches.append(
            allocator,
            IndexBranch{ index, .{ .value = value } },
        );
        return current;
    }

    /// Append a single trie entry (one already split out from its separators).
    /// An arrow splits the entry into a constant key and its value pattern;
    /// without one the whole entry is both key and value. This is the single
    /// source of entry semantics, so every parser that builds a trie directly
    /// arrives at the same result.
    pub fn appendEntry(self: *Self, allocator: Allocator, entry: Pattern) Allocator.Error!void {
        if (entry.root.len == 0) return;

        var arrow_index: ?usize = null;
        for (entry.root, 0..) |node, i| {
            if (node == .arrow) {
                arrow_index = i;
                break;
            }
        }

        if (arrow_index) |ai| {
            const constant = Pattern.fromSlice(entry.root[0..ai]);
            const arrow_pattern = entry.root[ai].arrow;
            // The arrow wrapper added a level of height; undo it for the value.
            const value = Pattern{ .root = arrow_pattern.root, .height = arrow_pattern.height -| 1 };
            _ = try self.append(allocator, constant, value);
        } else {
            _ = try self.append(allocator, entry, entry);
        }
    }

    /// A partial or complete match of a given pattern against a trie.
    pub const Match = struct {
        query: Pattern = .{}, // The pattern that was attempted to match
        value: ?Pattern = null,
        trie_ptr: *const Trie, // The last node matched, contains the value if any
        match_index: usize = 0,
        len: usize = 0, // For partial matches

        /// Node entries are just references, so they aren't freed by this
        /// function.
        pub fn deinit(self: *Match, allocator: Allocator) void {
            self.query.deinit(allocator);
        }
    };

    /// A result from a match. The branch stores the next lowest possible node
    /// or value, and the trie stores the next trie that matched. If the branch
    /// has a trie entry, it is *not* the same as this trie.
    const IndexBranchTrie = struct {
        index: usize,
        branch: Branch,
        trie: *const Trie,

        pub fn deinit(self: *IndexBranchTrie, allocator: Allocator) void {
            self.trie.deinit(allocator);
        }
    };

    /// Find the first branch at or after bound in the given branch list.
    fn findNextInBranches(branches: []const IndexBranch, bound: Bound) ?IndexBranch {
        const branch_index = sort.lowerBound(
            IndexBranch,
            branches,
            bound.lower,
            struct {
                fn lessThan(
                    ctx: usize,
                    branch: IndexBranch,
                ) Order {
                    const i, _ = branch;
                    return math.order(ctx, i);
                }
            }.lessThan,
        );
        return if (branch_index < branches.len) {
            const result = branches[branch_index];
            const result_index, _ = result;
            return if (result_index < bound.upper)
                result
            else
                null;
        } else null;
    }

    /// Finds the next minimum constant at this node by index.
    fn findNextConstant(self: Self, bound: Bound) ?IndexBranch {
        return findNextInBranches(self.constant_branches.items, bound);
    }

    /// Finds the next minimum variable at this node by index.
    fn findNextVar(self: Self, bound: Bound) ?IndexBranch {
        return findNextInBranches(self.var_branches.items, bound);
    }

    /// Finds the next minimum value at this node by index.
    fn findNextValue(self: Self, bound: Bound) ?IndexBranch {
        return findNextInBranches(self.value_branches.items, bound);
    }

    /// Finds the next minimum constant, variable or value across all branch types.
    fn findNext(self: Self, bound: Bound) ?IndexBranch {
        const constant_branch = self.findNextConstant(bound);
        const var_branch = self.findNextVar(bound);
        const value_branch = self.findNextValue(bound);

        var min_branch: ?IndexBranch = null;
        var min_index: usize = math.maxInt(usize);

        if (constant_branch) |kb| {
            const idx, _ = kb;
            if (idx < min_index) {
                min_index = idx;
                min_branch = kb;
            }
        }
        if (var_branch) |vb| {
            const idx, _ = vb;
            if (idx < min_index) {
                min_index = idx;
                min_branch = vb;
            }
        }
        if (value_branch) |valb| {
            const idx, _ = valb;
            if (idx < min_index) {
                min_branch = valb;
            }
        }

        return min_branch;
    }

    /// Whether this trie (the continuation after a var_pattern) has a branch
    /// that could match `node`, so the var_pattern should stop capturing here
    /// and let the rest of the rule resume. A following variable matches any
    /// term.
    fn continuesAt(self: *const Self, node: Node) bool {
        if (self.var_branches.items.len > 0) return true;
        return switch (node) {
            inline .constant, .char => |c| self.getToken(c) != null,
            .infix => |inf| self.getToken(inf.op) != null,
            .pattern => self.getToken("(") != null,
            else => false,
        };
    }

    /// Walk a structural separator token (its bytes plus the delimiter) and
    /// return the trie it leads to.
    fn getSeparatorTrie(self: *const Self, key: []const u8) ?*Trie {
        _, const after = self.getByteEntry(key) orelse return null;
        const delim_entry = after.map.getEntry(delim) orelse return null;
        return delim_entry.value_ptr;
    }

    /// Find the first term at or after bound
    fn matchTerm(
        self: *const Self,
        allocator: Allocator,
        bound: Bound,
        term_bindings: *VarBindings,
        node: Node,
    ) Allocator.Error!?IndexBranchTrie {
        // Check for variable branches that match anything
        if (self.findNextVar(bound)) |var_candidate| {
            const var_bound, const var_branch = var_candidate;

            const branch_node = switch (var_branch) {
                .variable => |variable| variable,
                .value => panic("Expected variable, found value", .{}),
                inline else => |b, tag| panic(
                    "Expected variable, found {s} at {*}",
                    .{ @tagName(tag), b.entry.value_ptr },
                ),
            };
            const variable = branch_node.entry.key_ptr.*;

            // Var patterns (variables starting with '*') capture the rest of the pattern,
            // not just a single node. They are handled in match(), not here.
            if (var_branch.isVarPattern()) {
                return .{
                    .index = var_bound,
                    .branch = var_branch,
                    .trie = branch_node.entry.value_ptr,
                };
            }

            const get_or_put = try term_bindings.getOrPut(allocator, variable);

            // Variable already bound - only match if node equals bound value
            if (get_or_put.found_existing) {
                if (get_or_put.value_ptr.eql(node))
                    return .{
                        .index = var_bound,
                        .branch = var_branch,
                        .trie = branch_node.entry.value_ptr,
                    }
                else {
                    // TODO
                }
            } else {
                // Bind the variable to this node
                get_or_put.value_ptr.* = node;
                // TODO: save for later, we still need to compare indices
                // with possible matches below to find the smallest
                return .{
                    .index = var_bound,
                    .branch = var_branch,
                    .trie = branch_node.entry.value_ptr,
                };
            }
        }

        // Now check for exact matches based on node type
        switch (node) {
            inline .constant, .char => |constant| {
                debug(
                    "Checking {*} for constant match {s} at bound {}",
                    .{ self, constant, bound },
                );
                return self.getBranch(bound, constant);
            },

            .variable => |variable| {
                // A subject variable is opaque: it can only match a trie var
                // branch (handled above), never a concrete rule term.
                debug("Subject variable {s} has no var branch to match", .{variable});
                return null;
            },
            .pattern => |pattern| {
                // Match opening paren
                const open_trie = self.getSeparatorTrie("(") orelse
                    return null;
                debug("Matching sub-pattern on {*}", .{open_trie});
                var index, _ = open_trie.findNext(bound) orelse
                    return null;

                // Recursively match the pattern contents
                var pattern_match = try open_trie
                    .match(allocator, .{ .lower = index, .upper = bound.upper }, term_bindings, pattern);
                defer pattern_match.deinit(allocator);
                index = pattern_match.match_index;
                if (pattern_match.len != pattern.root.len) {
                    debug("Sub-pattern match failed: only matched {} of {} terms", .{
                        pattern_match.len,
                        pattern.root.len,
                    });
                    return null;
                }
                debug("Sub-pattern matched {*}", .{pattern_match.trie_ptr});
                // Successfully matched entire pattern, now match closing paren
                const close_trie = pattern_match.trie_ptr.getSeparatorTrie(")") orelse
                    return null;
                debug("Closing paren matched {*}", .{close_trie});
                index, const branch = close_trie.findNext(.{ .lower = index, .upper = bound.upper }) orelse
                    return null;
                debug("Sub-pattern matched, returning trie: {*}", .{close_trie});
                // As with constant matching, don't return the next trie, but rather
                // the current trie (which we got from looking up the closing paren)
                return .{
                    .index = index,
                    .branch = branch,
                    .trie = close_trie,
                };
            },

            // Separators flatten onto the trie path as a key (`,` or `\n`)
            // followed by their contents. `.indent` evaluates like a comma.
            .list => |pattern| return self.matchSeparator(allocator, bound, term_bindings, ",", pattern),
            .semicolon => |pattern| return self.matchSeparator(allocator, bound, term_bindings, ";", pattern),
            .newline => |sep| return self.matchSeparator(allocator, bound, term_bindings, "\n", sep.rhs),
            .indent => |sep| return self.matchSeparator(allocator, bound, term_bindings, ",", sep.rhs),
            .trie => |query_trie| {
                var trie_pattern = try query_trie.toPattern(allocator);
                defer trie_pattern.deinit(allocator);

                var trie_match = try self.match(allocator, bound, term_bindings, trie_pattern);
                defer trie_match.deinit(allocator);

                const final_branch = trie_match.trie_ptr.findNext(.{ .lower = trie_match.match_index, .upper = bound.upper }) orelse
                    return null;
                _, const branch = final_branch;
                return .{
                    .index = trie_match.match_index,
                    .branch = branch,
                    .trie = trie_match.trie_ptr,
                };
            },
            // list: the operator symbol becomes a constant on the trie path,
            // followed by its operands. Match it the same way: look up the
            // operator constant, then recursively match the operand pattern.
            .infix => |inf| {
                debug("Matching infix {s} with {} operand(s)", .{ inf.op, inf.rhs.root.len });
                const open_trie = self.getSeparatorTrie(inf.op) orelse
                    return null;
                var index, _ = open_trie.findNext(bound) orelse
                    return null;

                var operand_match = try open_trie
                    .match(allocator, .{ .lower = index, .upper = bound.upper }, term_bindings, inf.rhs);
                defer operand_match.deinit(allocator);
                index = operand_match.match_index;
                if (operand_match.len != inf.rhs.root.len) {
                    debug("Infix match failed: only matched {} of {} operands", .{
                        operand_match.len,
                        inf.rhs.root.len,
                    });
                    return null;
                }

                const final_branch = operand_match.trie_ptr.findNext(.{ .lower = index, .upper = bound.upper }) orelse
                    return null;
                _, const branch = final_branch;
                return .{
                    .index = index,
                    .branch = branch,
                    .trie = operand_match.trie_ptr,
                };
            },
            // Comments are stripped before matching; never matches a branch.
            .comment => return null,
            // Arrows and matches are flattened like infixes: the operator
            // constant (`->`/`:`) sits on the path followed by the rhs pattern.
            .arrow => |rhs| return self.matchSeparator(allocator, bound, term_bindings, "->", rhs),
            .match => |rhs| return self.matchSeparator(allocator, bound, term_bindings, ":", rhs),
        }

        return null;
    }

    /// Matches a separator node (`.list`/`.newline`/`.indent`): look up the
    /// separator key constant on the trie path, then recursively match the
    /// separator's contents.
    fn matchSeparator(
        self: *const Self,
        allocator: Allocator,
        bound: Bound,
        term_bindings: *VarBindings,
        sep_key: []const u8,
        pattern: Pattern,
    ) Allocator.Error!?IndexBranchTrie {
        const open_trie = self.getSeparatorTrie(sep_key) orelse
            return null;
        debug("Matched separator at {*}", .{open_trie});
        var index, _ = open_trie.findNext(bound) orelse
            return null;

        // Recursively match the separator contents
        var pattern_match = try open_trie
            .match(allocator, .{ .lower = index, .upper = bound.upper }, term_bindings, pattern);
        defer pattern_match.deinit(allocator);
        index = pattern_match.match_index;

        // Check that the full pattern matched
        if (pattern_match.len != pattern.root.len) {
            debug("Separator match failed: only matched {} of {} terms", .{
                pattern_match.len,
                pattern.root.len,
            });
            return null;
        }

        debug("Matched separator tail at {*}", .{pattern_match.trie_ptr});
        const final_branch = pattern_match.trie_ptr.findNext(.{ .lower = index, .upper = bound.upper }) orelse
            return null;
        _, const branch = final_branch;
        return .{
            .index = index,
            .branch = branch,
            .trie = pattern_match.trie_ptr,
        };
    }

    /// Finds the lowest index full match for the entire pattern.
    /// A full match means every term in the pattern matched a branch in the trie.
    pub fn match(
        self: *const Self,
        allocator: Allocator,
        bound: Bound,
        term_bindings: *VarBindings,
        pattern: Pattern,
    ) Allocator.Error!Match {
        debug(
            "=== Starting match for pattern of length {} from bound {} ===",
            .{ pattern.root.len, bound },
        );
        var node_list = ArrayList(Node).empty;
        errdefer for (node_list.items) |term| term.deinit(allocator);
        var current = self;
        var index = bound.lower;
        var result: ?Pattern = null;
        // For each subsequent term, extend candidates that can continue matching
        var pattern_index: usize = 0;

        // Handle empty pattern: check if var_pattern can match it
        if (pattern.root.len == 0) {
            if (current.findNextVar(bound)) |var_candidate| {
                const var_index, const var_branch = var_candidate;
                // Only capture the empty pattern into this var_pattern when no
                // sibling constant branch is available. A bare empty tuple `()`
                // has a `)` constant to match here, so prefer that; a
                // trailing-comma tail (e.g. `(x,)`) has only the var, so it
                // captures the empty segment.
                if (var_branch.isVarPattern() and
                    current.findNextConstant(bound) == null)
                {
                    const var_name = var_branch.variable.entry.key_ptr.*;
                    const var_trie = var_branch.variable.entry.value_ptr;
                    // Bind var_pattern to empty pattern
                    const get_or_put = try term_bindings.getOrPut(allocator, var_name);
                    if (!get_or_put.found_existing) {
                        get_or_put.value_ptr.* = .{ .pattern = pattern };
                    }
                    try node_list.append(allocator, Node{ .variable = var_name });
                    current = var_trie;
                    index = var_index;
                    // Check for value in var_trie
                    if (var_trie.findNextValue(.{ .lower = var_index, .upper = bound.upper })) |value_candidate| {
                        _, const value_branch = value_candidate;
                        result = value_branch.value;
                    }
                }
            }
        }

        match_loop: while (pattern_index < pattern.root.len) : (pattern_index += 1) {
            const index_branch_trie = try current.matchTerm(
                allocator,
                .{ .lower = index, .upper = bound.upper },
                term_bindings,
                pattern.root[pattern_index],
            ) orelse {
                debug(
                    "matchTerm failed from bound {} on {*} at pattern index {}",
                    .{ bound, current, pattern_index },
                );
                break;
            };
            index = index_branch_trie.index;
            const branch = index_branch_trie.branch;
            switch (branch) {
                .constant => {
                    // A constant branch is an exact byte match of the query
                    // term, so the matched node is the query node itself. Copy
                    // it: `node_list` becomes the owned `Match.query`, so a
                    // shallow share of a compound node (e.g. a nested
                    // `.pattern`) would double-free against the caller's query.
                    debug("Appending constant branch at index {}", .{index});
                    try node_list.append(
                        allocator,
                        try pattern.root[pattern_index].copy(allocator),
                    );
                },
                .variable => |variable| {
                    const var_name = variable.entry.key_ptr.*;
                    debug(
                        "Appending variable branch at index {} of {s}",
                        .{ index, var_name },
                    );
                    try node_list.append(
                        allocator,
                        Node{ .variable = var_name },
                    );
                    const node = pattern.root[pattern_index];
                    // For compound nodes (list, pattern, etc.), regular variable bindings
                    // already happened in the recursive matchTerm call. But var_patterns
                    // need special handling because they capture the rest of the pattern.
                    const is_compound = switch (node) {
                        .list, .semicolon, .pattern, .match, .arrow, .infix => true,
                        else => false,
                    };
                    // Var patterns (starting with '*') capture the rest of the
                    // pattern. The exception is when this var is followed by a
                    // separator in the trie (e.g. the rule `*x, *y` stores a `,`
                    // branch after `*x`): then it captures only up to the next
                    // list/newline separator, leaving the separator and the
                    // following segment to be matched by the rest of the rule.
                    // A lone var_pattern has no separator branch, so it still
                    // swallows the whole list (needed for `map` and friends).
                    if (branch.isVarPattern()) {
                        const var_trie = variable.entry.value_ptr;
                        // The var_pattern captures a run of terms starting at
                        // this one. A list separator always ends the segment.
                        // Otherwise it extends until the rest of the rule (the
                        // trie continuation after the var) can resume matching
                        // an upcoming term; a trailing var with no such
                        // continuation swallows everything that remains.
                        const segmented = var_trie.map.get(',') != null or
                            var_trie.map.get(';') != null or
                            var_trie.map.get('\n') != null;
                        var boundary = pattern_index + 1;
                        while (boundary < pattern.root.len) : (boundary += 1) {
                            if (segmented) {
                                switch (pattern.root[boundary]) {
                                    .list, .semicolon, .newline, .indent => break,
                                    else => {},
                                }
                            } else if (var_trie.continuesAt(pattern.root[boundary])) {
                                break;
                            }
                        }
                        const rest_root = pattern.root[pattern_index..boundary];
                        var rest_height: usize = 0;
                        for (rest_root) |rest_node| {
                            rest_height = @max(rest_height, rest_node.height());
                        }
                        const rest = Pattern{
                            .root = rest_root,
                            .height = rest_height,
                        };
                        const get_or_put = try term_bindings.getOrPut(allocator, var_name);
                        if (get_or_put.found_existing) {
                            switch (get_or_put.value_ptr.*) {
                                .pattern => |existing_pattern| {
                                    // Conflicting capture: this var_pattern is
                                    // already bound to a different segment, so
                                    // the match fails here. Stop at the current
                                    // len with a null value; the evaluator keeps
                                    // the expression unchanged on a failed match.
                                    if (!existing_pattern.eql(rest))
                                        break :match_loop;
                                },
                                else => @panic("unimplemented: var_pattern bound to non-pattern value"),
                            }
                        } else {
                            debug("Assigning rest to var pattern at {*}", .{get_or_put.value_ptr});
                            get_or_put.value_ptr.* = .{ .pattern = rest };
                        }
                        current = var_trie;
                        if (boundary == pattern.root.len) {
                            pattern_index = pattern.root.len;
                            break; // Captured everything; nothing left to match.
                        }
                        // Advance past the captured segment; the loop's `+= 1`
                        // lands on the separator so it is matched next.
                        pattern_index = boundary - 1;
                        continue;
                    } else if (!is_compound) {
                        // Regular variables for non-compound nodes
                        const get_or_put = try term_bindings.getOrPut(allocator, var_name);
                        if (get_or_put.found_existing) {
                            // Conflicting capture: same as the var_pattern case
                            // above, fail the match here and let the evaluator
                            // keep the expression as-is.
                            if (!get_or_put.value_ptr.eql(node))
                                break :match_loop;
                        } else {
                            get_or_put.value_ptr.* = node;
                        }
                    }
                    current = variable.entry.value_ptr;
                },
                .value => |value| {
                    result = value;
                    debug(
                        "Found value branch at index {} address {*}",
                        .{ index, current },
                    );
                    pattern_index += 1;
                    break;
                },
            }
            current = index_branch_trie.trie;
        }
        const full_match = pattern_index == pattern.root.len;
        debug(
            "pattern_index {} == pattern root len: {}",
            .{ pattern_index, pattern.root.len },
        );
        if (!full_match)
            debug("No full match found", .{})
        else {
            if (current.findNextValue(.{ .lower = index, .upper = bound.upper })) |value_candidate| {
                debug("Value found", .{});
                _, const value_branch = value_candidate;
                result = value_branch.value;
            }
        }

        const constant_nodes = try node_list.toOwnedSlice(allocator);
        var max_child: usize = 0;
        for (constant_nodes) |n| max_child = @max(max_child, n.height());
        return Match{
            .query = Pattern{ .root = constant_nodes, .height = max_child },
            .value = if (full_match) result else null,
            .trie_ptr = current,
            .match_index = index,
            .len = pattern_index,
        };
    }

    /// Rewrites all variable captures into the matched expression. Copies any
    /// variables in node if they are keys in bindings with their values. If
    /// there are no matches in bindings, this function is equivalent to copy.
    pub fn rewrite(
        allocator: Allocator,
        pattern: Pattern,
        term_bindings: *const VarBindings,
    ) Allocator.Error!Pattern {
        var result = ArrayList(Node).empty;
        errdefer result.deinit(allocator);
        var max_child: usize = 0;

        for (pattern.root) |node| switch (node) {
            inline .constant, .char => |c, tag| try result.append(allocator, @unionInit(Node, @tagName(tag), c)),
            .variable => |variable| {
                const is_var_pattern = variable.len > 0 and variable[0] == '*';
                if (is_var_pattern) {
                    if (term_bindings.get(variable)) |sub_pattern| {
                        debug("Var pattern found: {s}", .{variable});
                        for (sub_pattern.pattern.root) |sub_node| {
                            const copied = try sub_node.copy(allocator);
                            max_child = @max(max_child, copied.height());
                            try result.append(allocator, copied);
                        }
                    } else try result.append(allocator, node);
                } else {
                    if (term_bindings.get(variable)) |bound_node| {
                        debug("Var found: {s}", .{variable});
                        const copied = try bound_node.copy(allocator);
                        max_child = @max(max_child, copied.height());
                        try result.append(allocator, copied);
                    } else {
                        debug("Var not found", .{});
                        try result.append(allocator, node);
                    }
                }
            },
            inline .pattern, .arrow, .match, .list, .semicolon => |nested, tag| {
                const rewritten = try rewrite(allocator, nested, term_bindings);
                const wrapped = Pattern{ .root = rewritten.root, .height = rewritten.height + 1 };
                max_child = @max(max_child, wrapped.height);
                try result.append(allocator, @unionInit(Node, @tagName(tag), wrapped));
            },
            .infix => |inf| {
                const rewritten = try rewrite(allocator, inf.rhs, term_bindings);
                const wrapped = Pattern{ .root = rewritten.root, .height = rewritten.height + 1 };
                max_child = @max(max_child, wrapped.height);
                try result.append(allocator, Node{ .infix = .{ .op = inf.op, .rhs = wrapped } });
            },
            // A trie literal carries no rewritable variables of its own; copy it
            // through so a value like `A : {trie}` survives the rewrite intact.
            .trie => try result.append(allocator, try node.copy(allocator)),
            // Comments are kept in the trie (so its print stays layout-faithful) but
            // are inert: drop them from a rewritten value so they never reach output.
            .comment => {},
            else => panic("unimplemented", .{}),
        };

        const nodes = try result.toOwnedSlice(allocator);
        return Pattern{ .root = nodes, .height = max_child };
    }

    /// The rewritten value of the lowest full match of `pattern` within `bound`,
    /// or null when nothing matched. Combines `match` and `rewrite` so callers
    /// (the evaluation steps) get a single `orelse return null` and never have to
    /// thread bindings or the raw `Match` themselves. The caller owns the
    /// returned pattern. `match_index` is the index the match was found at, which
    /// the steps use to shrink their bounds.
    pub fn matchRewrite(
        self: *const Self,
        allocator: Allocator,
        bound: Bound,
        pattern: Pattern,
    ) Allocator.Error!?struct { value: Pattern, match_index: usize } {
        var term_bindings = VarBindings{};
        defer term_bindings.deinit(allocator);
        var result = try self.match(allocator, bound, &term_bindings, pattern);
        defer result.deinit(allocator);
        const matched_value = result.value orelse return null;
        return .{
            .value = try rewrite(allocator, matched_value, &term_bindings),
            .match_index = result.match_index,
        };
    }

    /// The number of indexed entries in this trie. Matching an index ranges over
    /// `[lower = 0, upper = trie.length())`, so this is the starting upper bound.
    pub fn length(self: Self) usize {
        return self.constant_branches.items.len +
            self.var_branches.items.len +
            self.value_branches.items.len;
    }

    /// Returns a slice of constants, where each constant is concatenated into a string.
    pub fn constants(self: Self, allocator: Allocator) ![][]const u8 {
        const result = try allocator.alloc([][]const u8, self.count());
        for (result) |slice_ptr| {
            var constant_list = ArrayList([]const u8){};
            try self.writeValues(allocator, constant_list);
            slice_ptr = constant_list.toOwnedSlice(allocator);
        }
        return result;
    }

    pub fn valuesAsPatterns(self: Self, allocator: Allocator) ![]Pattern {
        const result = try allocator.alloc(Pattern, self.count());
        self.writeValues(result);
        return result;
    }

    /// Pretty print a trie on multiple lines
    pub fn pretty(self: Self, writer: anytype) !void {
        try self.writeIndent(writer, 0);
    }

    pub fn toString(self: Self, allocator: Allocator) ![]const u8 {
        var buff: std.ArrayList(u8) = .empty;
        errdefer buff.deinit(allocator);
        var allocating_writer = Io.Writer.Allocating
            .fromArrayList(allocator, &buff);
        try self.writeCanonical(&allocating_writer.writer);
        return allocating_writer.toOwnedSlice();
    }

    /// Print a trie without newlines
    pub fn write(self: Self, writer: anytype) !void {
        try self.writeIndent(writer, null);
    }

    /// Writes a single entry in the trie canonically by traversing from root.
    fn writeEntryAtIndex(
        self: *const Self,
        writer: anytype,
        index: usize,
    ) !void {
        var current = self;
        const index_bound = Bound{ .lower = index, .upper = index + 1 };
        while (true) {
            // Follow a constant byte branch. A whole token is spelled across
            // several bytes; emit it only at its delimiter leaf (the node
            // carrying the stored token).
            if (findNextInBranches(current.constant_branches.items, index_bound)) |kb| {
                const found_index, const branch = kb;
                if (found_index == index) {
                    current = branch.constant.entry.value_ptr;
                    if (current.token.len != 0) {
                        try writer.writeAll(current.token);
                        try writer.writeByte(' ');
                    }
                    continue;
                }
            }
            // Then check vars
            if (findNextInBranches(current.var_branches.items, index_bound)) |vb| {
                const found_index, const branch = vb;
                if (found_index == index) {
                    const variable = branch.variable.entry.key_ptr.*;
                    try writer.writeAll(variable);
                    try writer.writeByte(' ');
                    current = branch.variable.entry.value_ptr;
                    continue;
                }
            }
            // Finally check values
            if (findNextInBranches(current.value_branches.items, index_bound)) |valb| {
                const found_index, const branch = valb;
                if (found_index == index) {
                    try writer.writeAll("--> ");
                    try branch.value.writeIndent(writer, null);
                    return;
                }
            }
            break;
        }
    }

    /// Print a trie in order based on indices.
    pub fn writeCanonical(self: Self, writer: anytype) !void {
        const allocator = std.heap.page_allocator;
        const indices = try self.valueIndices(allocator);
        defer allocator.free(indices);

        for (indices) |idx| {
            try self.writeEntryAtIndex(writer, idx);
            try writer.writeByte('\n');
        }
    }

    fn collectValueIndices(self: *const Self, allocator: Allocator, indices: *std.ArrayList(usize)) Allocator.Error!void {
        for (self.value_branches.items) |index_branch| {
            const idx, _ = index_branch;
            try indices.append(allocator, idx);
        }
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            try entry.value_ptr.collectValueIndices(allocator, indices);
        }
    }

    /// Converts a trie to its flattened pattern representation.
    /// The trie is encoded as: { constant1 -> val1, constant2 -> val2, ... }
    /// Caller owns the returned pattern and should free it with `Pattern.deinit`.
    pub fn toPattern(self: *const Self, allocator: Allocator) Allocator.Error!Pattern {
        var nodes = ArrayList(Node).empty;
        errdefer nodes.deinit(allocator);

        try nodes.append(allocator, .{ .constant = "{" });

        const indices = try self.valueIndices(allocator);
        defer allocator.free(indices);

        for (indices, 0..) |entry_idx, i| {
            if (i > 0) {
                try nodes.append(allocator, .{ .constant = "," });
            }

            const constant_pat = try self.rebuildConstant(allocator, entry_idx);
            defer allocator.free(constant_pat.root);

            for (constant_pat.root) |node| {
                try nodes.append(allocator, node);
            }

            try nodes.append(allocator, .{ .constant = "->" });

            const value = self.getIndexOrNull(entry_idx) orelse continue;
            for (value.root) |node| {
                try nodes.append(allocator, try node.copy(allocator));
            }
        }

        try nodes.append(allocator, .{ .constant = "}" });

        const root = try nodes.toOwnedSlice(allocator);
        return Pattern{ .root = root, .height = 0 };
    }

    /// Returns sorted, deduplicated value indices. Caller owns the returned slice.
    pub fn valueIndices(self: *const Self, allocator: Allocator) Allocator.Error![]usize {
        var indices = std.ArrayList(usize).empty;
        errdefer indices.deinit(allocator);
        try self.collectValueIndices(allocator, &indices);
        std.mem.sort(usize, indices.items, {}, std.sort.asc(usize));

        // Deduplicate in place
        var write_pos: usize = 0;
        var last: ?usize = null;
        for (indices.items) |idx| {
            if (last == null or last.? != idx) {
                indices.items[write_pos] = idx;
                write_pos += 1;
                last = idx;
            }
        }
        indices.items.len = write_pos;

        return indices.toOwnedSlice(allocator);
    }

    pub const indent_increment = 2;
    pub fn writeIndent(
        self: *const Self,
        writer: anytype,
        optional_indent: ?usize,
    ) Writer.Error!void {
        try writer.writeAll("❬");
        for (self.value_branches.items) |index_branch| {
            _, const branch = index_branch;
            try branch.value.writeIndent(writer, null);
            try writer.writeAll(", ");
        }
        try writer.writeAll("❭ ");
        const optional_indent_inc = if (optional_indent) |indent|
            indent + indent_increment
        else
            null;
        try writer.writeByte('{');
        try writer.writeAll(if (optional_indent) |_| "\n" else "");
        try self.writeEntries(writer, optional_indent_inc);
        for (0..optional_indent orelse 0) |_|
            try writer.writeByte(' ');
        try writer.writeByte('}');
        try writer.writeAll(if (optional_indent) |_| "\n" else "");
    }

    // Print each branch key once. The byte map keys the constant path one byte
    // at a time and the var map keys whole variable names; both already store
    // each key uniquely, so iterating them directly needs no dedup.
    fn writeEntries(
        self: *const Self,
        writer: anytype,
        optional_indent: ?usize,
    ) Writer.Error!void {
        // The byte and var maps are hash maps whose iteration order depends on
        // insertion order and collisions, which differ between two tries built
        // from the same source by different parsers (and shift when a trie is
        // copied). Sort the keys so this rendering is canonical and two equal
        // tries print identically, which the `Parsable` tests rely on.
        const gpa = std.heap.page_allocator;

        var byte_keys = std.ArrayList(u8).empty;
        defer byte_keys.deinit(gpa);
        var byte_iter = self.map.keyIterator();
        while (byte_iter.next()) |key| byte_keys.append(gpa, key.*) catch return error.WriteFailed;
        std.mem.sort(u8, byte_keys.items, {}, std.sort.asc(u8));

        for (byte_keys.items) |key| {
            for (0..optional_indent orelse 1) |_|
                try writer.writeByte(' ');
            try writer.writeByte(key);
            try writer.writeAll(" -> ");
            try self.map.getPtr(key).?.writeIndent(writer, optional_indent);
            try writer.writeAll(if (optional_indent) |_| "" else ", ");
        }

        var var_keys = std.ArrayList([]const u8).empty;
        defer var_keys.deinit(gpa);
        var var_iter = self.var_map.keyIterator();
        while (var_iter.next()) |key| var_keys.append(gpa, key.*) catch return error.WriteFailed;
        std.mem.sort([]const u8, var_keys.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        for (var_keys.items) |key| {
            for (0..optional_indent orelse 1) |_|
                try writer.writeByte(' ');
            try writer.writeAll(key);
            try writer.writeAll(" -> ");
            try self.var_map.getPtr(key).?.writeIndent(writer, optional_indent);
            try writer.writeAll(if (optional_indent) |_| "" else ", ");
        }
    }
};

const testing = std.testing;

test "Trie: eql" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var trie1 = Trie{};
    var trie2 = Trie{};

    var constant_root = [_]Node{
        .{ .constant = "Aa" },
        .{ .constant = "Bb" },
    };
    var val_root = [_]Node{.{ .constant = "Value" }};
    const constant_pat = Pattern{ .root = &constant_root };
    const val = Pattern{ .root = &val_root };
    const ptr1 = try trie1.append(allocator, constant_pat, val);
    const ptr2 = try trie2.append(allocator, constant_pat, val);

    try testing.expect(trie1.getIndexOrNull(0) != null);
    try testing.expect(trie2.getIndexOrNull(0) != null);

    // Compare leaves that share the same value
    try testing.expect(ptr1.eql(ptr2.*));

    // Compare tries that have the same constant and value
    try testing.expect(trie1.eql(trie2));
    try testing.expect(trie2.eql(trie1));
}

test "Structure: put single lit" {}

test "Structure: put multiple lits" {
    // Multiple constants
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    var val_root = [_]Node{.{ .constant = "Val" }};
    var constant_root = [_]Node{
        .{ .constant = "1" },
        .{ .constant = "2" },
        .{ .constant = "3" },
    };
    const val = Pattern{ .root = &val_root };
    _ = try trie.append(
        testing.allocator,
        Pattern{ .root = &constant_root },
        val,
    );
    try testing.expect(trie.getToken("1") != null);
    try testing.expect(trie.getToken("1").?.getToken("2") != null);
    try testing.expectEqualDeep(trie.getIndex(0), val);
}

test "Memory: simple" {
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    var empty_root = [_]Node{};
    var val1_root = [_]Node{.{ .constant = "123" }};
    var constant_pat2_root = [_]Node{ .{ .constant = "01" }, .{ .constant = "12" } };
    var val2_root = [_]Node{.{ .constant = "123" }};
    var constant_pat3_root = [_]Node{ .{ .constant = "01" }, .{ .constant = "12" } };
    var val3_root = [_]Node{.{ .constant = "234" }};

    const ptr1 = try trie.append(
        testing.allocator,
        Pattern{ .root = &empty_root },
        Pattern{ .root = &val1_root },
    );
    const ptr2 = try trie.append(
        testing.allocator,
        Pattern{ .root = &constant_pat2_root },
        Pattern{ .root = &val2_root },
    );
    const ptr3 = try trie.append(
        testing.allocator,
        Pattern{ .root = &constant_pat3_root },
        Pattern{ .root = &val3_root },
    );

    try testing.expect(ptr1 != ptr2);
    try testing.expectEqual(ptr2, ptr3);
}

test "Behavior: vars" {
    var nested_trie = try Trie.create(testing.allocator);
    defer nested_trie.destroy(testing.allocator);

    var val_root = [_]Node{.{ .constant = "Beautiful" }};
    _ = try nested_trie.appendConstant(
        testing.allocator,
        &.{
            "cherry",
            "blossom",
            "tree",
        },
        Pattern{ .root = &val_root },
    );
}

test "Behavior: nesting" {
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    // Insert a constant with a nested sub-pattern: (A B) -> Result
    var inner_root = [_]Node{ .{ .constant = "A" }, .{ .constant = "B" } };
    var constant_root = [_]Node{.{ .pattern = .{ .root = &inner_root } }};
    var val_root = [_]Node{.{ .constant = "Result" }};

    const constant_pat = Pattern{ .root = &constant_root };
    const val = Pattern{ .root = &val_root };
    _ = try trie.append(testing.allocator, constant_pat, val);

    // The nested pattern should be encoded as "(" -> "A" -> "B" -> ")"
    try testing.expect(trie.getToken("(") != null);
    const open_trie = trie.getToken("(").?;
    try testing.expect(open_trie.getToken("A") != null);
    const a_trie = open_trie.getToken("A").?;
    try testing.expect(a_trie.getToken("B") != null);
    const b_trie = a_trie.getToken("B").?;
    try testing.expect(b_trie.getToken(")") != null);

    // Should be retrievable via get
    const result = trie.get(constant_pat);
    try testing.expect(result != null);

    // Should retrieve the correct value at index 0
    try testing.expectEqualDeep(trie.getIndex(0), val);

    // A non-matching nested pattern should return null
    var wrong_inner = [_]Node{ .{ .constant = "A" }, .{ .constant = "C" } };
    var wrong_constant_root = [_]Node{.{ .pattern = .{ .root = &wrong_inner } }};
    const wrong_key = Pattern{ .root = &wrong_constant_root };
    try testing.expect(trie.get(wrong_key) == null);
}

test "Behavior: equal variables" {
    // Two entries with variables: both use var "x" but with different values
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    // Entry 0: x -> Val1
    var constant_pat1_root = [_]Node{.{ .variable = "x" }};
    var val1_root = [_]Node{.{ .constant = "Val1" }};
    _ = try trie.append(
        testing.allocator,
        Pattern{ .root = &constant_pat1_root },
        Pattern{ .root = &val1_root },
    );

    // Entry 1: x -> Val2 (same variable name, different value)
    var constant_pat2_root = [_]Node{.{ .variable = "x" }};
    var val2_root = [_]Node{.{ .constant = "Val2" }};
    _ = try trie.append(
        testing.allocator,
        Pattern{ .root = &constant_pat2_root },
        Pattern{ .root = &val2_root },
    );

    // Both entries share the same variable name in the var map
    try testing.expect(trie.var_map.contains("x"));
    try testing.expectEqual(@as(usize, 2), trie.length());

    // Matching from bound 0 should find index 0
    var term_bindings = VarBindings{};
    defer term_bindings.deinit(testing.allocator);

    var query_root = [_]Node{.{ .constant = "anything" }};
    const query = Pattern{ .root = &query_root };

    var match1 = try trie.match(
        testing.allocator,
        .{ .upper = trie.length() },
        &term_bindings,
        query,
    );
    defer match1.deinit(testing.allocator);
    // A variable in the trie should match the literal "anything"
    try testing.expect(match1.value != null);
    try testing.expectEqualDeep(
        match1.value.?,
        Pattern{ .root = &val1_root },
    );

    // The variable "x" should now be bound to the constant "anything"
    const bound_val = term_bindings.get("x");
    try testing.expect(bound_val != null);
    try testing.expect(std.meta.eql(bound_val.?, Node{ .constant = "anything" }));
}

test "Behavior: equal constants, different indices" {
    // TODO
}

test "Behavior: equal constants, different structure" {
    // Constants that share a prefix but diverge — they should coexist in the trie
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    // Entry 0: A B -> Val1
    var constant_pat1_root = [_]Node{ .{ .constant = "A" }, .{ .constant = "B" } };
    var val1_root = [_]Node{.{ .constant = "Val1" }};
    _ = try trie.append(
        testing.allocator,
        Pattern{ .root = &constant_pat1_root },
        Pattern{ .root = &val1_root },
    );

    // Entry 1: A C -> Val2 (shares prefix "A", diverges at second node)
    var constant_pat2_root = [_]Node{ .{ .constant = "A" }, .{ .constant = "C" } };
    var val2_root = [_]Node{.{ .constant = "Val2" }};
    _ = try trie.append(
        testing.allocator,
        Pattern{ .root = &constant_pat2_root },
        Pattern{ .root = &val2_root },
    );

    // Entry 2: A B D -> Val3 (extends entry 0's constant)
    var constant_pat3_root = [_]Node{ .{ .constant = "A" }, .{ .constant = "B" }, .{ .constant = "D" } };
    var val3_root = [_]Node{.{ .constant = "Val3" }};
    _ = try trie.append(
        testing.allocator,
        Pattern{ .root = &constant_pat3_root },
        Pattern{ .root = &val3_root },
    );

    // The root should only have "A" (shared prefix)
    try testing.expectEqual(@as(usize, 1), trie.map.count());
    try testing.expect(trie.getToken("A") != null);

    // Under "A", both "B" and "C" should exist
    const a_trie = trie.getToken("A").?;
    try testing.expect(a_trie.getToken("B") != null);
    try testing.expect(a_trie.getToken("C") != null);

    // Under "A" -> "B", "D" should also exist (from entry 2)
    const b_trie = a_trie.getToken("B").?;
    try testing.expect(b_trie.getToken("D") != null);

    // Each path should resolve to its correct value
    try testing.expectEqualDeep(
        trie.getIndex(0),
        Pattern{ .root = &val1_root },
    );
    try testing.expectEqualDeep(
        trie.getIndex(1),
        Pattern{ .root = &val2_root },
    );
    try testing.expectEqualDeep(
        trie.getIndex(2),
        Pattern{ .root = &val3_root },
    );

    // get() with full constant should find the right sub-trie
    const ab_result = trie.get(Pattern{ .root = &constant_pat1_root });
    try testing.expect(ab_result != null);

    const ac_result = trie.get(Pattern{ .root = &constant_pat2_root });
    try testing.expect(ac_result != null);

    const abd_result = trie.get(Pattern{ .root = &constant_pat3_root });
    try testing.expect(abd_result != null);

    // A non-existent path should return null
    var missing_root = [_]Node{ .{ .constant = "A" }, .{ .constant = "Z" } };
    try testing.expect(trie.get(Pattern{ .root = &missing_root }) == null);
}

test "Trie: equal to copy" {
    var nested_trie = try Trie.create(testing.allocator);
    defer nested_trie.destroy(testing.allocator);

    var val_root = [_]Node{.{ .constant = "Beautiful" }};
    _ = try nested_trie.appendConstant(
        testing.allocator,
        &.{
            "cherry",
            "blossom",
            "tree",
        },
        Pattern{ .root = &val_root },
    );
    var copy = try nested_trie.*.copy(testing.allocator);
    defer copy.deinit(testing.allocator);

    assert(nested_trie.eql(copy));
    assert(copy.eql(nested_trie.*));
}

test "findNextValue" {
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    var constant_root = [_]Node{
        .{ .constant = "A" },
        .{ .constant = "B" },
    };
    var val_root_1 = [_]Node{.{ .constant = "123" }};
    var val_root_2 = [_]Node{.{ .constant = "456" }};
    const constant_pat = Pattern{ .root = &constant_root };
    const value1 = Pattern{ .root = &val_root_1 };
    _ = try trie.append(testing.allocator, constant_pat, value1);
    const value2 = Pattern{ .root = &val_root_2 };
    _ = try trie.append(testing.allocator, constant_pat, value2);

    const value_trie = trie.get(constant_pat) orelse unreachable;
    var index_branch = value_trie.findNextValue(.{ .upper = value_trie.length() }) orelse unreachable;
    var value_index, var value_branch = index_branch;
    try testing.expect(value_index == 0);
    try testing.expect(value_branch.value.eql(value1));

    index_branch = value_trie.findNextValue(.{ .lower = 1, .upper = value_trie.length() }) orelse unreachable;
    value_index, value_branch = index_branch;
    try testing.expect(value_index == 1);
    try testing.expect(value_branch.value.eql(value2));
}

test "Trie: toString" {
    var trie = Trie{};
    defer trie.deinit(testing.allocator);
    var constant_root = [_]Node{ .{ .constant = "A" }, .{ .constant = "B" } };
    var val_root = [_]Node{.{ .constant = "Val" }};
    _ = try trie.append(
        testing.allocator,
        Pattern{ .root = &constant_root },
        Pattern{ .root = &val_root },
    );
    {
        const str = try trie.toString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A B --> Val\n", str);
    }
    _ = try trie.append(
        testing.allocator,
        Pattern{ .root = &constant_root },
        Pattern{ .root = &val_root },
    );
    {
        const str = try trie.toString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A B --> Val\nA B --> Val\n", str);
    }
}

test "Roundtrip: A -> C -> B" {
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    // A --> C (index 0)
    var constant_pat1 = [_]Node{.{ .constant = "A" }};
    var val1 = [_]Node{.{ .constant = "C" }};
    _ = try trie.append(testing.allocator, Pattern{ .root = &constant_pat1 }, Pattern{ .root = &val1 });

    // C --> B (index 1)
    var constant_pat2 = [_]Node{.{ .constant = "C" }};
    var val2 = [_]Node{.{ .constant = "B" }};
    _ = try trie.append(testing.allocator, Pattern{ .root = &constant_pat2 }, Pattern{ .root = &val2 });

    // B --> A (index 2)
    var constant_pat3 = [_]Node{.{ .constant = "B" }};
    var val3 = [_]Node{.{ .constant = "A" }};
    _ = try trie.append(testing.allocator, Pattern{ .root = &constant_pat3 }, Pattern{ .root = &val3 });

    // A --> B (index 3)
    var constant_pat4 = [_]Node{.{ .constant = "A" }};
    var val4 = [_]Node{.{ .constant = "B" }};
    _ = try trie.append(testing.allocator, Pattern{ .root = &constant_pat4 }, Pattern{ .root = &val4 });

    // Query A, should evaluate to B
    var query = [_]Node{.{ .constant = "A" }};
    var term_bindings = VarBindings{};
    defer term_bindings.deinit(testing.allocator);
    var eval_result = try trie.match(
        testing.allocator,
        .{ .lower = 0, .upper = trie.length() },
        &term_bindings,
        Pattern{ .root = &query },
    );
    defer eval_result.deinit(testing.allocator);

    // A single match prioritizes the lowest rule, so `A` matches `A --> C`
    // (index 0), not the later `A --> B`. The matched value is a reference into
    // the trie (freed with the trie), so it must not be deinitialized here.
    if (eval_result.value) |value| {
        const str = try value.toString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("C", str);
    } else {
        try testing.expect(false);
    }
}

test "rebuildConstant: multiple entries" {
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    var constant_pat0 = [_]Node{ .{ .constant = "A" }, .{ .constant = "B" }, .{ .variable = "x" } };
    var constant_pat1 = [_]Node{ .{ .constant = "A" }, .{ .constant = "C" } };
    var constant_pat2 = [_]Node{ .{ .constant = "A" }, .{ .constant = "B" }, .{ .variable = "y" } };
    var val = [_]Node{.{ .constant = "V" }};
    _ = try trie.append(testing.allocator, .{ .root = &constant_pat0 }, .{ .root = &val });
    _ = try trie.append(testing.allocator, .{ .root = &constant_pat1 }, .{ .root = &val });
    _ = try trie.append(testing.allocator, .{ .root = &constant_pat2 }, .{ .root = &val });

    var r0 = try trie.rebuildConstant(testing.allocator, 0);
    defer testing.allocator.free(r0.root);
    var r1 = try trie.rebuildConstant(testing.allocator, 1);
    defer testing.allocator.free(r1.root);
    var r2 = try trie.rebuildConstant(testing.allocator, 2);
    defer testing.allocator.free(r2.root);

    const s0 = try r0.toString(testing.allocator);
    defer testing.allocator.free(s0);
    const s1 = try r1.toString(testing.allocator);
    defer testing.allocator.free(s1);
    const s2 = try r2.toString(testing.allocator);
    defer testing.allocator.free(s2);

    try testing.expectEqualStrings("A B x", s0);
    try testing.expectEqualStrings("A C", s1);
    try testing.expectEqualStrings("A B y", s2);
}

test "rebuildConstant: nested with list" {
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    var list_inner = [_]Node{.{ .variable = "y" }};
    var inner = [_]Node{ .{ .variable = "x" }, .{ .list = .{ .root = &list_inner } } };
    var constant_pat = [_]Node{.{ .pattern = .{ .root = &inner } }};
    var val = [_]Node{.{ .constant = "V" }};
    _ = try trie.append(testing.allocator, .{ .root = &constant_pat }, .{ .root = &val });

    var rebuilt = try trie.rebuildConstant(testing.allocator, 0);
    defer testing.allocator.free(rebuilt.root);
    const str = try rebuilt.toString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("( x, y )", str);
}

test "rebuildConstant: embedded trie with multiple entries" {
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    var inner_trie = Trie{};
    defer inner_trie.deinit(testing.allocator);
    var inner_constant0 = [_]Node{.{ .constant = "A" }};
    var inner_val0 = [_]Node{.{ .constant = "B" }};
    var inner_constant1 = [_]Node{ .{ .constant = "C" }, .{ .constant = "D" } };
    var inner_val1 = [_]Node{.{ .constant = "E" }};
    _ = try inner_trie.append(testing.allocator, .{ .root = &inner_constant0 }, .{ .root = &inner_val0 });
    _ = try inner_trie.append(testing.allocator, .{ .root = &inner_constant1 }, .{ .root = &inner_val1 });

    var constant_pat = [_]Node{ .{ .constant = "X" }, .{ .trie = inner_trie }, .{ .constant = "Y" } };
    var val = [_]Node{.{ .constant = "V" }};
    _ = try trie.append(testing.allocator, .{ .root = &constant_pat }, .{ .root = &val });

    var rebuilt = try trie.rebuildConstant(testing.allocator, 0);
    defer testing.allocator.free(rebuilt.root);
    const str = try rebuilt.toString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("X { A -> B, C D -> E } Y", str);
}

test "rebuildConstant: multiple nested tries" {
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    var inner1 = Trie{};
    defer inner1.deinit(testing.allocator);
    var i1_key = [_]Node{.{ .constant = "A" }};
    var i1_val = [_]Node{.{ .constant = "B" }};
    _ = try inner1.append(testing.allocator, .{ .root = &i1_key }, .{ .root = &i1_val });

    var inner2 = Trie{};
    defer inner2.deinit(testing.allocator);
    var i2_key0 = [_]Node{.{ .constant = "C" }};
    var i2_val0 = [_]Node{.{ .constant = "D" }};
    var i2_key1 = [_]Node{.{ .constant = "E" }};
    var i2_val1 = [_]Node{.{ .constant = "F" }};
    _ = try inner2.append(testing.allocator, .{ .root = &i2_key0 }, .{ .root = &i2_val0 });
    _ = try inner2.append(testing.allocator, .{ .root = &i2_key1 }, .{ .root = &i2_val1 });

    var constant_pat = [_]Node{ .{ .trie = inner1 }, .{ .constant = "X" }, .{ .trie = inner2 } };
    var val = [_]Node{.{ .constant = "V" }};
    _ = try trie.append(testing.allocator, .{ .root = &constant_pat }, .{ .root = &val });

    var rebuilt = try trie.rebuildConstant(testing.allocator, 0);
    defer testing.allocator.free(rebuilt.root);
    const str = try rebuilt.toString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("{ A -> B } X { C -> D, E -> F }", str);
}

const Parser = @import("../Parser.zig");

fn expectRebuildRoundtrip(trie: Trie, index: usize) !void {
    var rebuilt = try trie.rebuildConstant(testing.allocator, index);
    defer testing.allocator.free(rebuilt.root);
    const str = try rebuilt.toString(testing.allocator);
    defer testing.allocator.free(str);

    var parsed = try Parser.parse(testing.allocator, str);
    defer parsed.deinit(testing.allocator);

    // Verify parsed pattern matches the trie at this index
    var bindings = VarBindings{};
    defer bindings.deinit(testing.allocator);
    var match_result = try trie.match(testing.allocator, .{ .lower = index, .upper = trie.length() }, &bindings, parsed);
    defer match_result.deinit(testing.allocator);
    try testing.expect(match_result.value != null);
}

test "rebuildConstant: multiple entries roundtrip" {
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    var constant_pat0 = [_]Node{ .{ .constant = "A" }, .{ .constant = "B" }, .{ .variable = "x" } };
    var constant_pat1 = [_]Node{ .{ .constant = "A" }, .{ .constant = "C" } };
    var constant_pat2 = [_]Node{ .{ .constant = "A" }, .{ .constant = "B" }, .{ .variable = "y" } };
    var val = [_]Node{.{ .constant = "V" }};
    _ = try trie.append(testing.allocator, .{ .root = &constant_pat0 }, .{ .root = &val });
    _ = try trie.append(testing.allocator, .{ .root = &constant_pat1 }, .{ .root = &val });
    _ = try trie.append(testing.allocator, .{ .root = &constant_pat2 }, .{ .root = &val });

    try expectRebuildRoundtrip(trie, 0);
    try expectRebuildRoundtrip(trie, 1);
    try expectRebuildRoundtrip(trie, 2);
}

test "rebuildConstant: nested with list roundtrip" {
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    var list_inner = [_]Node{.{ .variable = "y" }};
    var inner = [_]Node{ .{ .variable = "x" }, .{ .list = .{ .root = &list_inner } } };
    var constant_pat = [_]Node{.{ .pattern = .{ .root = &inner } }};
    var val = [_]Node{.{ .constant = "V" }};
    _ = try trie.append(testing.allocator, .{ .root = &constant_pat }, .{ .root = &val });

    try expectRebuildRoundtrip(trie, 0);
}

test "rebuildConstant: embedded trie roundtrip" {
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    var inner_trie = Trie{};
    defer inner_trie.deinit(testing.allocator);
    var inner_constant0 = [_]Node{.{ .constant = "A" }};
    var inner_val0 = [_]Node{.{ .constant = "B" }};
    var inner_constant1 = [_]Node{ .{ .constant = "C" }, .{ .constant = "D" } };
    var inner_val1 = [_]Node{.{ .constant = "E" }};
    _ = try inner_trie.append(testing.allocator, .{ .root = &inner_constant0 }, .{ .root = &inner_val0 });
    _ = try inner_trie.append(testing.allocator, .{ .root = &inner_constant1 }, .{ .root = &inner_val1 });

    var constant_pat = [_]Node{ .{ .constant = "X" }, .{ .trie = inner_trie }, .{ .constant = "Y" } };
    var val = [_]Node{.{ .constant = "V" }};
    _ = try trie.append(testing.allocator, .{ .root = &constant_pat }, .{ .root = &val });

    try expectRebuildRoundtrip(trie, 0);
}

test "rebuildConstant: multiple nested tries roundtrip" {
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    var inner1 = Trie{};
    defer inner1.deinit(testing.allocator);
    var i1_key = [_]Node{.{ .constant = "A" }};
    var i1_val = [_]Node{.{ .constant = "B" }};
    _ = try inner1.append(testing.allocator, .{ .root = &i1_key }, .{ .root = &i1_val });

    var inner2 = Trie{};
    defer inner2.deinit(testing.allocator);
    var i2_key0 = [_]Node{.{ .constant = "C" }};
    var i2_val0 = [_]Node{.{ .constant = "D" }};
    var i2_key1 = [_]Node{.{ .constant = "E" }};
    var i2_val1 = [_]Node{.{ .constant = "F" }};
    _ = try inner2.append(testing.allocator, .{ .root = &i2_key0 }, .{ .root = &i2_val0 });
    _ = try inner2.append(testing.allocator, .{ .root = &i2_key1 }, .{ .root = &i2_val1 });

    var constant_pat = [_]Node{ .{ .trie = inner1 }, .{ .constant = "X" }, .{ .trie = inner2 } };
    var val = [_]Node{.{ .constant = "V" }};
    _ = try trie.append(testing.allocator, .{ .root = &constant_pat }, .{ .root = &val });

    try expectRebuildRoundtrip(trie, 0);
}

test "rebuildConstant: height preserved" {
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    var constant_pat = [_]Node{ .{ .constant = "A" }, .{ .variable = "x" } };
    var val = [_]Node{.{ .constant = "V" }};
    _ = try trie.append(testing.allocator, .{ .root = &constant_pat }, .{ .root = &val });

    const rebuilt = try trie.rebuildConstant(testing.allocator, 0);
    defer testing.allocator.free(rebuilt.root);
    try testing.expectEqual(@as(usize, 0), rebuilt.height);
}

test "Debug trie structure" {
    var trie = try Parser.parseTrie(testing.allocator, "A, *x --> *x");
    defer trie.deinit(testing.allocator);

    var trie2 = try Parser.parseTrie(testing.allocator, "x, y --> y, x");
    defer trie2.deinit(testing.allocator);
    try testing.expect(trie2.var_branches.items.len >= 1);
}

test "Match: trie size as lower bound never matches" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var trie = try Parser.parseTrie(allocator,
        \\A --> 1
        \\B --> 2
    );
    const query = try Parser.parse(allocator, "A");

    // Sanity check: the query matches when starting from the beginning.
    var lower_bindings = VarBindings{};
    const matched = try trie.match(
        allocator,
        .{ .lower = 0, .upper = trie.length() },
        &lower_bindings,
        query,
    );
    try testing.expect(matched.value != null);

    // Starting at the trie's size, there is no branch at or after the lower
    // bound, so nothing can ever match.
    var bindings = VarBindings{};
    const unmatched = try trie.match(
        allocator,
        .{ .lower = trie.length(), .upper = trie.length() },
        &bindings,
        query,
    );
    try testing.expect(unmatched.value == null);
    try testing.expectEqual(@as(usize, 0), unmatched.len);
}
