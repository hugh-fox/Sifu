const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList; // Update import
const mem = std.mem;
const math = std.math;
const compare = math.compare;
const util = @import("util.zig");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Order = math.Order;
const Wyhash = std.hash.Wyhash;
const array_hash_map = std.array_hash_map;
const AutoContext = std.array_hash_map.AutoContext;
const StringContext = std.array_hash_map.StringContext;
const ArenaAllocator = std.heap.ArenaAllocator;
const debug = std.log.debug;
const verbose_errors = @import("build_options").verbose_errors;
const debug_mode = @import("builtin").mode == .Debug;
const sort = std.sort;
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;

pub const HashMap = std.StringHashMapUnmanaged(Trie);
pub const GetOrPutResult = HashMap.GetOrPutResult;

/// Nodes form the keys and values of a pattern type (its recursive structure
/// forces both to be the same type). In Sifu, it is also the structure given
/// to a source code entry (a `Node(Token)`). It encodes sequences, nesting,
/// and patterns. It could also be a simple type for optimization purposes. Sifu
/// maps the syntax described below to this data structure, but that syntax is
/// otherwise irrelevant. Any infix operator that isn't a builtin (match, arrow
/// or list) is parsed into a pattern. These are ordered in their precedence, which
/// is used during parsing.
/// A pattern (a list of nodes) Node.
pub const Node = union(enum) {
    /// A unique constant, literal values. Uniqueness when in a pattern
    /// arises from NodeMap referencing the same value multiple times
    /// (based on Literal.eql).
    key: []const u8,
    /// A Var matches and stores a locally-unique key. During rewriting,
    /// whenever the key is encountered again, it is rewritten to this
    /// pattern's value. A Var pattern matches anything, including nested
    /// patterns. It only makes sense to match anything after trying to
    /// match something specific, so Vars always successfully match (if
    /// there is a Var) after a Key or Subpat match fails.
    variable: []const u8,
    /// Variables that match patterns as a term. These are only strictly
    /// needed for matching patterns with ops, where the nested patterns
    /// is implicit.
    var_pattern: []const u8,
    /// Spaces separated juxtaposition, or lists/parens for nested patterns.
    /// Infix operators add their rhs as a nested patterns after themselves.
    pattern: Pattern,
    /// The list following a non-builtin operator.
    infix: Pattern,
    /// A postfix encoded match pattern, i.e. `x : Int -> x * 2` where
    /// some node (`x`) must match some subpattern (`Int`) in order for
    /// the rest of the match to continue. Like infixes, the patterns to
    /// the left form their own subpatterns, stored here, but the `:` token
    /// is elided.
    match: Pattern,
    /// A postfix encoded arrow expression denoting a rewrite, i.e. `A B
    /// C -> 123`. This includes "long" versions of ops, which have same
    /// semantics, but only play a in part parsing/printing. Parsing
    /// shouldn't concern this abstract data structure, and there is
    /// enough information preserved such that during printing, the
    /// correct precedence operator can be recreated.
    arrow: Pattern,
    /// A single element in comma separated list, with the comma elided.
    /// Lists are operators that are recognized as separators for
    /// patterns.
    list: Pattern,
    /// An expression in braces.
    trie: Trie,

    /// Performs a deep copy, resulting in a Node the same size as the
    /// original. Does not deep copy keys or vars.
    /// The copy should be freed with `deinit`.
    pub fn copy(
        self: Node,
        allocator: Allocator,
    ) Allocator.Error!Node {
        return switch (self) {
            inline .key, .variable, .var_pattern => self,
            .pattern => |p| Node.ofPattern(try p.copy(allocator)),
            inline else => |pattern, tag| @unionInit(
                Node,
                @tagName(tag),
                try pattern.copy(allocator),
            ),
        };
    }

    // Same as copy but allocates the root
    pub fn clone(self: Node, allocator: Allocator) !*Node {
        const self_copy = try allocator.create(Node);
        self_copy.* = try self.copy(allocator);
        return self_copy;
    }

    pub fn destroy(self: *Node, allocator: Allocator) void {
        self.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn deinit(self: Node, allocator: Allocator) void {
        switch (self) {
            .key, .variable, .var_pattern => {},
            .trie => |*trie| @constCast(trie).deinit(allocator),
            inline else => |*pattern| @constCast(pattern).deinit(allocator),
        }
    }

    pub const hash = util.hashFromHasherUpdate(Node);

    pub fn hasherUpdate(self: Node, hasher: anytype) void {
        hasher.update(&mem.toBytes(@intFromEnum(self)));
        switch (self) {
            // Variables are always the same hash in patterns (in
            // varmaps they need unique hashes)
            // TODO: differentiate between repeated and unique vars
            .key, .variable, .var_pattern => |slice| hasher.update(
                &mem.toBytes(slice),
            ),
            .pattern => |pattern| pattern.hasherUpdate(hasher),
            inline else => |pattern, tag| {
                switch (tag) {
                    .arrow, .long_arrow => hasher.update("->"),
                    .match, .long_match => hasher.update(":"),
                    .list => hasher.update(","),
                    else => {},
                }
                pattern.hasherUpdate(hasher);
            },
        }
    }

    pub fn eql(node: Node, other: Node) bool {
        return if (@intFromEnum(node) != @intFromEnum(other))
            false
        else switch (node) {
            .key => |key| mem.eql(u8, key, other.key),
            // TODO: make exact comparisons work with single place
            // pattern in hashmaps
            // .variable => |v| Ctx.eql(undefined, v, other.variable, undefined),
            .variable => other == .variable,
            .var_pattern => other == .var_pattern,
            .trie => |trie| trie.eql(other.trie),
            inline else => |pattern, tag| pattern
                .eql(@field(other, @tagName(tag))),
        };
    }
    pub fn ofKey(key: []const u8) Node {
        return .{ .key = key };
    }
    pub fn ofVar(variable: []const u8) Node {
        return .{ .variable = variable };
    }
    pub fn ofVarPattern(var_pattern: []const u8) Node {
        return .{ .var_pattern = var_pattern };
    }

    pub fn ofPattern(pattern: Pattern) Node {
        return .{ .pattern = pattern };
    }

    pub fn createKey(
        allocator: Allocator,
        key: []const u8,
    ) Allocator.Error!*Node {
        const node = try allocator.create(Node);
        node.* = Node{ .key = key };
        return node;
    }

    /// Lifetime of `pattern` must be longer than this Node.
    pub fn createPattern(
        allocator: Allocator,
        pattern: Pattern,
    ) Allocator.Error!*Node {
        const node = try allocator.create(Node);
        node.* = Node{ .pattern = pattern };
        return node;
    }

    pub fn isOp(self: Node) bool {
        return switch (self) {
            .key, .variable, .pattern, .var_pattern, .trie => false,
            else => true,
        };
    }

    /// Compares by value, not by len, pos, or pointers.
    pub fn order(self: Node, other: Node) order {
        const ord = math.order(@intFromEnum(self), @intFromEnum(other));
        return if (ord == .eq)
            switch (self) {
                .pattern => |pattern| util.sliceOrder(
                    pattern,
                    other.pattern,
                    Node.order,
                ),
                .variable => |v| mem.order(u8, v, other.variable),
                .key => |key| key.order(other.key),
                .pattern => |pattern| pattern.order(other.pattern),
            }
        else
            ord;
    }

    pub fn formatSExp(
        self: Node,
        allocator: Allocator,
    ) ![]const u8 {
        var buff: std.ArrayList(u8) = try .initCapacity(allocator, 1024);
        defer buff.deinit(allocator);
        var writer = Io.Writer.fromArrayList(&buff);
        // TODO: figure out why this is empty string
        try self.writeSExp(&writer, null);
        // std.log.debug("Formatted s-exp: {}", .{buff.items.len});
        return buff.toOwnedSlice(allocator);
    }

    pub fn writeSExp(
        self: *Node,
        writer: *Writer,
        optional_indent: ?usize,
    ) !void {
        // std.log.debug("WriteSExp {s}", .{
        //     switch (self) {
        //         .key, .variable, .var_pattern => |ident| ident,
        //         else => |tag| @tagName(tag),
        //     },
        // });
        for (0..optional_indent orelse 0) |_|
            try writer.writeByte(' ');
        switch (self.*) {
            .key => |key| _ = try writer.writeAll(key),
            .variable, .var_pattern => |variable| {
                try writer.writeAll(variable);
            },
            .trie => |*trie| try trie.writeIndent(
                writer,
                optional_indent,
            ),
            .pattern => |pattern| {
                // std.log.debug("writing pattern len {}: (", .{pattern.root.len});
                try writer.writeByte('(');
                // Ignore top level parens
                try pattern.writeIndent(writer, optional_indent);
                // std.log.debug(")", .{});
                try writer.writeByte(')');
            },
            inline else => |pattern, tag| {
                // if (pattern.root.len > 0)
                //     for (pattern.root[0 .. pattern.root.len - 1]) |node| {
                //         try node.writeSExp(writer, optional_indent);
                //     };
                switch (tag) {
                    .arrow => try writer.writeAll("-> "),
                    .match => try writer.writeAll(": "),
                    // TODO: these should be determined by reverse engineering
                    // the required precedence based on parse tree. In other
                    // words, this function should to the exact opposite of
                    // parsing, and reconstruct precedence.
                    // .long_arrow => try writer.writeAll("--> "),
                    // .long_match => try writer.writeAll(":: "),
                    .list => try writer.writeAll(", "),
                    else => {},
                }
                try pattern.writeIndent(writer, optional_indent);
                // Don't write an s-exp as its redundant for ops
                // if (pattern.root.len > 0)
                //     try pattern.root[pattern.root.len - 1]
                //         .writeSExp(writer, optional_indent);
            },
        }
    }

    pub fn debug(self: Node, comptime fmt: []const u8) void {
        const allocator = std.debug.getDebugInfoAllocator();
        const node_str = self.formatSExp(allocator) catch unreachable;
        std.log.debug(fmt, .{node_str});
        defer allocator.free(node_str);
    }
};

pub const Pattern = struct {
    root: []Node = &.{},
    height: usize = 1, // patterns have a height because they are a branch

    pub fn isEmpty(self: Pattern) bool {
        return self.root.len == 0;
    }

    pub fn writeIndent(
        self: Pattern,
        writer: *Writer,
        optional_indent: ?usize,
    ) Writer.Error!void {
        const slice = self.root;
        if (slice.len == 0)
            return;
        // debug("tag: {s}", .{@tagName(pattern[0])});
        // std.log.debug("Write sexp on pattern len {}", .{self.root.len});
        try slice[0].writeSExp(writer, optional_indent);
        if (slice.len == 1) {
            return;
        } else for (slice[1 .. slice.len - 1]) |*pattern| {
            // debug("tag: {s}", .{@tagName(pattern)});
            try writer.writeByte(' ');
            try pattern.writeSExp(writer, optional_indent);
        }
        try writer.writeByte(' ');
        // debug("tag: {s}", .{@tagName(pattern[pattern.len - 1])});
        try slice[slice.len - 1]
            .writeSExp(writer, optional_indent);
    }

    pub fn write(
        self: Pattern,
        writer: *Writer,
    ) !void {
        return self.writeIndent(writer, 0);
    }

    pub fn toString(self: Pattern, allocator: Allocator) ![]const u8 {
        // TODO: properly grow buff
        var buff: std.ArrayList(u8) = try .initCapacity(allocator, 4096);
        errdefer buff.deinit(allocator);
        var writer = Io.Writer.fromArrayList(&buff);
        try self.write(&writer);
        return buff.toOwnedSlice(allocator);
    }

    pub fn copy(self: Pattern, allocator: Allocator) !Pattern {
        const pattern_copy = try allocator.alloc(Node, self.root.len);
        for (self.root, pattern_copy) |node, *node_copy|
            node_copy.* = try node.copy(allocator);

        return Pattern{
            .root = pattern_copy,
            .height = self.height,
        };
    }

    pub fn clone(self: Pattern, allocator: Allocator) !*Pattern {
        const pattern_copy_ptr = try allocator.create(Pattern);
        pattern_copy_ptr.* = try self.copy(allocator);

        return pattern_copy_ptr;
    }

    // Clears all memory and resets this Pattern's root to an empty pattern.
    pub fn deinit(pattern: *Pattern, allocator: Allocator) void {
        for (pattern.root) |*node| {
            @constCast(node).deinit(allocator);
        }
        allocator.free(pattern.root);
        pattern.* = .{};
    }

    pub fn destroy(self: *Pattern, allocator: Allocator) void {
        self.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn eql(self: Pattern, other: Pattern) bool {
        return self.height == other.height and
            self.root.len == other.root.len and
            for (self.root, other.root) |pattern, other_pattern| {
                if (!pattern.eql(other_pattern))
                    break false;
            } else true;
    }

    pub fn hasherUpdate(self: Pattern, hasher: anytype) void {
        // Height isn't hashed because it wouldn't add any new
        // information
        for (self.root) |pattern|
            pattern.hasherUpdate(hasher);
    }
};

/// A key node and its next term pointer for a trie, where only the
/// length of slice types are stored for keys (instead of pointers).
/// The term/next is a reference to a key/value in the HashMaps,
/// which owns both.
const Entry = HashMap.Entry;

/// This maps to branches, but the type is Branch instead of just *Self to
/// retrieve keys if necessary. The Self pointer references another field in
/// this trie, such as `keys`. Stores any and all values, vars and their indices
/// at each branch in the trie. Tracks the order of entries in the trie and
/// references to next pointers. An index for an entry is saved at every branch
/// in the trie for a given key. Branches may or may not contain values in their
/// ValueMap, for example in `Foo Bar -> 123`, the branch at `Foo` would have an
/// index to the key `Bar` and a leaf trie containing the value `123`.
const BranchNode = struct {
    // The string key and child trie entry from the current map.
    entry: Entry,
    // This points to the next branch in the entry's branch list. Necessary for
    // efficient lookups by index. There is always a next branch for keys/vars
    // and never for values.
    next_index: usize,

    pub fn this(branch_node: BranchNode) *Trie {
        return branch_node.entry.value_ptr;
    }

    pub fn next(branch_node: BranchNode) IndexBranch {
        return branch_node.entry.value_ptr.*
            .branches.items[branch_node.next_index];
    }
};

/// A single index and its next pointer in the trie. The union disambiguates
/// between values and the next variables/key. Keys are borrowed from the trie's
/// hashmap, but variables are owned (as they aren't stored as keys in the trie)
const Branch = union(enum) {
    key: BranchNode,
    variable: BranchNode,
    var_pattern: BranchNode,
    value: Pattern,

    pub fn node(branch: Branch) ?BranchNode {
        return switch (branch) {
            .key, .variable, .var_pattern => |branch_node| branch_node,
            .value => null,
        };
    }

    pub fn this(self: Branch) ?*Trie {
        switch (self) {
            .value => |value| {
                debug("Branch was a value, no next trie found", .{});
                _ = value;
                return null;
            },
            inline else => |branch_node| {
                return branch_node.this();
            },
        }
    }

    pub fn next(self: Branch) ?Branch {
        const branch_node = self.node() orelse
            return null;
        return branch_node; //.next();
    }
};

const IndexBranch = struct {
    usize, // Canonical trie index
    Branch,
};

pub const BranchList = ArrayList(IndexBranch);
pub const CacheList = ArrayList(usize);

/// For directing evaluations to completion. Initially, lower bound begins
/// at 0, for the upper bound, the length of the pattern (inclusive/exclusive
/// respectively)
const Bound = struct { lower: usize = 0, upper: usize };

/// Keeps track of which vars and var_pattern are bound to what part of an
/// expression given during matching.
pub const VarBindings = std.StringHashMapUnmanaged(Node);
pub const VarPatternBindings = std.StringHashMapUnmanaged(Pattern);

/// Maps terms to the next trie, if there is one. These form the branches of the
/// trie for a specific level of nesting. Each Key is in the map is unique, but
/// they can be repeated in separate indices. Therefore this stores its own next
/// Self pointer, and the indices for each key.
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
    // TODO remove and store in caches. Also possible to skip extra branches
    // as they can be found within a range. Only need to store one branch for
    // each trie with its minimum index, but indexing wouldn't be as fast
    branches: BranchList = .empty,
    key_cache: CacheList = .empty,
    var_cache: CacheList = .empty,
    var_pattern_cache: CacheList = .empty,
    value_cache: CacheList = .empty,
    depth: usize = 0, // TODO: implement depth caching

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
    /// Note that this isn't O(m) where m is the key length of the index.
    pub fn getIndexOrNull(self: Self, index: usize) ?Pattern {
        var current = &self;
        var branch: Branch = undefined;
        while (current.findNextBranch(index)) |next| {
            _, branch = next;
            current = branch.this() orelse
                return branch.value;
        }
        return null;
    }

    /// Rebuilds the key for a given index using an allocator for the
    /// arrays necessary to support the pattern structure, but pointers to the
    /// underlying keys.
    pub fn rebuildKey(
        self: Self,
        allocator: Allocator,
        index: usize,
    ) !Pattern {
        _ = index; // autofix
        _ = allocator; // autofix
        _ = self; // autofix
        @panic("unimplemented");
    }

    /// Deep copy a trie by value, as well as Keys and Variables.
    /// Use deinit to free.
    // TODO: optimize by allocating top level maps of same size and then
    // use putAssumeCapacity
    // TODO: use iterator instead of manually copying
    pub fn copy(self: Self, allocator: Allocator) Allocator.Error!Self {
        var result = Self{};
        var keys_iter = self.map.iterator();
        while (keys_iter.next()) |entry|
            try result.map.putNoClobber(
                allocator,
                entry.key_ptr.*,
                try entry.value_ptr.*.copy(allocator),
            );

        // result = try self.copy(allocator);
        // @panic("todo: copy all fields");
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

    /// The opposite of `copy`.
    /// TODO: check frees properly for owned and borrowed managers
    pub fn deinit(self: *Self, allocator: Allocator) void {
        defer self.map.deinit(allocator);
        self.branches.deinit(allocator);
        self.key_cache.deinit(allocator);
        self.var_cache.deinit(allocator);
        self.var_pattern_cache.deinit(allocator);
        self.value_cache.deinit(allocator);
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit(allocator);
        }
    }

    pub fn hash(self: Self) u32 {
        var hasher = Wyhash.init(0);
        self.hasherUpdate(&hasher);
        return @truncate(hasher.final());
    }

    pub fn hasherUpdate(self: Self, hasher: anytype) void {
        var map_iter = self.map.iterator();
        while (map_iter.next()) |entry| {
            entry.key_ptr.*.hasherUpdate(hasher);
            entry.value_ptr.*.hasherUpdate(hasher);
        }
        // No need to hash indices, only vars and values
        var vars_iter = self.vars.iterator();
        while (vars_iter.next()) |*entry| {
            hasher.update(entry.value_ptr.*);
        }
        var values_iter = self.values.iterator();
        // TODO: recurse
        while (values_iter.next()) |*entry| {
            entry.value_ptr.hasherUpdate(hasher);
        }
    }

    fn branchEql(comptime E: type, b1: E, b2: E) bool {
        return b1.key_ptr.eql(b2.key_ptr.*) and
            b1.value_ptr.eql(b2.value_ptr.*);
    }

    /// Tries are equal if they have the same literals, sub-arrays and
    /// sub-tries and if their variables are equal.
    pub fn eql(self: Self, other: Self) bool {
        if (self.map.count() != other.map.count())
            return false;
        var map_iter = self.map.iterator();
        var other_map_iter = other.map.iterator();
        while (map_iter.next()) |entry| {
            const other_entry = other_map_iter.next() orelse
                return false;
            if (!(mem.eql(u8, entry.key_ptr.*, other_entry.key_ptr.*)) or
                !entry.value_ptr.eql(other_entry.value_ptr.*))
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

    fn getBranch(
        self: Trie,
        bound: usize,
        key: []const u8,
        comptime tag: enum { key, variable, var_pattern },
    ) ?IndexBranchTrie {
        if (self.map.getEntry(key)) |entry| {
            debug(
                "Found string {s} in {*}",
                .{ key, &self },
            );
            // Find the next index from bound in the next trie, as it
            // will be the minimum index for this key
            if (entry.value_ptr.findNextByIndex(bound)) |branch_index| {
                const index, _ = entry.value_ptr.branches.items[branch_index];
                debug(
                    "Found branch in {*} for key {s} at index: {} within bound {}",
                    .{ entry.value_ptr, key, index, bound },
                );
                if (index < bound) panic(
                    "Index {} is less than bound {}\n",
                    .{ index, bound },
                );
                // Return the minimum index from the next trie but the
                // branch from this one
                return .{
                    .index = index,
                    .branch = @unionInit(Branch, @tagName(tag), .{
                        .entry = entry,
                        .next_index = branch_index,
                    }),
                    .trie = entry.value_ptr,
                };
            } else {
                debug(
                    "Key {s} found in trie, but no branches at or after bound {}",
                    .{ key, bound },
                );
                return null;
            }
        } else {
            debug("Key '{s}' not found in map", .{key});
            return null;
        }
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
            .key => |key| trie.map.get(key),
            .variable => |variable| trie.map.get(variable),
            .pattern => |sub_pattern| blk: {
                var current = trie.map.get("(") orelse
                    break :blk null;
                for (sub_pattern.root) |sub_node|
                    current = current.getTerm(sub_node) orelse
                        break :blk null;
                break :blk current.map.get(")");
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

    fn getOrPutKey(
        trie: *Self,
        allocator: Allocator,
        index: usize,
        key: []const u8,
    ) !*Self {
        const entry = try trie.map
            .getOrPutValue(allocator, key, Self{ .depth = trie.depth + 1 });
        const next = entry.value_ptr;
        try trie.key_cache.append(allocator, trie.branches.items.len);
        try trie.branches.append(
            allocator,
            IndexBranch{ index, .{
                .key = .{
                    .entry = entry,
                    .next_index = next.branches.items.len,
                },
            } },
        );
        return next;
    }

    fn getOrPutVar(
        trie: *Self,
        allocator: Allocator,
        index: usize,
        variable: []const u8,
    ) !*Self {
        const entry = try trie.map
            .getOrPutValue(allocator, variable, Self{});
        const next = entry.value_ptr;
        try trie.var_cache.append(allocator, trie.branches.items.len);
        try trie.branches.append(
            allocator,
            IndexBranch{ index, .{
                .variable = .{
                    .entry = entry,
                    .next_index = next.branches.items.len,
                },
            } },
        );
        return next;
    }

    fn getOrPutVarPattern(
        trie: *Self,
        allocator: Allocator,
        index: usize,
        var_pattern: []const u8,
    ) !*Self {
        const entry = try trie.map
            .getOrPutValue(allocator, var_pattern, Self{});
        const next = entry.value_ptr;
        try trie.var_pattern_cache.append(allocator, trie.branches.items.len);
        try trie.branches.append(
            allocator,
            IndexBranch{ index, .{
                .var_pattern = .{
                    .entry = entry,
                    .next_index = next.branches.items.len,
                },
            } },
        );
        return next;
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
            .key => |key| blk: {
                debug("getOrPutKey: {*} put {s} at index {}", .{ trie, key, index });
                const next = try trie.getOrPutKey(allocator, index, key);
                break :blk next;
            },
            .variable => |variable| try trie
                .getOrPutVar(allocator, index, variable),
            .var_pattern => |var_pattern| try trie
                .getOrPutVarPattern(allocator, index, var_pattern),
            .pattern => |sub_pat| blk: {
                var next = trie;
                debug("Processing pattern node at {*}", .{next});
                next = try next.getOrPutKey(allocator, index, "(");
                debug("Open paren address: {*}", .{next});
                next = try next.ensurePath(allocator, index, sub_pat);
                debug("Sub-pattern address: {*}", .{next});
                next = try next.getOrPutKey(allocator, index, ")");
                debug("Close paren address: {*}", .{next});
                break :blk next;
            },
            .trie => |sub_trie| {
                _ = sub_trie;
                // var next = try trie.getOrPutKey(allocator, index, "{");
                // next = try next.ensurePath(allocator, index, sub_trie);
                // next = try next.getOrPutKey(allocator, index, "}");
                // break :blk next;
                @panic("unimplemented\n");
            },
            .list => |comma| blk: {
                var next = trie;
                next = try next.getOrPutKey(allocator, index, ",");
                next = try next.ensurePath(allocator, index, comma);
                // debug("Comma literal address: {*}", .{next});
                // debug("Comma len {} at {*}", .{ comma.root.len, next });
                // for (0..comma.root.len - 1) |i| {
                //     next = try next.ensurePathTerm(allocator, index, comma.root[i]);
                //     debug("Comma Prefix address: {*}", .{next});
                // }
                // debug("last: {s}", .{comma.root[comma.root.len - 1].key});
                // next = try next.ensurePath(allocator, index, comma.root[comma.root.len - 1].pattern);
                // debug("Comma rhs address: {*}", .{next});

                break :blk next;
            },
            // Pattern trie's values will always be tries too, which will
            // map nested pattern to the next trie on the current level.
            // The resulting encoding is counter-intuitive when printed
            // because each level of nesting must be a branch to enable
            // trie matching.
            inline else => |pattern| {
                _ = pattern;
                @panic("unimplemented");
                // var next = try trie.getOrPutKey(allocator, index, "(");
                // // All op types are encoded the same way after their top
                // // level hash. These don't need special treatment because
                // // their structure is simple, and their operator unique.
                // next = try next.ensurePath(allocator, index, pattern);
                // next = try next.getOrPutKey(allocator, index, ")");
                // break :blk next;
            },
        };
    }

    /// Creates the necessary branches and key entries in the trie for
    /// pattern, and returns a pointer to the branch at the end of the path.
    /// While similar to a hashmap's getOrPut function, ensurePath always
    /// adds a new index, asserting that it did not already exist. There is
    /// no getOrPut equivalent for tries because they are append-only.
    ///
    /// The index must not already be in the trie.
    /// Pattern are copied.
    /// Returns a pointer to the updated trie node. If the given pattern is
    /// empty (0 len), the returned key and index are undefined.
    fn ensurePath(
        trie: *Self,
        allocator: Allocator,
        index: usize,
        pattern: Pattern,
    ) !*Self {
        var current = trie;
        // debug(
        //     "Ensure Path for {*} at index {} for pattern len {}",
        //     .{ trie, index, pattern.root.len },
        // );
        for (pattern.root) |node| {
            current = try current.ensurePathTerm(allocator, index, node);
        }
        return current;
    }

    /// Add a node to the trie by following `keys`, wrapping them into an
    /// Pattern of Nodes.
    /// Allocations:
    /// - The value, if given, is allocated and copied recursively
    /// Freeing should be done with `destroy` or `deinit`, depending on
    /// how `self` was allocated
    pub fn appendKey(
        self: *Self,
        allocator: Allocator,
        key: []const []const u8,
        value: Pattern,
    ) Allocator.Error!*Self {
        const root = try allocator.alloc(Node, key.len);
        defer allocator.free(root);
        for (root, key) |*node, token|
            node.* = Node.ofKey(token);

        return self.append(allocator, Pattern{ .root = root }, value);
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
        const index = trie.size();
        var current = trie;
        current = try current.ensurePath(allocator, index, pattern);
        // If there isn't a value, use the pattern as the value instead
        const value = optional_value orelse pattern;
        // try pattern.copy(allocator);
        try current.value_cache.append(
            allocator,
            current.branches.items.len,
        );
        debug(
            "Added value of len {} at index {} and branch index {} on trie {*}",
            .{ value.root.len, index, current.branches.items.len, current },
        );
        try current.branches.append(
            allocator,
            IndexBranch{ index, .{ .value = value } },
        );
        debug("Value cache: {any}", .{current.value_cache.items});
        return current;
    }

    /// A partial or complete match of a given pattern against a trie.
    pub const Match = struct {
        key: Pattern = .{}, // The pattern that was attempted to match
        value: ?Pattern = null,
        node_ptr: *const Trie,
        index: usize = 0,
        len: usize = 0, // For partial matches

        /// Node entries are just references, so they aren't freed by this
        /// function.
        pub fn deinit(self: *Match, allocator: Allocator) void {
            self.key.deinit(allocator);
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
            self.deinit(allocator);
        }
    };

    // TODO: convert to PriorityQueue
    const MatchQueue = ArrayList(IndexBranchTrie);

    /// A partial or complete sequence of matches of a pattern against a trie.
    const Eval = struct {
        value: ?*Pattern = null,
        index: usize = 0,
        len: usize = 0, // For partial matches
    };

    // Find the index of the next branch starting from bound.
    fn findNextByIndex(self: Self, bound: usize) ?usize {
        const branches = self.branches;
        // To compare by bound with other branches, it must be put into a Branch
        // first. Its kind can be undefined since it will never be returned.
        // const elem = IndexBranch{ bound, undefined };
        debug("Find next by index on bound: {}", .{bound});
        const index = sort.lowerBound(
            IndexBranch,
            branches.items,
            bound,
            struct {
                fn lessThan(
                    ctx: usize,
                    branch: IndexBranch,
                ) Order {
                    const i, _ = branch;
                    debug("Compare branches: {} < {}", .{ ctx, i });
                    return math.order(ctx, i);
                }
            }.lessThan,
        );
        // No index found if lowerBound returned the length of branches
        return if (index < branches.items.len)
            index
        else
            null;
    }

    fn findNextBranch(self: Self, bound: usize) ?IndexBranch {
        return if (self.findNextByIndex(bound)) |index|
            self.branches.items[index]
        else
            null;
    }

    /// Compares branches in the cache by first looking them up in the branch-
    /// indices list, then comparing the index to the bound.
    /// TODO: search only the remaining cache from branches_bound
    fn findNextByCache(
        self: Self,
        branches_bound: usize,
        cache: []const usize,
    ) ?IndexBranch {
        // debug("Cache: {any}", .{cache});
        const cache_index = sort.lowerBound(
            usize,
            cache,
            .{ branches_bound, self.branches.items }, // [branches_bound..]
            struct {
                fn lessThan(
                    ctx: struct { usize, []IndexBranch },
                    other_branch_index: usize,
                ) Order {
                    const branch_index, const branches = ctx;
                    const index, _ = branches[branch_index];
                    const other_index, _ = branches[other_branch_index];
                    // debug("Compare cached: {} < {}", .{ other_index, index });
                    return math.order(other_index, index);
                }
            }.lessThan,
        );
        // const branch_index = cache_index + branches_bound;
        // No index found if lowerBound returned the length of branches
        return if (cache_index < cache.len)
            self.branches.items[cache_index]
        else
            null;
    }

    /// Finds the next minimum key at this node by index.
    fn findNextKey(self: Self, bound: usize) ?IndexBranch {
        const branches_bound = self.findNextByIndex(bound) orelse
            return null;
        return self.findNextByCache(branches_bound, self.key_cache.items);
    }

    /// Finds the next minimum variable at this node by index.
    fn findNextVar(self: Self, bound: usize) ?IndexBranch {
        const branches_bound = self.findNextByIndex(bound) orelse
            return null;
        return self.findNextByCache(branches_bound, self.var_cache.items);
    }

    fn findNextVarPattern(self: Self, bound: usize) ?IndexBranch {
        const branches_bound = self.findNextByIndex(bound) orelse
            return null;
        return self.findNextByCache(branches_bound, self.var_pattern_cache.items);
    }

    /// Finds the next minimum value at this node by index.
    fn findNextValue(self: Self, bound: usize) ?IndexBranch {
        const branches_bound = self.findNextByIndex(bound) orelse
            return null;
        return self.findNextByCache(branches_bound, self.value_cache.items);
    }

    // // Finds the next minimum key, variable or value.
    fn findNext(self: Self, bound: usize) ?IndexBranch {
        const branches_bound = self.findNextByIndex(bound) orelse
            return null;

        return self.branches.items[branches_bound];
    }

    // // If the index is unchanged, its trivially the minimum match. If the
    // // next index is a variable or value its always the next branch.

    /// The first half of evaluation with backtracking. The variables in the node match
    /// anything in the trie, and vars in the trie match anything in
    /// the expression. Includes partial prefixes (ones that don't match all
    /// pattern). This function returns any trie branches, even if their
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
    /// Time Complexity: O(mlogn) where m is the key len and n is the size of the trie.
    /// Returns a trie of the subset of branches that matches `node`. Caller
    /// owns the trie returned, but it is a shallow copy and thus cannot be
    /// freed with destroy/deinit without freeing references in self.
    // Add this struct near the top with other Match/Eval structs

    /// Finds all possible branches that could match the given node at or after
    /// bound.
    /// Returns a queue of all candidate matches with their indices, branches,
    /// and updated bindings.
    fn matchAllTerms(
        self: *const Self,
        // allocator: Allocator,
        // bound: usize,
        // bindings: VarBindings,
        // node: Node,
    ) Allocator.Error!MatchQueue {
        _ = self;
        @panic("unimplemented\n");
    }

    /// Find the first term at or after bound
    fn matchTerm(
        self: *const Self,
        allocator: Allocator,
        bound: usize,
        term_bindings: *VarBindings,
        pattern_bindings: *VarPatternBindings,
        node: Node,
    ) Allocator.Error!?IndexBranchTrie {
        // debug("Branching `", .{});
        // node.debug("{s}");
        // debug("` from bound {}", .{bound});

        // Check for variable branches that match anything
        if (self.findNextVar(bound)) |var_candidate| {
            const var_bound, const var_branch = var_candidate;
            // debug("Found var branch at index: {}", .{var_bound});

            const branch_node = switch (var_branch) {
                .variable => |variable| variable,
                .value => panic("Expected variable, found value", .{}),
                inline else => |b, tag| panic(
                    "Expected variable, found {s} {s} at {*}",
                    .{ @tagName(tag), b.entry.key_ptr.*, b.entry.value_ptr },
                ),
            };
            const variable = branch_node.entry.key_ptr.*;

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
            .key => |key| {
                debug(
                    "Checking {*} for key match {s} at bound {}",
                    .{ self, key, bound },
                );
                return self.getBranch(bound, key, .key);
            },

            .variable => |variable| {
                // Match against bound variable or bind new one
                if (term_bindings.get(variable)) |bound_node| {
                    debug("Checking existing var binding: {s}", .{variable});
                    // Variable already bound - need to match the bound value
                    return if (node.eql(bound_node)) {
                        panic("unimplemented\n", .{});
                    } else {
                        panic("unimplemented\n", .{});
                    };
                } else {
                    debug(
                        "Variable {s} not yet bound - matches anything",
                        .{variable},
                    );
                    // Variable not bound - it can match any single term
                    // We need to try matching each possible branch
                    if (self.findNext(bound)) |next_candidate| {
                        const next_index, const next_branch = next_candidate;

                        // Bind the variable to what we're matching
                        const bound_value = switch (next_branch) {
                            .key => |branch_node| Node.ofKey(
                                branch_node.entry.key_ptr.*,
                            ),
                            .variable => |branch_node| Node.ofVar(
                                branch_node.entry.key_ptr.*,
                            ),
                            .var_pattern => |branch_node| Node{
                                .var_pattern = branch_node.entry.key_ptr.*,
                            },
                            .value => {
                                // TODO
                                // new_bindings.deinit(allocator);
                                return null;
                            },
                        };

                        try term_bindings.put(allocator, variable, bound_value);

                        return .{
                            .index = next_index,
                            .branch = next_branch,
                            .trie = next_branch.variable.entry.value_ptr,
                        };
                    }
                }
            },
            .pattern => |pattern| {
                // Match opening paren
                const open_entry = self.map.getEntry("(") orelse
                    return null;
                const open_trie = open_entry.value_ptr;
                debug("Matching sub-pattern on {*}", .{open_trie});
                var index, _ = open_trie.findNext(bound) orelse
                    return null;

                // Recursively match the pattern contents
                var pattern_match = try open_trie
                    .match(allocator, index, term_bindings, pattern_bindings, pattern);
                defer pattern_match.deinit(allocator);
                index = pattern_match.index;
                if (pattern_match.len != pattern.root.len) {
                    debug("Sub-pattern match failed: only matched {} of {} terms", .{
                        pattern_match.len,
                        pattern.root.len,
                    });
                    return null;
                }
                debug("Sub-pattern matched {*}", .{pattern_match.node_ptr});
                // Successfully matched entire pattern, now match closing paren
                const close_entry = pattern_match.node_ptr.map.getEntry(")") orelse
                    return null;
                const close_trie = close_entry.value_ptr;
                debug("Closing paren matched {*}", .{close_trie});
                index, const branch = close_trie.findNext(index) orelse
                    return null;
                debug("Sub-pattern matched, returning trie: {*}", .{close_trie});
                // As with key matching, don't return the next trie, but rather
                // the current trie (which we got from looking up the closing paren)
                return .{
                    .index = index,
                    .branch = branch,
                    .trie = close_trie,
                };
            },

            .var_pattern => {
                // @panic("var_pattern matching not yet implemented");
            },
            .list => |pattern| {
                // debug("Matched list with len {}", .{pattern.root.len});
                const open_entry = self.map.getEntry(",") orelse
                    return null;
                const open_trie = open_entry.value_ptr;
                // debug("Matched comma at {*}", .{open_trie});
                const branch_index = open_trie.findNextByIndex(bound) orelse
                    return null;
                const index, const branch = self.branches.items[branch_index];
                var pattern_match = try open_trie
                    .match(allocator, index, term_bindings, pattern_bindings, pattern);
                defer pattern_match.deinit(allocator);
                debug("Matched tail at {*}", .{pattern_match.node_ptr});
                return .{
                    .index = index,
                    .branch = branch,
                    .trie = pattern_match.node_ptr,
                };
            },
            .trie => {
                @panic("trie matching not yet implemented");
            },
            inline .arrow, .match, .infix => |_, tag| {
                std.debug.panic(
                    "unimplemented node type {s} in matchTerm",
                    .{@tagName(tag)},
                );
            },
        }

        return null;
    }

    /// Finds the lowest index full match for the entire pattern.
    /// A full match means every term in the pattern matched a branch in the trie.
    pub fn match(
        self: *const Self,
        allocator: Allocator,
        bound: usize,
        term_bindings: *VarBindings,
        pattern_bindings: *VarPatternBindings,
        pattern: Pattern,
    ) Allocator.Error!Match {
        debug(
            "=== Starting match for pattern of length {} from bound {} ===",
            .{ pattern.root.len, bound },
        );
        var node_list = ArrayList(Node).empty;
        errdefer for (node_list.items) |term| term.deinit(allocator);
        var current = self;
        var index = bound;
        var result: ?Pattern = null;
        // For each subsequent term, extend candidates that can continue matching
        var pattern_index: usize = 0;
        while (pattern_index < pattern.root.len) : (pattern_index += 1) {
            const rest = Pattern{
                .root = pattern.root[pattern_index..],
                .height = pattern.height,
            };
            // TODO: stop early if there are more terms in trie and they match
            if (current.findNextVarPattern(bound)) |var_candidate| {
                const var_bound, const var_pattern_branch = var_candidate;
                debug("Found var_pattern branch at index: {}", .{var_bound});

                const branch_node = var_pattern_branch.var_pattern;
                const var_pattern = branch_node.entry.key_ptr.*;

                const get_or_put = try pattern_bindings.getOrPut(allocator, var_pattern);

                // Variable already bound - only match if node equals bound value
                if (get_or_put.found_existing) {
                    if (get_or_put.value_ptr.eql(rest))
                        // return IndexBranchTrie{
                        //     .index = var_bound,
                        //     .branch = var_pattern_branch,
                        //     .trie = branch_node.entry.value_ptr,
                        // }
                        @panic("unimplemented\n")
                    else {
                        // TODO
                        // new_bindings.deinit(allocator);
                        @panic("unimplemented\n");
                    }
                } else {
                    get_or_put.value_ptr.* = rest;

                    // Bind the variable to this node
                    try pattern_bindings.put(allocator, var_pattern, rest);
                    // TODO: save for later, we still need to compare indices
                    // with possible matches below to find the smallest
                    current = branch_node.entry.value_ptr;
                }
                // Already bound the full pattern, so skip the loop below
                pattern_index = pattern.root.len;
                // debug("break with remaining len: {}", .{rest.root.len});
                break;
            }
            // debug("pattern root len: {}", .{pattern.root.len});

            // debug("pattern index: {}", .{pattern_index});
            // debug("pattern.root[0] = {s}", .{@tagName(pattern.root[0])});
            // Start with initial candidates for the first term
            const index_branch_trie = try current.matchTerm(
                allocator,
                bound,
                term_bindings,
                pattern_bindings,
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
                .key => |key| {
                    debug(
                        "Appending key branch at index {} of {s}",
                        .{ index, key.entry.key_ptr.* },
                    );
                    try node_list.append(
                        allocator,
                        Node{ .key = key.entry.key_ptr.* },
                    );
                },
                .variable => |variable| {
                    debug(
                        "Appending variable branch at index {} of {s}",
                        .{ index, variable.entry.key_ptr.* },
                    );
                    try node_list.append(
                        allocator,
                        Node{ .variable = variable.entry.key_ptr.* },
                    );
                },
                .var_pattern => |var_pattern| {
                    debug(
                        "Appending var_pattern branch at index {} of {s}",
                        .{ index, var_pattern.entry.key_ptr.* },
                    );
                    try node_list.append(
                        allocator,
                        Node{ .var_pattern = var_pattern.entry.key_ptr.* },
                    );
                },
                .value => |value| {
                    // current = index_branch.next();
                    result = value;
                    debug(
                        "Found value branch at index {} address {*}",
                        .{ index, current },
                    );
                    pattern_index += 1;
                    break;
                },
            }
            // debug("Next trie term at {*}", .{index_branch_trie.trie});
            current = index_branch_trie.trie;
            // orelse {
            //     debug("No next trie found at index {}", .{index});
            //     pattern_index += 1;
            //     break;
            // };
        }
        const full_match = pattern_index == pattern.root.len;
        debug(
            "pattern_index {} == pattern root len: {}",
            .{ pattern_index, pattern.root.len },
        );
        if (!full_match)
            debug("No full match found", .{})
        else {
            // debug("Full match found", .{});

            if (current.findNextValue(bound)) |value_candidate| {
                debug("Value found", .{});
                _, const value_branch = value_candidate;
                result = value_branch.value;
            }
        }

        return Match{
            .key = Pattern{ .root = try node_list.toOwnedSlice(allocator) },
            .value = if (full_match) result else null,
            //  blk: {
            //     _, const branch = current.findNextValue(index) orelse
            //         break :blk null;
            //     break :blk branch.value;
            // },
            .node_ptr = current,
            .index = index,
            .len = pattern_index,
        };
    }

    /// The second half of an evaluation step. Rewrites all variable
    /// captures into the matched expression. Copies any variables in node
    /// if they are keys in bindings with their values. If there are no
    /// matches in bindings, this functions is equivalent to copy. The
    /// result should be freed shallowly with ArrayList.deinit.
    /// This function takes an arraylist instead of an allocator, which is
    /// assumed empty and returned empty.
    pub fn rewrite(
        self: Self,
        allocator: Allocator,
        bound: usize,
        pattern: Pattern,
        term_bindings: *VarBindings,
        pattern_bindings: *VarPatternBindings,
    ) Allocator.Error!Pattern {
        // debug("Rewrite pattern of len {}", .{pattern.root.len});
        var result = ArrayList(Node).empty;
        errdefer result.deinit(allocator);

        for (pattern.root) |node| switch (node) {
            .key => |key| try result.append(allocator, Node.ofKey(key)),
            .variable => |variable| {
                if (term_bindings.get(variable)) |_|
                    debug("Var found: {s}", .{variable})
                else
                    debug("Var not found", .{});
                try result.append(
                    allocator,
                    term_bindings.get(variable) orelse
                        node,
                );
            },
            .var_pattern => |var_pattern| {
                if (pattern_bindings.get(var_pattern)) |_|
                    debug("Var pattern get {s}: ", .{var_pattern})
                    // var_node.writeSExp(streams.err, null) catch unreachable
                else
                    debug("Var pattern not found", .{});
                if (pattern_bindings.get(var_pattern)) |sub_pattern| {
                    // TODO: calculate correct height with sub_pattern's
                    // height
                    // for (sub_pattern.root) |sub_node|
                    //     try result.append(allocator, sub_node);

                    try result.appendSlice(
                        allocator,
                        sub_pattern.root,
                        // (next.value orelse sub_pattern).root,
                    );
                } else try result.append(allocator, node);
            },
            inline .pattern, .arrow, .match, .list, .infix => |nested, tag| {
                const rewritten = try self.rewrite(allocator, bound, nested, term_bindings, pattern_bindings);

                // debug("Rewrite recursing on {s} len {}", .{ @tagName(tag), nested.root.len });
                try result.append(allocator, @unionInit(
                    Node,
                    @tagName(tag),
                    // nested_eval.value orelse nested,
                    rewritten,
                ));
            },
            else => panic("unimplemented", .{}),
        };
        // debug(
        //     "Rewrite returning on pattern len {} with result len {}",
        //     .{ pattern.root.len, result.items.len },
        // );

        return Pattern{ .root = try result.toOwnedSlice(allocator) };
    }

    /// Follow `pattern` in `self` until no matches. Performs a partial,
    /// but exhaustive match (keeps evaluating any results of the query) and
    /// if possible a rewrite.
    /// Starts matching between [lower, upper) bounds, shrinking the upper bound
    /// to each matched value's index. If nothing matches, then a single node
    /// trie with the same value as self is returned.
    /// Caller owns and should free the result's value and bindings with
    /// Match.deinit.
    pub fn evaluateSlice(
        self: Self,
        allocator: Allocator,
        pattern: Pattern,
        result: *ArrayList(Node),
    ) Allocator.Error!Pattern {
        var bound: Bound = .{ .upper = self.size() };
        var total_matched: usize = 0;
        var matched: Match = .{ .index = 0 };
        while (matched.index < bound.upper) : (bound.upper = matched.index) {
            debug("Matching from bounds [{},{})", .{ bound.lower, bound.upper });
            matched = try self.match(allocator, bound.lower, pattern);
            defer matched.deinit(allocator);
            debug(
                "Match result: {} of {} pattern nodes at index {}, ",
                .{ matched.len, pattern.root.len, matched.index },
            );
            if (matched.value) |value| {
                debug("matched value: {}", .{value});
                // return value;
                // _ = result;
                return try rewrite(allocator, value, matched.bindings, result);
            } else debug("but no match", .{});
            total_matched += matched.len;
            if (total_matched < pattern.root.len)
                break;
        }
        return try pattern.copy(allocator);
    }

    /// A simple evaluator that matches patterns only if all their terms match
    /// (unlike concatenative evaluation, that supports partial matches)
    /// Caller frees with `Pattern.deinit(allocator)`
    pub fn evaluateComplete(
        self: Self,
        allocator: Allocator,
        bound: usize,
        pattern: Pattern,
    ) Allocator.Error!Eval {
        var matched: Match = .{ .node_ptr = &self };
        var index: usize = bound;
        var current: *Pattern = try pattern.clone(allocator);
        current = current;
        var term_bindings = VarBindings{};
        defer term_bindings.deinit(allocator);
        var pattern_bindings = VarPatternBindings{};
        defer pattern_bindings.deinit(allocator);
        while (index < self.size()) {
            // while (current.height < pattern.height) : (len_matched += matched.len) {
            // } else
            matched = try self.match(allocator, index, &term_bindings, &pattern_bindings, current.*);
            // defer matched.deinit(allocator);
            if (matched.index < index)
                panic("Match index bug: matched.index {} < index {}", .{ matched.index, index });

            index = matched.index + 1;

            const next = matched.value orelse {
                debug("Eval match at {*}, but no value", .{matched.node_ptr});
                // current.destroy(allocator);
                break;
            };
            // debug("Matched len: {}", .{matched.len});
            // }
            // debug("Matched all", .{});

            // Rewrite all current bindings into the matched value
            // current.destroy(allocator);
            current.* = try self.rewrite(
                allocator,
                bound,
                next,
                &term_bindings,
                &pattern_bindings,
            );
            // Reset bindings for each new match index
            term_bindings.clearRetainingCapacity();
            pattern_bindings.clearRetainingCapacity();

            // debug("vars in map: {}", .{bindings.size});
            const slice = .{};

            // Prevent infinite recursion at this index. Recursion
            // through other indices will be terminated by match index
            // shrinking.
            if (slice.len == next.root.len) {
                panic("unimplemented\n", .{});
                // for (slice, next.root) |trie, next_trie| {
                //     // check if the same trie's shape could be matched
                //     // TODO: use a trie match function here instead of eql
                //     if (!trie.asEmpty().eql(next_trie))
                //         break;
                // } else break; // Don't evaluate the same trie
            }
            // debug("Eval matched len {}", .{next.root.len});
            // next.debug("{s}");
            // next.write(streams.err) catch unreachable;
            // streams.err.writeByte('\n') catch unreachable;

            // debug(
            //     "Comparing heights: current {} < query {}",
            //     .{ current.height, pattern.height },
            // );

            debug("Next eval index: {}\n", .{index});
        }

        // if (matched.len != pattern.root.len) {
        // debug("No complete match, skipping index {}.", .{matched.index});
        // Evaluate nested patterns that failed to match
        // TODO: replace recursion with a continue
        // Recurse into nested expressions
        for (current.root, 0..) |*nested, i| switch (nested.*) {
            inline else => |sub_pattern, tag| if (@TypeOf(sub_pattern) == Pattern) {
                debug("Recursing into pattern at index {} of len {}", .{
                    i,
                    sub_pattern.root.len,
                });
                // Sub-expressions start over from 0 (structural recursion) if
                // the sub_pattern length is less than the original
                const nested_eval = try self.evaluateComplete(
                    allocator,
                    matched.index,
                    // TODO
                    // if (sub_pattern.height < pattern.height)
                    //     0
                    // else
                    //     matched.index + 1,
                    sub_pattern,
                );
                // nested.deinit(allocator);
                // Recursively eval nested list but preserve node type
                nested.* = @unionInit(
                    Node,
                    @tagName(tag),
                    if (nested_eval.value) |ptr|
                        ptr.*
                    else
                        try sub_pattern.copy(allocator),
                );
            },
        };
        const eval = Eval{
            .value = current,
            .index = matched.index,
            .len = matched.len,
        };
        debug("Evaluated {} nodes at index {}\n", .{ eval.len, eval.index });
        return eval;
    }

    /// Given a trie and a query to match against it, this function
    /// continously matches until no matches are found, or a match repeats.
    /// Match result cases:
    /// - a trie of lower ordinal: continue
    /// - the same trie: continue unless tries are equivalent
    /// - a trie of higher ordinal: break
    // TODO: fix ops as keys not being matched
    // TODO: refactor with evaluateStep
    // pub fn evaluate(
    //     self: *Self,
    //     allocator: Allocator,
    //     pattern: Pattern,
    // ) Allocator.Error!Pattern {
    //     var index: usize = 0;
    //     var buffer = ArrayList(Node).init(allocator);
    //     while (index < pattern.root.len) {
    //         const eval = try self.evaluateSlice(allocator, pattern, &result);
    //         if (result.items.len == 0) {
    //             debug("No match, skipping index {}.", .{index});
    //             try result.append(
    //                 // Evaluate nested pattern that failed to match
    //                 // TODO: replace recursion with a continue
    //                 // TODO needs another nested result list
    //                 switch (result.items[index]) {
    //                     inline .pattern, .match, .arrow, .list => |slice, tag|
    //                     // Recursively eval nested list but preserve node type
    //                     @unionInit(
    //                         Node,
    //                         @tagName(tag),
    //                         try self.evaluate(allocator, slice),
    //                     ),
    //                     else => try pattern[index].copy(allocator),
    //                 },
    //             );
    //             index += 1;
    //             continue;
    //         }
    //         debug("vars in map: {}", .{eval.bindings.entries.len});
    //         const slice = .{};
    //         if (eval.value) |next| {
    //             // Prevent infinite recursion at this index. Recursion
    //             // through other indices will be terminated by match index
    //             // shrinking.
    //             if (slice.len == next.pattern.len)
    //                 for (slice, next.pattern) |trie, next_trie| {
    //                     // check if the same trie's shape could be matched
    //                     // TODO: use a trie match function here instead of eql
    //                     if (!trie.asEmpty().eql(next_trie))
    //                         break;
    //                 } else break; // Don't evaluate the same trie
    //             debug("Eval matched {s}: ", .{@tagName(next.*)});
    //             next.write(streams.err) catch unreachable;
    //             streams.err.writeByte('') catch unreachable;
    //             const rewritten =
    //                 try rewrite(next.pattern, eval.bindings, buffer);
    //             defer Node.ofPattern(rewritten).deinit(allocator);
    //             const sub_eval = try self.evaluate(allocator, rewritten);
    //             defer allocator.free(sub_eval);
    //             try result.appendSlice(allocator, sub_eval);
    //         } else {
    //             try result.appendSlice(allocator, slice);
    //             debug("Match, but no value", .{});
    //         }
    //         index += eval.len;
    //     }
    //     debug("Eval: ", .{});
    //     for (result.items) |trie| {
    //         debug("{s} ", .{@tagName(trie)});
    //         trie.writeSExp(streams.err, 0) catch unreachable;
    //         streams.err.writeByte(' ') catch unreachable;
    //     }
    //     streams.err.writeByte('') catch unreachable;
    //     return result.toOwnedSlice();
    // }

    pub fn size(self: Self) usize {
        return self.branches.items.len;
    }

    /// Returns a slice of keys, where each key is concatenated into a string.
    pub fn keys(self: Self, allocator: Allocator) ![][]const u8 {
        const result = try allocator.alloc([][]const u8, self.count());
        for (result) |slice_ptr| {
            var key = ArrayList([]const u8){};
            try self.writeValues(allocator, key);
            slice_ptr = key.toOwnedSlice(allocator);
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
        var buff = ArrayList(u8).init(allocator);
        self.pretty(buff.writer());
        return buff.toOwnedSlice();
    }

    /// Print a trie without newlines
    pub fn write(self: Self, writer: anytype) !void {
        try self.writeIndent(writer, null);
    }

    /// Writes a single entry in the trie canonically. Index must be
    /// valid.
    pub fn writeIndex(
        writer: anytype,
        index_branch: IndexBranch,
    ) !void {
        const index, var branch = index_branch;
        if (comptime debug_mode)
            try writer.print("{} | ", .{index});

        while (branch.node()) |branch_node| : (_, branch = branch_node.next()) {
            try writer.writeAll(branch_node.entry.key_ptr.*);
            try writer.writeByte(' ');
        }
        // TODO print correct precedence
        try writer.writeAll("--> ");
        try branch.value.writeIndent(writer, null);
    }

    /// Print a trie in order based on indices.
    pub fn writeCanonical(self: Self, writer: anytype) !void {
        for (self.branches.items) |index_branch| {
            try writeIndex(writer, index_branch);
            try writer.writeByte('\n');
        }
    }

    pub const indent_increment = 2;
    pub fn writeIndent(
        self: *const Self,
        writer: anytype,
        optional_indent: ?usize,
    ) Writer.Error!void {
        if (debug_mode)
            try writer.print("{*} ", .{self});
        try writer.writeAll("❬");
        for (self.value_cache.items) |value_index_branch| {
            const index, const branch = self.branches.items[value_index_branch];
            if (debug_mode)
                try writer.print("{} ({}): ", .{ index, value_index_branch });
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
        try writeEntries(self.map, writer, optional_indent_inc);
        for (0..optional_indent orelse 0) |_|
            try writer.writeByte(' ');
        try writer.writeByte('}');
        try writer.writeAll(if (optional_indent) |_| "\n" else "");
    }

    fn writeEntries(
        map: anytype,
        writer: anytype,
        optional_indent: ?usize,
    ) Writer.Error!void {
        var iter = map.iterator();
        while (iter.next()) |entry| {
            for (0..optional_indent orelse 1) |_|
                try writer.writeByte(' ');

            const node = entry.key_ptr.*;
            try writer.writeAll(node);
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

    var trie1 = Trie{};
    var trie2 = Trie{};

    var key_root = [_]Node{
        .{ .key = "Aa" },
        .{ .key = "Bb" },
    };
    var val_root = [_]Node{.{ .key = "Value" }};
    const key = Pattern{ .root = &key_root };
    const val = Pattern{ .root = &val_root };
    const ptr1 = try trie1.append(allocator, key, val);
    const ptr2 = try trie2.append(allocator, key, val);

    try testing.expect(trie1.getIndexOrNull(0) != null);
    try testing.expect(trie2.getIndexOrNull(0) != null);

    // Compare leaves that share the same value
    try testing.expect(ptr1.eql(ptr2.*));

    // Compare tries that have the same key and value
    try testing.expect(trie1.eql(trie2));
    try testing.expect(trie2.eql(trie1));
}

test "Structure: put single lit" {}

test "Structure: put multiple lits" {
    // Multiple keys
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    var val_root = [_]Node{.{ .key = "Val" }};
    var key_root = [_]Node{
        .{ .key = "1" },
        .{ .key = "2" },
        .{ .key = "3" },
    };
    const val = Pattern{ .root = &val_root };
    _ = try trie.append(
        testing.allocator,
        Pattern{ .root = &key_root },
        val,
    );
    try testing.expect(trie.map.contains("1"));
    try testing.expect(trie.map.get("1").?.map.contains("2"));
    try testing.expectEqualDeep(trie.getIndex(0), val);
}

test "Memory: simple" {
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    var empty_root = [_]Node{};
    var val1_root = [_]Node{.{ .key = "123" }};
    var key2_root = [_]Node{ .{ .key = "01" }, .{ .key = "12" } };
    var val2_root = [_]Node{.{ .key = "123" }};
    var key3_root = [_]Node{ .{ .key = "01" }, .{ .key = "12" } };
    var val3_root = [_]Node{.{ .key = "234" }};

    const ptr1 = try trie.append(
        testing.allocator,
        Pattern{ .root = &empty_root },
        Pattern{ .root = &val1_root },
    );
    const ptr2 = try trie.append(
        testing.allocator,
        Pattern{ .root = &key2_root },
        Pattern{ .root = &val2_root },
    );
    const ptr3 = try trie.append(
        testing.allocator,
        Pattern{ .root = &key3_root },
        Pattern{ .root = &val3_root },
    );

    try testing.expect(ptr1 != ptr2);
    try testing.expectEqual(ptr2, ptr3);
}

test "Behavior: vars" {
    var nested_trie = try Trie.create(testing.allocator);
    defer nested_trie.destroy(testing.allocator);

    var val_root = [_]Node{.{ .key = "Beautiful" }};
    _ = try nested_trie.appendKey(
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

    // Insert a key with a nested sub-pattern: (A B) -> Result
    var inner_root = [_]Node{ .{ .key = "A" }, .{ .key = "B" } };
    var key_root = [_]Node{.{ .pattern = .{ .root = &inner_root } }};
    var val_root = [_]Node{.{ .key = "Result" }};

    const key = Pattern{ .root = &key_root };
    const val = Pattern{ .root = &val_root };
    _ = try trie.append(testing.allocator, key, val);

    // The nested pattern should be encoded as "(" -> "A" -> "B" -> ")"
    try testing.expect(trie.map.contains("("));
    const open_trie = trie.map.get("(").?;
    try testing.expect(open_trie.map.contains("A"));
    const a_trie = open_trie.map.get("A").?;
    try testing.expect(a_trie.map.contains("B"));
    const b_trie = a_trie.map.get("B").?;
    try testing.expect(b_trie.map.contains(")"));

    // Should be retrievable via get
    const result = trie.get(key);
    try testing.expect(result != null);

    // Should retrieve the correct value at index 0
    try testing.expectEqualDeep(trie.getIndex(0), val);

    // A non-matching nested pattern should return null
    var wrong_inner = [_]Node{ .{ .key = "A" }, .{ .key = "C" } };
    var wrong_key_root = [_]Node{.{ .pattern = .{ .root = &wrong_inner } }};
    const wrong_key = Pattern{ .root = &wrong_key_root };
    try testing.expect(trie.get(wrong_key) == null);
}

test "Behavior: equal variables" {
    // Two entries with variables: both use var "x" but with different values
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    // Entry 0: x -> Val1
    var key1_root = [_]Node{.{ .variable = "x" }};
    var val1_root = [_]Node{.{ .key = "Val1" }};
    _ = try trie.append(
        testing.allocator,
        Pattern{ .root = &key1_root },
        Pattern{ .root = &val1_root },
    );

    // Entry 1: x -> Val2 (same variable name, different value)
    var key2_root = [_]Node{.{ .variable = "x" }};
    var val2_root = [_]Node{.{ .key = "Val2" }};
    _ = try trie.append(
        testing.allocator,
        Pattern{ .root = &key2_root },
        Pattern{ .root = &val2_root },
    );

    // Both entries share the same variable name in the map
    try testing.expect(trie.map.contains("x"));
    try testing.expectEqual(@as(usize, 2), trie.size());

    // Matching from bound 0 should find index 0
    var term_bindings = VarBindings{};
    defer term_bindings.deinit(testing.allocator);
    var pattern_bindings = VarPatternBindings{};
    defer pattern_bindings.deinit(testing.allocator);

    var query_root = [_]Node{.{ .key = "anything" }};
    const query = Pattern{ .root = &query_root };

    var match1 = try trie.match(
        testing.allocator,
        0,
        &term_bindings,
        &pattern_bindings,
        query,
    );
    defer match1.deinit(testing.allocator);
    // A variable in the trie should match the literal "anything"
    try testing.expect(match1.value != null);
    try testing.expectEqualDeep(
        match1.value.?,
        Pattern{ .root = &val1_root },
    );

    // The variable "x" should now be bound to the key "anything"
    const bound_val = term_bindings.get("x");
    try testing.expect(bound_val != null);
    try testing.expect(std.meta.eql(bound_val.?, Node{ .key = "anything" }));
}

test "Behavior: equal keys, different indices" {
    // TODO
}

test "Behavior: equal keys, different structure" {
    // Keys that share a prefix but diverge — they should coexist in the trie
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    // Entry 0: A B -> Val1
    var key1_root = [_]Node{ .{ .key = "A" }, .{ .key = "B" } };
    var val1_root = [_]Node{.{ .key = "Val1" }};
    _ = try trie.append(
        testing.allocator,
        Pattern{ .root = &key1_root },
        Pattern{ .root = &val1_root },
    );

    // Entry 1: A C -> Val2 (shares prefix "A", diverges at second node)
    var key2_root = [_]Node{ .{ .key = "A" }, .{ .key = "C" } };
    var val2_root = [_]Node{.{ .key = "Val2" }};
    _ = try trie.append(
        testing.allocator,
        Pattern{ .root = &key2_root },
        Pattern{ .root = &val2_root },
    );

    // Entry 2: A B D -> Val3 (extends entry 0's key)
    var key3_root = [_]Node{ .{ .key = "A" }, .{ .key = "B" }, .{ .key = "D" } };
    var val3_root = [_]Node{.{ .key = "Val3" }};
    _ = try trie.append(
        testing.allocator,
        Pattern{ .root = &key3_root },
        Pattern{ .root = &val3_root },
    );

    // The root should only have "A" (shared prefix)
    try testing.expectEqual(@as(usize, 1), trie.map.count());
    try testing.expect(trie.map.contains("A"));

    // Under "A", both "B" and "C" should exist
    const a_trie = trie.map.get("A").?;
    try testing.expect(a_trie.map.contains("B"));
    try testing.expect(a_trie.map.contains("C"));

    // Under "A" -> "B", "D" should also exist (from entry 2)
    const b_trie = a_trie.map.get("B").?;
    try testing.expect(b_trie.map.contains("D"));

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

    // get() with full key should find the right sub-trie
    const ab_result = trie.get(Pattern{ .root = &key1_root });
    try testing.expect(ab_result != null);

    const ac_result = trie.get(Pattern{ .root = &key2_root });
    try testing.expect(ac_result != null);

    const abd_result = trie.get(Pattern{ .root = &key3_root });
    try testing.expect(abd_result != null);

    // A non-existent path should return null
    var missing_root = [_]Node{ .{ .key = "A" }, .{ .key = "Z" } };
    try testing.expect(trie.get(Pattern{ .root = &missing_root }) == null);
}

test "Trie: equal to copy" {
    var nested_trie = try Trie.create(testing.allocator);
    defer nested_trie.destroy(testing.allocator);

    var val_root = [_]Node{.{ .key = "Beautiful" }};
    _ = try nested_trie.appendKey(
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

test "Pattern: equal to copy" {
    var root = [_]Node{
        .{ .key = "cherry" },
        .{ .key = "blossom" },
        .{ .key = "tree" },
    };
    const pattern = Pattern{ .root = &root };
    const copy = try pattern.copy(testing.allocator);
    defer copy.deinit(testing.allocator);
    assert(pattern.eql(copy));
    assert(copy.eql(pattern));
}

test "Pattern: equal to clone" {
    var list_root = [_]Node{.{ .key = "tree" }};
    var root = [_]Node{
        .{ .key = "cherry" },
        .{ .key = "blossom" },
        .{ .list = .{ .root = &list_root } },
    };
    const pattern = Pattern{ .root = &root };
    const clone = try pattern.clone(testing.allocator);
    defer clone.destroy(testing.allocator);
    assert(pattern.eql(clone.*));
    assert(clone.eql(pattern));
}

test "findNextByCache" {
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    var key_root = [_]Node{
        .{ .key = "A" },
        .{ .key = "B" },
    };
    var val_root_1 = [_]Node{.{ .key = "123" }};
    var val_root_2 = [_]Node{.{ .key = "456" }};
    const key = Pattern{ .root = &key_root };
    const value1 = Pattern{ .root = &val_root_1 };
    _ = try trie.append(testing.allocator, key, value1);
    const value2 = Pattern{ .root = &val_root_2 };
    _ = try trie.append(testing.allocator, key, value2);

    const value_trie = trie.get(key) orelse unreachable;
    var branch_index = value_trie.findNextByIndex(0) orelse unreachable;
    var value_index, var value_branch = value_trie.branches.items[branch_index];
    try testing.expect(value_index == 0);
    try testing.expect(value_branch.value.eql(value1));

    branch_index = value_trie.findNextByIndex(1) orelse unreachable;
    value_index, value_branch = value_trie.branches.items[branch_index];
    try testing.expect(value_index == 1);
    try testing.expect(value_branch.value.eql(value2));
}
