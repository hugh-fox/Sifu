const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;
const math = std.math;
const util = @import("../util.zig");
const assert = std.debug.assert;
const panic = util.panic;
const Order = math.Order;
const Wyhash = std.hash.Wyhash;
const array_hash_map = std.array_hash_map;
const AutoContext = std.array_hash_map.AutoContext;
const StringContext = std.array_hash_map.StringContext;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const DoublyLinkedList = std.DoublyLinkedList;
const meta = std.meta;
const ArenaAllocator = std.heap.ArenaAllocator;
const print = util.print;
const first = util.first;
const last = util.last;
const streams = util.streams;
const verbose_errors = @import("build_options").verbose_errors;
const debug_mode = @import("builtin").mode == .Debug;

pub const Tree = @import("tree.zig").Tree;
const Trie = @import("generic_trie").TokenTrie(IndexedValues);

pub const HashMap = Trie.HashMap;
pub const GetOrPutResult = HashMap.GetOrPutResult;

/// A key node and its next term pointer for a trie, where only the
/// length of slice types are stored for keys (instead of pointers).
/// The term/next is a reference to a key/value in the HashMaps,
/// which owns both. This type is isomorphic to a key-value entry in
/// HashMap to form a bijection.
pub const Entry = HashMap.Entry;

/// This maps to branches, but the type is Branch instead of just *Self
/// to retrieve keys if necessary. The Self pointer references another
/// field in this trie, such as `keys`.
const IndexMap = std.AutoArrayHashMapUnmanaged(usize, Entry);

/// ArrayMaps are used as both branches and values need to support
/// efficient iteration, to support recursive matching variables.
const ValueMap = std.AutoArrayHashMapUnmanaged(usize, Tree);

/// Stores any and all values, vars and their indices at each branch in the
/// trie.
pub const IndexedValues = struct {
    /// Tracks the order of entries in the trie and references to next
    /// pointers. An index for an entry is saved at every branch in the trie
    /// for a given key. Branches may or may not contain values in their
    /// ValueMap, for example in `Foo Bar -> 123`, the branch at `Foo` would
    /// have an index to the key `Bar` and a leaf trie containing the
    /// value `123`.
    indices: IndexMap = .{},

    /// Caches a mtrieing of vars to their indices (rules with the same
    /// vars can be repeated arbitrarily) so that they can be efficiently
    /// iterated over.
    vars: HashMap = .{},

    /// Similar to the index map, this stores the values of the trie for the
    /// node at a given index/path.
    values: ValueMap = .{},
};

/// Maps terms to the next trie, if there is one. These form the branches of the
/// trie for a specific level of nesting. Each Key is in the map is unique, but
/// they can be repeated in separate indices. Therefore this stores its own next
/// Self pointer, and the indices for each key.
///
/// Keys must be efficiently iterable, but that is provided by the index map
/// anyways so an array map isn't needed for the trie's hashmap.
///
/// The tries that for types that are shared (variables and nested tree/tries)
/// are encoded by a layer of pointer indirection in their respective fields
/// here.
pub const SifuTrie = struct {
    pub const Self = @This();
    pub const Node = Tree.Node;

    /// The results of matching a trie exactly (vars are matched literally
    /// instead of by building up a tree of their possible values)
    pub const ExactPrefix = struct {
        len: usize,
        index: ?usize, // Null if no prefix
        leaf: Self,
    };

    /// Asserts that the index exists.
    pub fn getIndex(self: Self, index: usize) Tree {
        return self.getIndexOrNull(index) orelse
            panic("Index {} doesn't exist\n", .{index});
    }
    /// Returns null if the index doesn't exist in the trie.
    pub fn getIndexOrNull(self: Self, index: usize) ?Tree {
        var current = self;
        while (current.indices.get(index)) |next| {
            current = next.*;
        }
        return current.values.get(index);
    }

    /// Rebuilds the key for a given index using an allocator for the
    /// arrays necessary to support the tree structure, but pointers to the
    /// underlying keys.
    pub fn rebuildKey(
        self: Self,
        allocator: Allocator,
        index: usize,
    ) !Tree {
        _ = index; // autofix
        _ = allocator; // autofix
        _ = self; // autofix
        @panic("unimplemented");
    }

    /// Deep copy a trie by value, as well as Keys and Variables.
    /// Use deinit to free.
    // TODO: optimize by allocating top level maps of same size and then
    // use putAssumeCapacity
    pub fn copy(self: Self, allocator: Allocator) Allocator.Error!Self {
        var result = Self{};
        var map_iter = self.keys.iterator();
        while (map_iter.next()) |entry|
            try result.keys.putNoClobber(
                allocator,
                entry.key_ptr.*,
                try entry.value_ptr.*.copy(allocator),
            );

        // Deep copy the indices map
        var index_iter = self.indices.iterator();
        while (index_iter.next()) |index_entry| {
            const index = index_entry.key_ptr.*;
            const entry = index_entry.value_ptr.*;
            // Insert a borrowed pointer to the new key copy.
            try result.indices
                .putNoClobber(allocator, index, entry);
        }

        @panic("todo: copy all fields");
        // return result;
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

    /// The opposite of `copy`.
    /// TODO: check frees properly for owned and borrowed managers
    pub fn deinit(self: *Self, allocator: Allocator) void {
        defer self.keys.deinit(allocator);
        var iter = self.keys.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit(allocator);
        }
        defer self.indices.deinit(allocator);
        defer self.values.deinit(allocator);
        for (self.values.values()) |*value|
            value.destroy(allocator);
    }

    pub fn hash(self: Self) u32 {
        var hasher = Wyhash.init(0);
        self.hasherUpdate(&hasher);
        return @truncate(hasher.final());
    }

    pub fn hasherUpdate(self: Self, hasher: anytype) void {
        var map_iter = self.keys.iterator();
        while (map_iter.next()) |entry| {
            entry.key_ptr.*.hasherUpdate(hasher);
            entry.value_ptr.*.hasherUpdate(hasher);
        }
        var index_iter = self.indices.iterator();
        // TODO: recurse
        while (index_iter.next()) |*entry| {
            hasher.update(mem.asBytes(entry));
        }
    }

    fn branchEql(comptime E: type, b1: E, b2: E) bool {
        return b1.key_ptr.eql(b2.key_ptr.*) and
            b1.value_ptr.eql(b2.value_ptr.*);
    }

    /// Tries are equal if they have the same literals, sub-arrays and
    /// sub-tries and if their debruijn variables are equal. The tries
    /// are assumed to be in debruijn form already.
    pub fn eql(self: Self, other: Self) bool {
        if (self.keys.count() != other.keys.count() or
            self.indices.entries.len != other.indices.entries.len or
            self.values.entries.len != other.values.entries.len)
            return false;
        var map_iter = self.keys.iterator();
        var other_map_iter = other.keys.iterator();
        while (map_iter.next()) |entry| {
            const other_entry = other_map_iter.next() orelse
                return false;
            if (!(entry.key_ptr.*.eql(other_entry.key_ptr.*)) or
                entry.value_ptr != other_entry.value_ptr)
                return false;
        }
        var index_iter = self.indices.iterator();
        var other_index_iter = other.indices.iterator();
        while (index_iter.next()) |entry| {
            const other_entry = other_index_iter.next() orelse
                return false;
            const val = entry.value_ptr.*;
            const other_index = other_entry.value_ptr.*;
            if (entry.key_ptr.* != other_entry.key_ptr.* or
                !val.term.eql(other_index.term.*))
                return false;
        }
        return true;
    }

    pub fn create(allocator: Allocator) !*Self {
        const result = try allocator.create(Self);
        result.* = Self{};
        return result;
    }

    pub const VarNext = struct {
        variable: []const u8,
        index: usize,
        next: *Self,
    };

    /// Follows `trie` for each trie matching structure as well as value.
    /// Does not require allocation because variable branches are not
    /// explored, but rather followed. This is an exact match, so variables
    /// only match variables and a subtrie will be returned. This pointer
    /// is valid unless reassigned in `pat`.
    /// If trie is empty the same `pat` pointer will be returned. If
    /// the entire `tree` is a prefix, a pointer to the last pat will be
    /// returned instead of null.
    /// `trie` isn't modified.
    pub fn getTerm(
        trie: Self,
        node: Node,
    ) ?Self {
        return switch (node) {
            .key => |key| trie.keys.get(key),
            .variable => |variable| trie.vars.get(variable),
            .tree => |sub_tree| blk: {
                var current = trie.keys.get("(") orelse
                    break :blk null;
                for (sub_tree.root) |sub_node|
                    current = current.getTerm(sub_node) orelse
                        break :blk null;
                break :blk current.keys.get(")");
            },
            .arrow, .match, .list => panic("unimplemented", .{}),
            else => panic("unimplemented", .{}),
        };
    }

    /// Return a pointer to the last trie in `pat` after the longest path
    /// following `tree`
    pub fn getPrefix(
        trie: Self,
        tree: Tree,
    ) ExactPrefix {
        var current = trie;
        const index: usize = undefined; // TODO
        // Follow the longest branch that exists
        const prefix_len = for (tree.root, 0..) |trie, i| {
            current = current.getTerm(trie) orelse
                break i;
        } else tree.root.len;

        return .{ .len = prefix_len, .index = index, .leaf = current };
    }

    pub fn get(
        trie: Self,
        tree: Tree,
    ) ?Self {
        const prefix = trie.getPrefix(tree);
        return if (prefix.len == tree.root.len)
            prefix.leaf
        else
            null;
    }

    pub fn append(
        trie: *Self,
        allocator: Allocator,
        key: Tree,
        optional_value: ?Tree,
    ) Allocator.Error!*Self {
        // The length of values will be the next entry index after insertion
        const len = trie.count();
        var branch = trie;
        branch = try branch.ensurePath(allocator, len, key);
        // If there isn't a value, use the key as the value instead
        const value = optional_value orelse
            try key.copy(allocator);
        try branch.values.putNoClobber(allocator, len, value);
        return branch;
    }

    /// Creates the necessary branches and key entries in the trie for
    /// tree, and returns a pointer to the branch at the end of the path.
    /// While similar to a hashmap's getOrPut function, ensurePath always
    /// adds a new index, asserting that it did not already exist. There is
    /// no getOrPut equivalent for tries because they are append-only.
    ///
    /// The index must not already be in the trie.
    /// Tree are copied.
    /// Returns a pointer to the updated trie node. If the given tree is
    /// empty (0 len), the returned key and index are undefined.
    fn ensurePath(
        trie: *Self,
        allocator: Allocator,
        index: usize,
        tree: Tree,
    ) !*Self {
        var current = trie;
        for (tree.root) |trie| {
            const entry = try current.ensurePathTerm(allocator, index, trie);
            current = entry.value_ptr;
        }
        return current;
    }

    fn getOrPutKey(
        trie: *Self,
        allocator: Allocator,
        index: usize,
        key: []const u8,
    ) !Entry {
        const entry = try trie.keys
            .getOrPutValue(allocator, key, Self{});
        try trie.indices.putNoClobber(allocator, index, entry);
        return entry;
    }

    fn getOrPutVar(
        trie: *Self,
        allocator: Allocator,
        index: usize,
        variable: []const u8,
    ) !Entry {
        const entry = try trie.vars
            .getOrPutValue(allocator, variable, Self{});
        try trie.indices.putNoClobber(allocator, index, entry);
        return entry;
    }

    /// Follows or creates a path as necessary in the trie and
    /// indices. Only adds branches, not values.
    fn ensurePathTerm(
        trie: *Self,
        allocator: Allocator,
        index: usize,
        term: Node,
    ) Allocator.Error!Entry {
        return switch (term) {
            .key => |key| try trie.getOrPutKey(allocator, index, key),
            .variable,
            .var_tree,
            => |variable| try trie.getOrPutVar(allocator, index, variable),
            .trie => |sub_pat| {
                const entry = try trie.getOrPutKey(allocator, index, "{");
                _ = entry;
                _ = sub_pat;
                @panic("unimplemented\n");
            },
            // Pattern trie's values will always be tries too, which will
            // map nested tree to the next trie on the current level.
            // The resulting encoding is counter-intuitive when printed
            // because each level of nesting must be a branch to enable
            // trie matching.
            inline else => |tree| blk: {
                var entry = try trie.getOrPutKey(allocator, index, "(");
                // All op types are encoded the same way after their top
                // level hash. These don't need special treatment because
                // their structure is simple, and their operator unique.
                const next = try entry.value_ptr
                    .ensurePath(allocator, index, tree);
                entry = try next.getOrPutKey(allocator, index, ")");
                break :blk entry;
            },
        };
    }

    /// Add a node to the trie by following `keys`, wrpatterning them into an
    /// Pattern of Nodes.
    /// Allocations:
    /// - The path followed by tree is allocated and copied recursively
    /// - The node, if given, is allocated and copied recursively
    /// Freeing should be done with `destroy` or `deinit`, depending on
    /// how `self` was allocated
    pub fn putKeys(
        self: *Self,
        allocator: Allocator,
        keys: []const []const u8,
        optional_value: ?Tree,
    ) Allocator.Error!*Self {
        var tree = allocator.alloc([]const u8, keys.len);
        defer tree.free(allocator);
        for (tree, keys) |*trie, key|
            trie.* = Node.ofKey(key);

        return self.put(
            allocator,
            Node.ofTree(tree),
            try optional_value.clone(allocator),
        );
    }

    /// A partial or complete match of a given tree against a trie.
    const Match = struct {
        /// Keeps track of which vars and var_tree are bound to what part of an
        /// expression given during matching.
        pub const VarBindings = std.StringHashMapUnmanaged(Tree);

        len: usize = 0, // Checks if complete or partial match
        index: usize = 0, // The bounds subsequent matches should be within
        bindings: VarBindings = .{}, // Bound variables
        // Matching branches that can be backtracked to. Indices are tracked
        // because they are always matched in ascending order, but not
        // necessarily sequentially.
        branches: std.AutoHashMapUnmanaged(Node, Branch) = .{},

        /// The second half of an evaluation step. Rewrites all variable
        /// captures into the matched expression. Copies any variables in node
        /// if they are keys in bindings with their values. If there are no
        /// matches in bindings, this functions is equivalent to copy. Result
        /// should be freed with deinit.
        pub fn rewrite(
            match_state: Match,
            allocator: Allocator,
            tree: Tree,
        ) Allocator.Error!Tree {
            var result = ArrayListUnmanaged(Node){};
            for (tree.root) |node| switch (node) {
                .key => |key| try result.append(allocator, Node.ofKey(key)),
                .variable => |variable| {
                    print("Var get: ", .{});
                    if (match_state.bindings.get(variable)) |var_node|
                        var_node.write(streams.err) catch unreachable
                    else
                        print("null", .{});
                    print("\n", .{});
                    try result.append(
                        allocator,
                        try (match_state.bindings.get(variable) orelse
                            node).copy(allocator),
                    );
                },
                .var_tree => |var_tree| {
                    print("Var tree get: ", .{});
                    if (match_state.bindings.get(var_tree)) |var_node|
                        var_node.write(streams.err) catch unreachable
                    else
                        print("null", .{});
                    print("\n", .{});
                    if (match_state.bindings.get(var_tree)) |tree_node| {
                        for (tree_node.tree.root) |trie|
                            try result.append(
                                allocator,
                                try trie.copy(allocator),
                            );
                    } else try result.append(allocator, node);
                },
                inline .tree, .arrow, .match, .list, .infix => |nested, tag| {
                    try result.append(allocator, @unionInit(
                        Node,
                        @tagName(tag),
                        try match_state.rewrite(allocator, nested),
                    ));
                },
                // .trie => |sub_pat| {
                //     _ = sub_pat;
                // },
                else => panic("unimplemented", .{}),
            };
            return Tree{
                .root = try result.toOwnedSlice(allocator),
                .height = tree.height,
            };
        }

        /// Node entries are just references, so they aren't freed by this
        /// function.
        pub fn deinit(self: *Match, allocator: Allocator) void {
            defer self.bindings.deinit(allocator);
            defer self.branches.deinit(allocator);
        }
    };

    /// The resulting trie and match index (if any) from a partial,
    /// successful matching (otherwise null is returned from `match`),
    /// therefore `trie` is always a child of the root. This type is
    /// similar to IndexMap.Entry.
    const Branch = struct {
        trie: Self,
        index: usize, // where this term matched in the node map
    };

    /// The first half of evaluation. The variables in the node match
    /// anything in the trie, and vars in the trie match anything in
    /// the expression. Includes partial prefixes (ones that don't match all
    /// tree). This function returns any trie branches, even if their
    /// value is null, unlike `match`. The position defines the index where
    /// allowable matches begin. As a trie is matched, a hashmap for vars
    /// is populated with each var's bound variable. These can the be used
    /// by the caller for rewriting.
    /// - Any node matches a var trie including a var (the var node is
    ///   then stored in the var map like any other node)
    /// - A var node doesn't match a non-var trie (var matching is one
    ///   way)
    /// - A literal node that matches a trie of both literals and vars
    /// matches the literal part, not the var
    /// Returns a nullable struct describing a successful match containing:
    /// - the value for that match in the trie
    /// - the minimum index a subsequent match should use, which is one
    /// greater than the previous (except for structural recursion).
    /// - null if no match
    /// Caller owns the slice.
    ///
    // TODO: move bindings from params to result
    // TODO: match vars with first available index and increment it
    // TODO: prioritize indices order over exact matching when possible
    fn branchTerm(
        self: Self,
        allocator: Allocator,
        match_state: *Match,
        node: Node,
    ) Allocator.Error!?Self {
        print("Branching `", .{});
        node.writeSExp(streams.err, null) catch unreachable;
        print("`, ", .{});
        var current = self;
        var index, const len, var bindings, const branches = .{
            match_state.index,
            match_state.len,
            match_state.bindings,
            match_state.branches,
        };
        switch (node) {
            .key => |key| if (self.keys.getEntry(key)) |entry| {
                current = entry.value_ptr.*;
                print("exactly: {s}\n", .{node.key});

                // Check that in the branch matched, there is a valid index
                // TODO: make O(1) by caching the internal index to skip
                // previously matched indices
                // TODO: Check vars if this fails, and prioritize index
                // ordering over exact literal matches
                if (current.indices.get(index)) |branch| {
                    _ = Branch{
                        .trie = branch.next.*,
                        .index = index,
                    };
                } else if (current.values.contains(index)) {
                    _ = Branch{
                        .trie = current,
                        .index = index,
                    };
                } else for (current.indices.keys()) |next_index| {
                    if (index > index) {
                        index = next_index;
                        break;
                    }
                } else {
                    print(
                        \\Highest index of {} is smaller than current
                        \\ index {}, not matching.
                        \\
                    ,
                        .{ index, index },
                    );
                }
                print(" at index: {}\n", .{index});
            },
            .variable, .var_tree => @panic("unimplemented"),
            .trie => @panic("unimplemented"), // |trie| {},
            inline else => |sub_tree, tag| {
                _ = tag; // autofix
                _ = sub_tree; // autofix
                // Check Var as Alternative here, but this probably can't be
                // a recursive call without a stack overflow
                print("Branching subtree\n", .{});
                // var next = self.keys.get(
                //     @unionInit(DetachedNode, @tagName(tag), {}),
                // ) orelse {
                //     _ = null;
                // };
                // var matches =
                //     try next.matchAll(allocator, match_state, sub_tree) orelse
                //     {
                //     _ = null;
                // };
                // while (matches.values.next()) |entry| {
                //     // Choose the next available index
                //     if (entry.key_ptr.* >= match_state.index) {
                //         _ = Branch{
                //             .index = entry.key_ptr.*,
                //             .trie = entry.value_ptr.*.trie,
                //         };
                //         break;
                //     }
                // }
            },
        }
        if (self.var_cache.count() > 0) {
            // index += 1; // TODO use as limit
            // result.index = var_next.index;
            // TODO: check correct index for next var
            const var_next = self.var_cache.entries.get(0);
            print(
                "as var `{s}` with index {}\n",
                .{ var_next.key, var_next.value },
            );
            // print(" at index: {?}\n", .{result.index});
            const var_result = try bindings
                .getOrPut(allocator, var_next.key);
            // If a previous var was bound, check that the
            // current key matches it
            if (var_result.found_existing) {
                if (var_result.value_ptr.*.eql(node)) {
                    print("found equal existing var match\n", .{});
                } else {
                    print("found existing non-equal var matching\n", .{});
                }
            } else {
                print("New Var: {s}\n", .{var_result.key_ptr.*});
                var_result.value_ptr.* = node;
            }
            @panic("unimplemented");
            // break :blk BranchResult{ .trie = var_next.value };
        }
        return .{ current, Match{
            .index = index,
            .len = len,
            .bindings = bindings,
            .branches = branches,
        } };
    }

    /// Same as match, but with matchTerm's signature. Returns a complete
    /// match of all tree or else null. For partial matches, no new vars
    /// are put into the bindings, and null is returned.
    /// Caller owns.
    pub fn matchAll(
        self: Self,
        allocator: Allocator,
        match_state: *Match,
        tree: Tree,
    ) Allocator.Error!?Match {
        // TODO: restart if match fails partway
        const prev_len = match_state.bindings.size;
        _ = prev_len; // autofix
        var current = self;
        for (tree.root) |trie| {
            if (try current
                .branchTerm(allocator, match_state, trie)) |next_state|
            {
                current = next_state;
                if (match_state.index < current.count()) {
                    match_state.len += 1;
                } else break;
            }
        }
        print("Match All\n", .{});
        // print("Result and Query len equal: {}\n", .{result.len == tree.len});
        // print("Result value null: {}\n", .{result.value == null});
        return if (match_state.len == tree.root.len)
            match_state // TODO: maybe return values here?
        else
            null;
    }

    /// Follow `tree` in `self` until no matches. Then returns the furthest
    /// trie node and its corresponding number of matched tree that
    /// was in the trie. Starts matching at [index, ..), in the
    /// longest path otherwise any index for a shorter path.
    /// Caller owns and should free the result's value and bindings with
    /// Match.deinit.
    /// If nothing matches, then an empty, default Match is returned.
    pub fn match(
        self: Self,
        allocator: Allocator,
        tree: Tree,
    ) Allocator.Error!Match {
        var match_state = Match{};
        _ = try self.matchAll(allocator, &match_state, tree);

        return match_state;
    }

    /// Performs a single full match and if possible a rewrite.
    /// Caller owns and should free with deinit.
    // TODO: untangle the mess of how to free unused strings through
    // mutliple rewrite steps (deep copying)
    pub fn evaluateStep(
        self: Self,
        allocator: Allocator,
        index: usize,
        tree: Tree,
    ) Allocator.Error!Tree {
        _ = index;
        const next_match = try self.match(allocator, tree);
        defer next_match.deinit();
        while (next_match.values.next()) |entry| {
            const next_index, const value =
                .{ entry.key_ptr.*, entry.value_ptr.* };
            print(
                "Matched {} of {} tree at index {}: ",
                .{ next_match.len, tree.root.len, next_index },
            );
            value.write(streams.err) catch unreachable;
            print("\n", .{});
            return self.rewrite(allocator, next_match.bindings, value.tree);
        } else {
            print(
                "No match, after {} nodes followed\n",
                .{next_match.len},
            );
            return .{};
        }
    }

    /// Given a trie and a query to match against it, this function
    /// continously matches until no matches are found, or a match repeats.
    /// Match result cases:
    /// - a trie of lower ordinal: continue
    /// - the same trie: continue unless tries are equivalent
    ///   expressions (fixed point)
    /// - a trie of higher ordinal: break
    // TODO: fix ops as keys not being matched
    // TODO: refactor with evaluateStep
    pub fn evaluate(
        self: *Self,
        allocator: Allocator,
        tree: Tree,
    ) Allocator.Error!Tree {
        var index: usize = 0;
        var result = ArrayListUnmanaged(Node){};
        while (index < tree.len) {
            print("Matching from index: {}\n", .{index});
            const query = tree[index..];
            const matched = try self.match(allocator, query);
            if (matched.len == 0) {
                print("No match, skipping index {}.\n", .{index});
                try result.append(
                    allocator,
                    // Evaluate nested tree that failed to match
                    // TODO: replace recursion with a continue
                    switch (tree[index]) {
                        inline .tree, .match, .arrow, .list => |slice, tag|
                        // Recursively eval but preserve node type
                        @unionInit(
                            Node,
                            @tagName(tag),
                            try self.evaluate(allocator, slice),
                        ),
                        else => try tree[index].copy(allocator),
                    },
                );
                index += 1;
                continue;
            }
            print("vars in map: {}\n", .{matched.bindings.entries.len});
            if (matched.value) |next| {
                // Prevent infinite recursion at this index. Recursion
                // through other indices will be terminated by match index
                // shrinking.
                if (query.len == next.tree.len)
                    for (query, next.tree) |trie, next_trie| {
                        // check if the same trie's shape could be matched
                        // TODO: use a trie match function here instead of eql
                        if (!trie.asEmpty().eql(next_trie))
                            break;
                    } else break; // Don't evaluate the same trie
                print("Eval matched {s}: ", .{@tagName(next.*)});
                next.write(streams.err) catch unreachable;
                streams.err.writeByte('\n') catch unreachable;
                const rewritten =
                    try self.rewrite(allocator, matched.bindings, next.tree);
                defer Node.ofTree(rewritten).deinit(allocator);
                const sub_eval = try self.evaluate(allocator, rewritten);
                defer allocator.free(sub_eval);
                try result.appendSlice(allocator, sub_eval);
            } else {
                try result.appendSlice(allocator, query);
                print("Match, but no value\n", .{});
            }
            index += matched.len;
        }
        print("Eval: ", .{});
        for (result.items) |trie| {
            print("{s} ", .{@tagName(trie)});
            trieiteSExp(streams.err, 0) catch unreachable;
            streams.err.writeByte(' ') catch unreachable;
        }
        streams.err.writeByte('\n') catch unreachable;
        return result.toOwnedSlice(allocator);
    }

    pub fn count(self: Self) usize {
        return self.indices.count() + self.values.count();
    }

    /// Pretty print a trie on multiple lines
    pub fn pretty(self: Self, writer: anytype) !void {
        try self.writeIndent(writer, 0);
    }

    /// Print a trie without newlines
    pub fn write(self: Self, writer: anytype) !void {
        try self.writeIndent(writer, null);
    }

    /// Writes a single entry in the trie canonically. Index must be
    /// valid.
    pub fn writeIndex(self: Self, writer: anytype, index: usize) !void {
        var current = self;
        if (comptime debug_mode)
            try writer.print("{} | ", .{index});
        while (current.indices.get(index)) |branch| {
            try writer.writeAll(branch.key_ptr.*);
            try writer.writeByte(' ');
            current = branch.value_ptr.*;
        }

        if (current.values.get(index)) |value| {
            try writer.writeAll("-> ");
            try value.writeIndent(writer, null);
        }
    }

    /// Print a trie in order based on indices.
    pub fn writeCanonical(self: Self, writer: anytype) !void {
        for (0..self.count()) |index| {
            try self.writeIndex(writer, index);
            try writer.writeByte('\n');
        }
    }

    pub const indent_increment = 2;
    pub fn writeIndent(
        self: Self,
        writer: anytype,
        optional_indent: ?usize,
    ) @TypeOf(writer).Error!void {
        try writer.writeAll("❬");
        for (self.values.entries.items(.value)) |value| {
            try value.writeIndent(writer, null);
            try writer.writeAll(", ");
        }
        try writer.writeAll("❭ ");
        const optional_indent_inc = if (optional_indent) |indent|
            indent + indent_increment
        else
            null;
        try writer.writeByte('{');
        try writer.writeAll(if (optional_indent) |_| "\n" else "");
        try writeEntries(self.keys, writer, optional_indent_inc);
        for (0..optional_indent orelse 0) |_|
            try writer.writeByte(' ');
        try writer.writeByte('}');
        try writer.writeAll(if (optional_indent) |_| "\n" else "");
    }

    fn writeEntries(
        map: anytype,
        writer: anytype,
        optional_indent: ?usize,
    ) @TypeOf(writer).Error!void {
        var iter = map.iterator();
        while (iter.next()) |entry| {
            for (0..optional_indent orelse 1) |_|
                try writer.writeByte(' ');

            const node = entry.key_ptr.*;
            try util.genericWrite(node, writer);
            try writer.writeAll(" -> ");
            try entry.value_ptr.*.writeIndent(writer, optional_indent);
            try writer.writeAll(if (optional_indent) |_| "" else ", ");
        }
    }
};

const testing = std.testing;

test "Trie: eql" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p1 = Trie{};
    var p2 = Trie{};

    var value = Trie.Node{ .key = "123" };
    const value2 = Trie.Node{ .key = "123" };
    // Reverse order because tries are values, not references
    try p2.map.put(allocator, "Bb", Trie{ .value = &value });
    try p1.map.put(allocator, "Aa", p2);

    var p_put = Trie{};
    _ = try p_put.putTree(allocator, &.{
        Trie.Node{ .key = "Aa" },
        Trie.Node{ .key = "Bb" },
    }, value2);
    try p1.write(streams.err);
    try streams.err.writeByte('\n');
    try p_put.write(streams.err);
    try streams.err.writeByte('\n');
    try testing.expect(p1.eql(p_put));
}

test "put single lit" {}

test "put multiple lits" {
    // Multiple keys
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    _ = try trie.putTree(
        testing.allocator,
        &.{ Trie.Node{ .key = 1 }, Trie.Node{ .key = 2 }, Trie.Node{ .key = 3 } },
        null,
    );
    try testing.expect(trie.keys.contains(1));
}

test "Compile: nested" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    var trie = try Trie.ofValue(al, 123);
    const prefix = trie.getPrefix(&.{});
    _ = prefix;
    // Test nested
    // const Pat2 = Pat{};
    // Pat2.pat_map.put( &pat, 456 };
    // _ = Pat2;
}

test "Memory: simple" {
    var trie = try Trie.ofValue(testing.allocator, 123);
    defer trie.deinit(testing.allocator);
}

test "Memory: nesting" {
    var nested_trie = try Trie.create(testing.allocator);
    defer nested_trie.destroy(testing.allocator);
    nested_trie.getOrPut(testing.allocator, Trie{}, "subpat's value");

    _ = try nested_trie.putKeys(
        testing.allocator,
        &.{ "cherry", "blossom", "tree" },
        Trie.Node.ofKey("beautiful"),
    );
}

test "Memory: idempotency" {
    var trie = Trie{};
    defer trie.deinit(testing.allocator);
}

test "Memory: nested trie" {
    var trie = try Trie.create(testing.allocator);
    defer trie.destroy(testing.allocator);
    var value_trie = try Trie.ofValue(testing.allocator, "Value");

    // No need to free this, because key pointers are destroyed
    var nested_trie = try Trie.ofValue(testing.allocator, "Asdf");

    try trie.keys.put(testing.allocator, Trie.Node{ .trie = &nested_trie }, value_trie);

    _ = try value_trie.putKeys(
        testing.allocator,
        &.{ "cherry", "blossom", "tree" },
        null,
    );
}

test "Behavior: var hashing" {
    var pat = Trie{};
    defer pat.deinit(testing.allocator);
    try pat.vars.put(
        testing.allocator,
        "x",
        Trie.Tree{ .root = .{ .lit = "1" } },
    );
    try pat.vars.put(
        testing.allocator,
        "y",
        Trie.Tree{ .root = .{ .lit = "2" } },
    );
    try pat.pretty(streams.err);
    if (pat.get("")) |got| {
        print("Got: ", .{});
        try got.write(streams.err);
        print("\n", .{});
    } else print("Got null\n", .{});
    if (pat.get("x")) |got| {
        print("Got: ", .{});
        try got.write(streams.err);
        print("\n", .{});
    } else print("Got null\n", .{});
}

// TODO: test for multiple tries with different variables, and with multiple
// equal variables
// TODO: test for tries with equal keys but different structure, like A (B)
// and (A B)
