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

pub const HashMap = std.AutoHashMapUnmanaged(u8, Trie);
pub const GetOrPutResult = HashMap.GetOrPutResult;
const Entry = HashMap.Entry;

const IndexValue = struct {
    usize, // Canonical trie index
    []const u8,
};

pub const Bound = struct { lower: usize = 0, upper: usize };

pub const Trie = struct {
    pub const Self = @This();

    map: HashMap = .{},
    leaves: ArrayList(IndexValue) = .empty, // The values on this branch
    length: usize = 0, // The size of this Trie (including children)

    pub fn copy(self: Self, allocator: Allocator) Allocator.Error!Self {
        var result = Self{};

        // Copy the byte map entries
        var keys_iter = self.map.iterator();
        while (keys_iter.next()) |entry|
            try result.map.putNoClobber(
                allocator,
                entry.key_ptr.*,
                try entry.value_ptr.*.copy(allocator),
            );

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

    /// The opposite of `copy`. Trie owns copies of all keys stored via
    /// append, so this frees all values and internal structures.
    pub fn deinit(self: *Self, allocator: Allocator) void {
        // Recursively deinit child tries (each entry in map, once)
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.map.deinit(allocator);
        self.* = .{};
    }

    pub fn eql(self: Self, other: Self) bool {
        if (self.map.count() != other.map.count())
            return false;

        var map_iter = self.map.iterator();
        while (map_iter.next()) |entry| {
            const other_value = other.map.get(entry.key_ptr.*) orelse
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

    pub fn get(trie: Self, byte: u8) ?Self {
        return trie.map.get(byte);
    }

    pub fn getToken(trie: Self, token: []const u8) ?Self {
        var current = trie;
        for (token) |byte|
            current = current.map.get(byte) orelse
                return null;
        return current;
    }

    /// Creates the necessary branches and constant entries in the trie for
    /// key, and returns a pointer to the branch at the end of the path.
    /// While similar to a hashmap's getOrPut function, ensurePath always
    /// adds a new index, asserting that it did not already exist. There is
    /// no getOrPut equivalent for tries because they are append-only.
    ///
    /// The index must not already be in the trie.
    /// []const u8 are copied.
    /// Returns a pointer to the updated trie node. If the given key is
    /// empty (0 len), the returned constant and index are undefined.
    fn ensurePath(
        trie: *Self,
        allocator: Allocator,
        key: []const u8,
    ) !*Self {
        var next = trie;
        for (key) |byte|
            next = (try trie.map.getOrPutValue(allocator, byte, Self{})).value_ptr;
        return next;
    }

    /// Add a node to the trie by following `constants`, wrapping them into an
    /// []const u8 of Nodes.
    /// Allocations:
    /// - The value, if given, is allocated and copied recursively
    /// Freeing should be done with `destroy` or `deinit`, depending on
    /// how `self` was allocated
    ///
    /// If there isn't a value, cache the key as the value instead.
    /// Caller owns a the value.
    pub fn append(
        trie: *Self,
        allocator: Allocator,
        key: []const u8,
        value: []const u8,
    ) Allocator.Error!void {
        debug("Appending to {*}", .{trie});
        // The length of values will be the next entry index after insertion
        const index = trie.length;
        var current = trie;
        current = try current.ensurePath(allocator, key);
        debug(
            "Added value '{s}' at leaf index {} and branch index {} on trie {*}",
            .{ value, index, current.leaves.items.len, current },
        );
        try current.leaves.append(
            allocator,
            IndexValue{ index, value },
        );
        trie.length += 1;
    }

    /// Returns null if the index doesn't exist in the trie.
    pub fn getIndexValue(self: Self, index: usize) ?[]const u8 {
        var current = &self;
        current = current; // autofix
        const bound = Bound{ .lower = index, .upper = index + 1 };
        _ = bound; // autofix

        return null;
    }

    pub fn rebuildConstant(
        self: Self,
        allocator: Allocator,
        index: usize,
    ) Allocator.Error![]const u8 {
        _ = self;
        _ = index;
        var nodes = ArrayList(u8).empty;
        errdefer nodes.deinit(allocator);

        const root = try nodes.toOwnedSlice(allocator);
        var max_child: usize = 0;
        for (root) |n| max_child = @max(max_child, n.height());
        return []const u8{ .root = root, .height = max_child };
    }

    /// Append a single trie entry (one already split out from its separators).
    /// An arrow splits the entry into a constant key and its value key;
    /// without one the whole entry is both key and value. This is the single
    /// source of entry semantics, so every parser that builds a trie directly
    /// arrives at the same result.
    pub fn appendEntry(self: *Self, allocator: Allocator, entry: []const u8) Allocator.Error!void {
        if (entry.root.len == 0) return;

        var arrow_index: ?usize = null;
        for (entry.root, 0..) |node, i| {
            if (node == .arrow) {
                arrow_index = i;
                break;
            }
        }

        if (arrow_index) |ai| {
            const constant = []const u8.fromSlice(entry.root[0..ai]);
            const arrow_key = entry.root[ai].arrow;
            // The arrow wrapper added a level of height; undo it for the value.
            const value = []const u8{ .root = arrow_key.root, .height = arrow_key.height -| 1 };
            _ = try self.append(allocator, constant, value);
        } else {
            _ = try self.append(allocator, entry, entry);
        }
    }

    pub fn toString(self: Self, allocator: Allocator) ![]const u8 {
        var buff: std.ArrayList(u8) = .empty;
        errdefer buff.deinit(allocator);
        var allocating_writer = Io.Writer.Allocating
            .fromArrayList(allocator, &buff);
        try self.writeCanonical(&allocating_writer.writer);
        return allocating_writer.toOwnedSlice();
    }

    /// Writes a single entry in the trie canonically by traversing from root.
    fn writeIndexValue(
        self: *const Self,
        writer: anytype,
        index: usize,
    ) !void {
        var current = self;
        current = current; // autofix
        const index_bound = Bound{ .lower = index, .upper = index + 1 };
        _ = index_bound; // autofix
        _ = writer;
        while (true) {
            break;
        }
    }

    pub fn writeCanonical(self: Self, writer: anytype) !void {
        for (0..self.length) |index| {
            try self.writeIndexValue(writer, index);
            try writer.writeByte('\n');
        }
    }

    /// Copies this trie's values, including children, into the array at their
    /// canonical index.
    fn copyValues(self: Self, vals: [][]const u8) void {
        for (self.leaves.items) |index_value| {
            const index, const value = index_value;
            vals[index] = value;
        }
        var iter = self.map.valueIterator();
        while (iter.next()) |child| {
            child.copyValues(vals);
        }
    }

    /// Returns values in order. Caller owns the returned slice.
    pub fn values(self: Self, allocator: Allocator) Allocator.Error![][]const u8 {
        const result = try allocator.alloc([]const u8, self.length);
        errdefer allocator.free(result);

        try self.copyValues(allocator, result);

        return result;
    }

    pub const indent_increment = 2;
    pub fn writeIndent(
        self: *const Self,
        writer: anytype,
        optional_indent: ?usize,
    ) Writer.Error!void {
        try writer.writeAll("❬");
        for (self.value_branches.items) |index_value| {
            _, const branch = index_value;
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
