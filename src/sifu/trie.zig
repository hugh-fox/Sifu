const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList; // Update import
const mem = std.mem;
const math = std.math;
const compare = math.compare;
const util = @import("../util.zig");
const parse = @import("tree_sitter_sifu").parse;
const assert = std.debug.assert;
const panic = util.panic;
const Order = math.Order;
const Wyhash = std.hash.Wyhash;
const array_hash_map = std.array_hash_map;
const AutoContext = std.array_hash_map.AutoContext;
const StringContext = std.array_hash_map.StringContext;
const ArenaAllocator = std.heap.ArenaAllocator;
const print = util.print;
const first = util.first;
const last = util.last;
const streams = util.streams;
const verbose_errors = @import("build_options").verbose_errors;
const debug_mode = @import("builtin").mode == .Debug;
const sort = std.sort;
const io = std.io;
const Reader = io.Reader;
const Writer = io.Writer;

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
            inline else => |pattern| pattern.deinit(allocator),
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
            .key => |key| mem.eql(key, other.key),
            // TODO: make exact comparisons work with single place
            // pattern in hashmaps
            // .variable => |v| Ctx.eql(undefined, v, other.variable, undefined),
            .variable => other == .variable,
            .var_pattern => other == .var_pattern,
            .trie => |trie| trie.eql(other.trie),
            inline else => |pattern| pattern.eql(other.pattern),
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
    pub fn order(self: Node, other: Node) Order {
        const ord = math.order(@intFromEnum(self), @intFromEnum(other));
        return if (ord == .eq)
            switch (self) {
                .pattern => |pattern| util.orderWith(
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

    pub fn writeSExp(
        self: Node,
        writer: *Writer,
        optional_indent: ?usize,
    ) !void {
        for (0..optional_indent orelse 0) |_|
            try writer.writeByte(' ');
        switch (self) {
            .key => |key| _ = try util.genericWrite(key, writer),
            .variable, .var_pattern => |variable| {
                _ = try util.genericWrite(variable, writer);
            },
            .trie => |trie| try trie.writeIndent(
                writer,
                optional_indent,
            ),
            .pattern => |pattern| {
                try writer.writeByte('(');
                // Ignore top level parens
                try pattern.writeIndent(writer, optional_indent);
                try writer.writeByte(')');
            },
            inline else => |pattern, tag| {
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
                // Don't write an s-exp as its redundant for ops
                try pattern.writeIndent(writer, optional_indent);
            },
        }
    }
};

pub const Pattern = struct {
    root: []const Node = &.{},
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
        // print("tag: {s}\n", .{@tagName(pattern[0])});
        try slice[0].writeSExp(writer, optional_indent);
        if (slice.len == 1) {
            return;
        } else for (slice[1 .. slice.len - 1]) |pattern| {
            // print("tag: {s}\n", .{@tagName(pattern)});
            try writer.writeByte(' ');
            try pattern.writeSExp(writer, optional_indent);
        }
        try writer.writeByte(' ');
        // print("tag: {s}\n", .{@tagName(pattern[pattern.len - 1])});
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
        var buff = std.ArrayList(u8).init(allocator);
        try self.write(buff.writer());
        return buff.toOwnedSlice();
    }

    pub fn copy(self: Pattern, allocator: Allocator) !Pattern {
        const pattern_copy = try allocator.alloc(Node, self.root.len);
        for (self.root, pattern_copy) |pattern, *node_copy|
            node_copy.* = try pattern.copy(allocator);

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
    pub fn deinit(pattern: Pattern, allocator: Allocator) void {
        for (pattern.root) |*node| {
            @constCast(node).deinit(allocator);
        }
        allocator.free(pattern.root);
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
    value: Pattern,

    pub fn node(branch: Branch) ?BranchNode {
        return switch (branch) {
            .key, .variable => |branch_node| branch_node,
            .value => null,
        };
    }

    pub fn next(self: Branch) ?*const Trie {
        switch (self) {
            .key => |branch_node| {
                return branch_node.entry.value_ptr;
            },
            .variable => |branch_node| {
                _ = branch_node;
                @panic("unimplemented"); // bind var
                // return branch_node.entry.value_ptr;
            },
            .value => |value| {
                _ = value;
                return null;
            },
        }
    }
};

const IndexBranch = struct {
    usize, // Canonical trie index
    Branch,
};

pub const BranchList = ArrayList(IndexBranch);
pub const IndexList = ArrayList(usize);

/// For directing evaluations to completion. Initially, lower bound begins
/// at 0, for the upper bound, the length of the pattern (inclusive/exclusive
/// respectively)
const Bound = struct { lower: usize = 0, upper: usize };

/// Keeps track of which vars and var_pattern are bound to what part of an
/// expression given during matching.
pub const VarBindings = std.StringHashMapUnmanaged(Node);

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
    branches: BranchList = .{},
    var_cache: IndexList = .{},
    value_cache: IndexList = .{},
    height: usize = 0, // TODO: implement height caching

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
    pub fn getIndexOrNull(self: Self, index: usize) ?Pattern {
        var current = self;
        while (current.get(index)) |next| {
            current = next.value_ptr.*;
        }
        return current.get(index);
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
    pub fn copy(self: Self, allocator: Allocator) Allocator.Error!Self {
        var result = Self{};
        var keys_iter = self.map.iterator();
        while (keys_iter.next()) |entry|
            try result.map.putNoClobber(
                allocator,
                entry.key_ptr.*,
                try entry.value_ptr.*.copy(allocator),
            );

        result = try self.copy(allocator);
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
        defer self.map.deinit(allocator);
        self.branches.deinit(allocator);
        self.var_cache.deinit(allocator);
        self.value_cache.deinit(allocator);
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit(allocator);
        }
        defer self.deinit(allocator);
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
        var vars_iter = self.valuess.vars.iterator();
        while (vars_iter.next()) |*entry| {
            hasher.update(entry.value_ptr.*);
        }
        var values_iter = self.valuess.values.iterator();
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
    /// sub-tries and if their debruijn variables are equal. The tries
    /// are assumed to be in debruijn form already.
    pub fn eql(self: Self, other: Self) bool {
        if (self.map.count() != other.map.count() or
            self.entries.len !=
                other.value.entries.len or
            self.entries.len != other.value.entries.len)
            return false;
        var map_iter = self.map.iterator();
        var other_map_iter = other.map.iterator();
        while (map_iter.next()) |entry| {
            const other_entry = other_map_iter.next() orelse
                return false;
            if (!(mem.eql(u8, entry.key_ptr.*, other_entry.key_ptr.*)) or
                entry.value_ptr != other_entry.value_ptr)
                return false;
        }
        var value_iter = self.iterator();
        var other_value_iter = other.value.iterator();
        while (value_iter.next()) |entry| {
            const other_entry = other_value_iter.next() orelse
                return false;
            const value = entry.value_ptr.*;
            const other_value = other_entry.value_ptr.*;
            if (entry.key_ptr.* != other_entry.key_ptr.* or
                !value.eql(other_value))
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
    /// the entire `pattern` is a prefix, a pointer to the last pat will be
    /// returned instead of null.
    /// `trie` isn't modified.
    pub fn getTerm(
        trie: Self,
        node: Node,
    ) ?Self {
        return switch (node) {
            .key => |key| trie.map.get(key),
            .variable => |variable| trie.vars.get(variable),
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
            .getOrPutValue(allocator, key, Self{});
        const next = entry.value_ptr;
        try trie.branches.append(
            allocator,
            IndexBranch{ index, .{
                .key = .{
                    .entry = entry,
                    .next_index = next.branches.items.len,
                },
            } },
        );
        return entry.value_ptr;
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
                const next = try trie.getOrPutKey(allocator, index, key);
                break :blk next;
            },
            .variable,
            .var_pattern,
            => |variable| try trie.getOrPutVar(allocator, index, variable),
            .pattern => |sub_pat| blk: {
                var next = trie;
                next = try next.getOrPutKey(allocator, index, "(");
                next = try next.ensurePath(allocator, index, sub_pat);
                next = try next.getOrPutKey(allocator, index, ")");
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
        for (pattern.root) |node|
            current = try current.ensurePathTerm(allocator, index, node);
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
        for (root, key) |*node, token|
            node.* = Node.ofKey(token);

        return self.append(allocator, Pattern{ .root = root }, value);
    }

    // TODO: change return type to void
    pub fn append(
        trie: *Self,
        allocator: Allocator,
        key: Pattern,
        optional_value: ?Pattern,
    ) Allocator.Error!*Self {
        // The length of values will be the next entry index after insertion
        const index = trie.size();
        var current = trie;
        current = try current.ensurePath(allocator, index, key);
        // If there isn't a value, use the key as the value instead
        const value = optional_value orelse
            try key.copy(allocator);
        try current.value_cache.append(
            allocator,
            current.branches.items.len,
        );
        try current.branches.append(
            allocator,
            IndexBranch{ index, .{ .value = value } },
        );
        print("Value cache: {any}\n", .{current.value_cache.items});
        return current;
    }

    /// A partial or complete match of a given pattern against a trie.
    const Match = struct {
        key: Pattern = .{}, // The pattern that was attempted to match
        value: ?Pattern = null,
        node_ptr: *const Trie,
        index: usize = 0,
        len: usize = 0, // For partial matches
        bindings: VarBindings = .{}, // Bound variables

        /// Node entries are just references, so they aren't freed by this
        /// function.
        pub fn deinit(self: *Match, allocator: Allocator) void {
            defer self.bindings.deinit(allocator);
        }
    };

    /// A partial or complete sequence of matches of a pattern against a trie.
    const Eval = struct {
        value: ?Pattern = null,
        index: usize = 0,
        len: usize = 0, // For partial matches
    };

    // Find the index of the next branch starting from bound.
    fn findNextByIndex(self: Self, bound: usize) ?usize {
        const branches = self.branches;

        // To compare by bound with other branches, it must be put into a Branch
        // first. Its kind can be undefined since it will never be returned.
        // const elem = IndexBranch{ bound, undefined };
        const index = sort.lowerBound(
            IndexBranch,
            branches.items,
            .{ bound, branches },
            struct {
                fn lessThan(
                    ctx: @TypeOf(.{ bound, branches }),
                    cmp_branch: IndexBranch,
                ) Order {
                    const b, _ = ctx;
                    const i, _ = cmp_branch;
                    // print("Compare branches: {} < {}\n", .{ lhs_index, rhs_index });
                    return math.order(b, i);
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

    fn findNextByCache(
        self: Self,
        branches_bound: usize,
        cache: []const usize,
    ) ?IndexBranch {
        print("Cache: {any}\n", .{cache});
        const cache_index = sort.lowerBound(
            usize,
            cache,
            .{ branches_bound, self.branches.items },
            struct {
                fn lessThan(
                    ctx: @TypeOf(.{ branches_bound, self.branches.items }),
                    cmp_index: usize,
                ) Order {
                    const bound, const branches = ctx;
                    const index, _ = branches[cmp_index];
                    print("Compare cached: {} < {}\n", .{ bound, index });
                    return math.order(bound, index);
                }
            }.lessThan,
        );
        // No index found if lowerBound returned the length of branches
        return if (cache_index < cache.len)
            self.branches.items[cache[cache_index]]
        else
            null;
    }

    /// Finds the next minimum value at this node by index.
    fn findNextValue(self: Self, bound: usize) ?IndexBranch {
        const branches_bound = self.findNextByIndex(bound) orelse
            return null;
        return self.findNextByCache(branches_bound, self.value_cache.items);
    }

    /// Finds the next minimum variable at this node by index.
    fn findNextVar(self: Self, bound: usize) ?IndexBranch {
        return self.findNextByCache(bound, self.var_cache.items);
    }

    // Finds the next minimum variable or value.
    fn findNext(self: Self, bound: usize) ?IndexBranch {
        // Find the next var and value efficiently using their caches
        const value_branch = self.findNextValue(bound) orelse
            return self.findNextVar(bound);
        // Check if there is a need to search for a var before doing so
        if (value_branch[0] == bound)
            return value_branch;
        const var_branch = self.findNextVar(bound) orelse
            return value_branch;
        return switch (math.order(value_branch[0], var_branch[0])) {
            .lt => value_branch,
            .eq => panic("Duplicate indices found", .{}),
            .gt => var_branch,
        };
    }
    // // If the index is unchanged, its trivially the minimum match. If the
    // // next index is a variable or value its always the next branch.

    /// The first half of evaluation. The variables in the node match
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
    fn matchTerm(
        self: *const Self,
        allocator: Allocator,
        bound: usize,
        node: Node,
    ) Allocator.Error!?IndexBranch {
        print("Branching `", .{});
        node.writeSExp(streams.err, null) catch unreachable;
        print("`, ", .{});
        //  orelse {
        //     // Instead of backtracking, simply restart the match
        //     // from the beginning but with an incremented index.
        //     return null;
        // };
        switch (node) {
            // The branch a key points to must be within bound
            .key => |_| if (self.map.getEntry(node.key)) |key_entry| {
                print("exactly: {s}\n", .{node.key});
                // TODO merge with backtracking code as this lookahead will
                // be redundant
                // print("Finding next by index orelse candidate\n", .{});
                // TODO: use next index saved in match trie instead of searching
                // TODO: check if this pointer is really memory safe
                const key_candidate_index = key_entry.value_ptr
                    .findNextByIndex(bound) orelse
                    return self.findNext(bound);
                const key_index, _ =
                    self.branches.items[key_candidate_index];
                // print("Finding candidate orelse next index\n", .{});
                const key_branch = IndexBranch{
                    key_index, .{
                        .key = .{
                            .entry = key_entry,
                            .next_index = key_candidate_index,
                        },
                    },
                };
                const candidate = self.findNext(bound) orelse
                    return key_branch;
                const candidate_index, _ = candidate;
                print(
                    "Is the candidate less than matched key's index? {}\n",
                    .{candidate_index < key_index},
                );
                return if (candidate_index < key_index)
                    candidate
                else
                    key_branch;
            } else {
                print("but key '{s}' not found in map: {s}\n", .{ node.key, "{" });
                if (debug_mode) {
                    writeEntries(self.map, streams.err, 0) catch
                        unreachable;
                    streams.err.writeAll("}\n") catch unreachable;
                }
                // First try any available branches, then let `match` try
                // values.
                print("returning find candidate\n", .{});
                return self.findNext(bound);
            },
            .variable, .var_pattern => {
                // // If a previous var was bound, check that the
                // // current key matches it
                // if (var_result.found_existing) {
                //     if (var_result.value_ptr.*.eql(node)) {
                //         print("found equal existing var match\n", .{});
                //     } else {
                //         print("found existing non-equal var matching\n", .{});
                //     }
                // } else {
                //     print("New Var: {s}\n", .{var_result.key_ptr.*});
                //     var_result.value_ptr.* = node;
                // }
            },
            .infix => @panic("unimplemented"), // |infix| {},
            .pattern => |pattern| {
                print("sub-pattern\n", .{});
                // Follow the sub-pattern in the trie
                var current = self;
                var index, var branch = try self.matchTerm(allocator, bound, Node{ .key = "(" }) orelse
                    return null;
                current = branch.next() orelse
                    return null;
                print("sub-pattern match\n", .{});
                current = (try current.match(allocator, index, pattern)).node_ptr;
                index, branch = try current.matchTerm(allocator, index, Node{ .key = ")" }) orelse
                    return .{ index, branch };
                current = branch.next() orelse
                    return null;
                print("sub-pattern matched\n", .{});
            },
            .trie => @panic("unimplemented"), // |trie| {},
            else => @panic("unimplemented"),
        }
        return null;
    }

    /// Finds the lowest bound index that also matches pattern. Returns its
    /// value as well as the length of the prefix of pattern matched (which
    /// is equal to the pattern's length if all nodes matched at least once).
    /// Returns the value of `self` if given trie if pattern is empty (base
    /// case).
    /// All possible valid indices for a key will be tried, up until bound.
    /// Minimum indices are always prioritized. For example, if 'A' and
    /// 'A B' are in the trie at indices 0 and 1 respectively, matching 'A B'
    /// with bound 0 will match at 0 partially instead of 'A B' at 1 fully.
    pub fn match(
        self: *const Self,
        allocator: Allocator,
        bound: usize,
        pattern: Pattern,
    ) Allocator.Error!Match {
        var current = self;
        var index: usize = bound;
        var result = Match{ .node_ptr = self };
        while (result.len < pattern.root.len) : (result.len += 1) {
            const node = pattern.root[result.len];
            print("Find next by index from bound: {}\n", .{index});
            print("Branch list: [ ", .{});
            for (current.branches.items) |index_branch| {
                print("{} ", .{index_branch[0]});
            }
            print("]\n", .{});
            index, const branch = try current.matchTerm(allocator, index, node) orelse
                break;
            print("at index {}, ", .{index});
            switch (branch) {
                .key => |branch_node| {
                    current = branch_node.entry.value_ptr;
                },
                .variable => |branch_node| {
                    current = branch_node.entry.value_ptr;
                    @panic("unimplemented"); // bind var
                },
                .value => |value| {
                    print("Value reached, continuing\n", .{});
                    result.value = value;
                    @panic("need to backtrack instead of continue here");
                    // continue;
                },
            }
        }
        if (current.findNextValue(index)) |value| {
            index, const branch = value;
            print("Matches exhausted, but value found.\n", .{});
            result.value = branch.value;
            result.index = index;
        } else print(
            "No match in range [{}, {}], after {} nodes followed\n",
            .{ bound, index, result.len },
        );
        result.node_ptr = current;
        return result;
    }

    pub fn matchStr(
        self: Self,
        allocator: Allocator,
        bound: usize,
        query_str: []const u8,
    ) !Match {
        var fbs = std.io.fixedBufferStream(query_str);
        var arena, const query = try parse(allocator, fbs.reader());
        defer arena.deinit();
        return self.match(allocator, bound, query);
    }

    /// The second half of an evaluation step. Rewrites all variable
    /// captures into the matched expression. Copies any variables in node
    /// if they are keys in bindings with their values. If there are no
    /// matches in bindings, this functions is equivalent to copy. The
    /// result should be freed shallowly with ArrayList.deinit.
    /// This function takes an arraylist instead of an allocator, which is
    /// assumed empty and returned empty.
    pub fn rewrite(
        allocator: Allocator,
        pattern: Pattern,
        bindings: VarBindings,
        result: *ArrayList(Node),
    ) Allocator.Error!Pattern {
        for (pattern.root) |node| switch (node) {
            .key => |key| try result.append(allocator, Node.ofKey(key)),
            .variable => |variable| {
                print("Var get: ", .{});
                if (bindings.get(variable)) |var_node|
                    var_node.writeSExp(streams.err, null) catch unreachable
                else
                    print("null", .{});
                print("\n", .{});
                try result.append(
                    allocator,
                    bindings.get(variable) orelse
                        node,
                );
            },
            .var_pattern => |var_pattern| {
                print("Var pattern get: ", .{});
                if (bindings.get(var_pattern)) |var_node|
                    var_node.writeSExp(streams.err, null) catch unreachable
                else
                    print("null", .{});
                print("\n", .{});
                if (bindings.get(var_pattern)) |sub_pattern| {
                    // TODO: calculate correct height with sub_pattern's
                    // height
                    for (sub_pattern.pattern.root) |sub_node|
                        try result.append(allocator, sub_node);
                } else try result.append(allocator, node);
            },
            inline .pattern, .arrow, .match, .list, .infix => |nested, tag| {
                try result.append(allocator, @unionInit(
                    Node,
                    @tagName(tag),
                    try rewrite(allocator, nested, bindings, result),
                ));
            },
            else => panic("unimplemented", .{}),
        };
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
            print("Matching from bounds [{},{})\n", .{ bound.lower, bound.upper });
            matched = try self.match(allocator, bound.lower, pattern);
            defer matched.deinit(allocator);
            print(
                "Match result: {} of {} pattern nodes at index {}, ",
                .{ matched.len, pattern.root.len, matched.index },
            );
            if (matched.value) |value| {
                print("matched value: ", .{});
                value.write(streams.err) catch unreachable;
                print("\n", .{});
                return try rewrite(allocator, value, matched.bindings, result);
            } else print("but no match", .{});
            print("\n", .{});
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
        self: *Self,
        allocator: Allocator,
        bound: usize,
        pattern: Pattern,
    ) Allocator.Error!Eval {
        var buffer = ArrayList(Node){};
        defer buffer.deinit(allocator); // shouldn't be necessary, but just in case
        var matched: Match = .{ .node_ptr = self };
        var index: usize = bound;
        var current: Pattern = pattern;
        while (index < self.size()) : (matched.deinit(allocator)) {
            matched = try self.match(allocator, index, current);
            index = matched.index + 1;
            if (matched.len != pattern.root.len) {
                print("No complete match, skipping index {}.\n", .{matched.index});
                // Evaluate nested patterns that failed to match
                // TODO: replace recursion with a continue
                // switch (pattern) {
                //     inline .pattern, .match, .arrow, .list => |slice, tag|
                //     // Recursively eval nested list but preserve node type
                //     @unionInit(
                //         Node,
                //         @tagName(tag),
                //         // Sub-expressions start over from 0 (structural
                //         // recursion)
                //         try self.evaluateComplete(allocator, 0, slice),
                //     ),
                //     else => try pattern.copy(allocator),
                // }

            }
            print("vars in map: {}\n", .{matched.bindings.size});
            const slice = .{};
            if (matched.value) |next| {
                // Prevent infinite recursion at this index. Recursion
                // through other indices will be terminated by match index
                // shrinking.
                if (slice.len == next.root.len)
                    for (slice, next.root) |trie, next_trie| {
                        // check if the same trie's shape could be matched
                        // TODO: use a trie match function here instead of eql
                        if (!trie.asEmpty().eql(next_trie))
                            break;
                    } else break; // Don't evaluate the same trie
                print("Eval matched {}: ", .{next.root.len});
                next.write(streams.err) catch unreachable;
                streams.err.writeByte('\n') catch unreachable;
                current =
                    try rewrite(allocator, next, matched.bindings, &buffer);
            } else {
                print("Match, but no value\n", .{});
                break;
            }
        }
        const eval = Eval{
            .value = current,
            .index = matched.index,
            .len = matched.len,
        };
        print("Evaluated {} nodes at index {}:\n", .{ eval.len, eval.index });
        if (eval.value) |value| {
            value.write(streams.err) catch unreachable;
            streams.err.writeByte(' ') catch unreachable;
        }
        streams.err.writeByte('\n') catch unreachable;
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
    //             print("No match, skipping index {}.\n", .{index});
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
    //         print("vars in map: {}\n", .{eval.bindings.entries.len});
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
    //             print("Eval matched {s}: ", .{@tagName(next.*)});
    //             next.write(streams.err) catch unreachable;
    //             streams.err.writeByte('\n') catch unreachable;
    //             const rewritten =
    //                 try rewrite(next.pattern, eval.bindings, buffer);
    //             defer Node.ofPattern(rewritten).deinit(allocator);
    //             const sub_eval = try self.evaluate(allocator, rewritten);
    //             defer allocator.free(sub_eval);
    //             try result.appendSlice(allocator, sub_eval);
    //         } else {
    //             try result.appendSlice(allocator, slice);
    //             print("Match, but no value\n", .{});
    //         }
    //         index += eval.len;
    //     }
    //     print("Eval: ", .{});
    //     for (result.items) |trie| {
    //         print("{s} ", .{@tagName(trie)});
    //         trie.writeSExp(streams.err, 0) catch unreachable;
    //         streams.err.writeByte(' ') catch unreachable;
    //     }
    //     streams.err.writeByte('\n') catch unreachable;
    //     return result.toOwnedSlice();
    // }

    pub fn size(self: Self) usize {
        return self.branches.items.len;
    }

    /// Caller owns the slice, but not the patterns in it.
    fn setKeys(
        self: Self,
        allocator: Allocator,
        result: []ArrayList([]const u8),
    ) !void {
        for (self.keys) |key| {
            try result[key.index].appendSlice(allocator, key.name + ' ');
        }
        for (self.keys.items) |entry|
            entry.next.setKeys(result);
        for (self.vars.items) |entry|
            entry.next.setKeys(result);
    }

    /// Caller owns the slice, but not the patterns in it.
    fn setValues(self: Self, result: []Pattern) void {
        for (self.values) |value| {
            result[value.index] = value.pattern;
        }
        for (self.keys.items) |entry|
            entry.next.setValues(result);
        for (self.vars.items) |entry|
            entry.next.setValues(result);
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

            // if (comptime debug_mode)
            //     try writer.print("[{}] ", .{index});
        }
        try writer.writeAll("-> ");
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
        self: Self,
        writer: anytype,
        optional_indent: ?usize,
    ) Writer.Error!void {
        try writer.writeAll("❬");
        for (self.value_cache.items) |value_index| {
            _, const branch = self.branches.items[value_index];
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

    var trie1 = Trie{};
    var trie2 = Trie{};

    const key = Pattern{ .root = &.{
        .{ .key = "Aa" },
        .{ .key = "Bb" },
    } };
    const ptr1 = try trie1.append(allocator, key, Pattern{
        .root = &.{.{ .key = "Value" }},
    });
    const ptr2 = try trie2.append(allocator, key, Pattern{
        .root = &.{.{ .key = "Value" }},
    });

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

    const val = Pattern{ .root = &.{.{ .key = "Val" }} };
    _ = try trie.append(
        testing.allocator,
        Pattern{ .root = &.{
            Node{ .key = "1" },
            Node{ .key = "2" },
            Node{ .key = "3" },
        } },
        val,
    );
    try testing.expect(trie.map.contains("1"));
    try testing.expect(trie.map.get("1").?.map.contains("2"));
    try testing.expectEqualDeep(trie.getIndex(0), val);
}

test "Memory: simple" {
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    const ptr1 = try trie.append(
        testing.allocator,
        Pattern{ .root = &.{} },
        Pattern{ .root = &.{.{ .key = "123" }} },
    );
    const ptr2 = try trie.append(
        testing.allocator,
        Pattern{ .root = &.{ .{ .key = "01" }, .{ .key = "12" } } },
        Pattern{ .root = &.{.{ .key = "123" }} },
    );
    const ptr3 = try trie.append(
        testing.allocator,
        Pattern{ .root = &.{ .{ .key = "01" }, .{ .key = "12" } } },
        Pattern{ .root = &.{.{ .key = "234" }} },
    );

    try testing.expect(ptr1 != ptr2);
    try testing.expectEqual(ptr2, ptr3);
}

test "Behavior: vars" {
    var nested_trie = try Trie.create(testing.allocator);
    defer nested_trie.destroy(testing.allocator);

    _ = try nested_trie.appendKey(
        testing.allocator,
        &.{
            "cherry",
            "blossom",
            "tree",
        },
        Pattern{ .root = &.{.{ .key = "Beautiful" }} },
    );
}

test "Behavior: nesting" {
    @panic("unimplemented");
}

test "Behavior: equal variables" {
    @panic("unimplemented");
}

test "Behavior: equal keys, different indices" {
    @panic("unimplemented");
}

test "Behavior: equal keys, different structure" {
    @panic("unimplemented");
}
