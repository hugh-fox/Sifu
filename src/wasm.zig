/// This module defines glue code between zig, wasm and js. The extern
/// functions here must have corresponding declarations in the importObject used
/// by WebAssembly.instantiateStreaming.
const std = @import("std");
const fmt = std.fmt;
const io = std.io;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
// for debugging with zig test --test-filter, comment this import
const verbose_errors = @import("build_options").verbose_errors;
const use_tree_sitter = @import("build_options").tree_sitter;
const Parser = @import("Parser.zig");
const ts = if (use_tree_sitter) @import("tree_sitter_parser.zig") else struct {};
const trie_module = @import("sifu/trie.zig");
const Pattern = trie_module.Pattern;
const Trie = trie_module.Trie;
const core = @import("interpreter.zig");
const Streams = @import("streams.zig").Streams;

// const Node = Pattern.Node;
const wasm_allocator = std.heap.wasm_allocator;
extern "js" fn log(msg_ptr: [*]const u8, msg_len: usize) void;
extern "js" fn err(msg_ptr: [*]const u8, msg_len: usize) void;
extern "js" fn logInt(int: usize) void;

const PackedSlice = packed struct(u64) {
    ptr: u32,
    len: u32,
};

/// The result of a match/eval, allocated on the wasm heap and returned by
/// pointer. The caller (js) reads the fields, then frees the result string and
/// this struct. `index` is the trie index the match actually occurred at.
/// `pattern` is a heap `*Pattern` clone of the result, kept so a chained
/// evaluation can be driven straight from it (via `matchPattern`/`evalPattern`)
/// without re-parsing a string; the caller frees it with `destroyPattern`.
const MatchResult = extern struct {
    ptr: u32,
    len: u32,
    index: u32,
    pattern: u32,
};

fn panic(comptime msg: []const u8) noreturn {
    err(msg.ptr, msg.len);
    @trap();
}

/// Returns an int pointer to a trie, which should be freed with
/// `Trie.destroy(wasm_allocator)`
export fn parseSliceAsTrie(ptr: [*]const u8, len: u32) u32 {
    const trie_ptr = wasm_allocator.create(Trie) catch
        panic("Allocation of trie failed");
    errdefer wasm_allocator.free(trie_ptr);

    trie_ptr.* = Parser.parseTrie(wasm_allocator, ptr[0..len]) catch
        panic("Error parsing trie");

    return @intFromPtr(trie_ptr);
}

/// Frees a trie (and all of its internal allocations) previously returned by
/// `parseSliceAsTrie`.
export fn destroyTrie(trie_ptr: u32) void {
    @as(*Trie, @ptrFromInt(trie_ptr)).destroy(wasm_allocator);
}

/// The number of indexed entries in a trie. A match/eval that reports an index
/// equal to (or greater than) this never actually fired a rule (the search ran
/// off the end), which lets the caller tell a real result from an echo.
export fn trieSize(trie_ptr: u32) u32 {
    return @intCast(@as(*Trie, @ptrFromInt(trie_ptr)).length());
}

export fn parse(ptr: [*]const u8, len: u32) u32 {
    const pattern_ptr = wasm_allocator.create(Pattern) catch
        panic("Allocation of trie failed");
    errdefer wasm_allocator.free(pattern_ptr);
    log(ptr, len);

    pattern_ptr.* = Parser.parse(wasm_allocator, ptr[0..len]) catch
        panic("Error parsing pattern");

    return @intFromPtr(pattern_ptr);
}

/// Frees a pattern previously returned by `parse` or kept in a `MatchResult`.
export fn destroyPattern(pattern_ptr: u32) void {
    @as(*Pattern, @ptrFromInt(pattern_ptr)).destroy(wasm_allocator);
}

/// Caller frees the result string, the result `pattern`, and the returned
/// `MatchResult`. Parses `query` into a pattern then delegates to
/// `matchPattern`.
export fn matchStr(trie_ptr: u32, query_ptr: [*]const u8, query_len: u32, index: u32) u32 {
    const query = wasm_allocator.create(Pattern) catch
        panic("Allocation of query failed");
    defer query.destroy(wasm_allocator);
    query.* = Parser.parse(wasm_allocator, query_ptr[0..query_len]) catch
        panic("Error parsing query");
    return matchPattern(trie_ptr, @intCast(@intFromPtr(query)), index);
}

/// Builds a heap `MatchResult` for `expr` matched at trie index `index`: a
/// freshly allocated result string, a `*Pattern` clone for chaining, and the
/// struct itself. The caller (js) frees all three.
fn makeResult(expr: Pattern, index: usize) u32 {
    const expr_string = expr.toString(wasm_allocator) catch
        panic("Writing expr failed");
    const result_pattern = expr.clone(wasm_allocator) catch
        panic("Cloning pattern failed");

    const out = wasm_allocator.create(MatchResult) catch
        panic("Allocation of match result failed");
    out.* = .{
        .ptr = @intCast(@intFromPtr(expr_string.ptr)),
        .len = @intCast(expr_string.len),
        .index = @intCast(index),
        .pattern = @intCast(@intFromPtr(result_pattern)),
    };
    return @intCast(@intFromPtr(out));
}

/// Caller frees the result string, the result `pattern`, and the returned
/// `MatchResult`. Performs one match + rewrite step on the already-parsed
/// `pattern` starting from `index`, which lets chained evaluations skip
/// re-parsing. Returns 0 when no rule matches.
export fn matchPattern(trie_ptr: u32, pattern_ptr: u32, index: u32) u32 {
    const trie: *Trie = @ptrFromInt(trie_ptr);
    const pattern: *Pattern = @ptrFromInt(pattern_ptr);
    var it = core.initMatchAt(trie.*, wasm_allocator, index, pattern.*) catch
        panic("Match error");
    defer it.deinit();
    const stepped = (it.step() catch panic("Match error")) orelse
        return 0; // no match
    return makeResult(stepped, it.ctx.index);
}

/// Caller frees the result string, the result `pattern`, and the returned
/// `MatchResult`. Parses `query` into a pattern then delegates to `evalPattern`.
export fn evalStr(trie_ptr: u32, query_ptr: [*]const u8, query_len: u32, index: u32) u32 {
    const query = wasm_allocator.create(Pattern) catch
        panic("Allocation of query failed");
    defer query.destroy(wasm_allocator);
    query.* = Parser.parse(wasm_allocator, query_ptr[0..query_len]) catch
        panic("Error parsing query");
    return evalPattern(trie_ptr, @intCast(@intFromPtr(query)), index);
}

/// Caller frees the result string, the result `pattern`, and the returned
/// `MatchResult`. Fully evaluates the already-parsed `pattern` to a fixed point
/// (a complete evaluation runs to completion, so the starting `index` is
/// unused). The reported index is the trie size, signalling "no further step".
export fn evalPattern(trie_ptr: u32, pattern_ptr: u32, index: u32) u32 {
    _ = index;
    const trie: *Trie = @ptrFromInt(trie_ptr);
    const pattern: *Pattern = @ptrFromInt(pattern_ptr);
    var result = (core.evaluateComplete(trie.*, wasm_allocator, pattern.*) catch
        panic("Eval error")) orelse return 0;
    defer result.deinit(wasm_allocator);
    return makeResult(result, trie.length());
}

/// Caller frees the result string, the result `pattern`, and the returned
/// `MatchResult`. Parses `query` then creates a stepping `iterator`.
export fn iteratorStr(trie_ptr: u32, query_ptr: [*]const u8, query_len: u32) u32 {
    const query = wasm_allocator.create(Pattern) catch
        panic("Allocation of query failed");
    defer query.destroy(wasm_allocator);
    query.* = Parser.parse(wasm_allocator, query_ptr[0..query_len]) catch
        panic("Error parsing query");
    return iterator(trie_ptr, @intCast(@intFromPtr(query)));
}

/// Creates a stepping evaluation `Iterator` over the already-parsed `pattern`,
/// returning a heap pointer the caller drives with `iteratorNext` and frees with
/// `destroyIterator`. The iterator copies `pattern`, so the caller still owns it.
export fn iterator(trie_ptr: u32, pattern_ptr: u32) u32 {
    const trie: *Trie = @ptrFromInt(trie_ptr);
    const pattern: *Pattern = @ptrFromInt(pattern_ptr);
    const it = wasm_allocator.create(core.MatchEvaluator) catch
        panic("Allocation of iterator failed");
    it.* = core.initMatch(trie.*, wasm_allocator, pattern.*) catch
        panic("Iterator init failed");
    return @intCast(@intFromPtr(it));
}

/// Advances an `iterator` by one top-level match/rewrite step, returning a
/// `MatchResult` (the rewritten expression and the trie index it matched at) or
/// 0 once evaluation has settled. The caller frees the result as for `match`.
export fn iteratorNext(iter_ptr: u32) u32 {
    const it: *core.MatchEvaluator = @ptrFromInt(iter_ptr);
    const stepped = (it.step() catch panic("Iterator step error")) orelse
        return 0; // settled
    return makeResult(stepped, it.ctx.index);
}

/// Frees an `Iterator` previously returned by `iterator`/`iteratorStr`.
export fn destroyIterator(iter_ptr: u32) void {
    const it: *core.MatchEvaluator = @ptrFromInt(iter_ptr);
    it.deinit();
    wasm_allocator.destroy(it);
}

// Allocator `len` bytes using the wasm allocator
export fn alloc(len: usize) [*]const u8 {
    const slice = std.heap.wasm_allocator.alloc(u8, len) catch
        panic("Allocation failed");
    // bufDebug("Alloc {} bytes at {*}\n", .{ slice.len, slice.ptr });
    return slice.ptr;
}

export fn free(ptr: [*]const u8, len: usize) void {
    // const ptr: [*]usize = @ptrFromInt(ptr_num);
    std.heap.wasm_allocator.free(ptr[0..len]);
}

export fn toString(trie_ptr: u32) u64 {
    const trie: *Trie = @ptrFromInt(trie_ptr);
    const string = trie.toString(wasm_allocator) catch
        panic("Allocation failed");

    return @bitCast(PackedSlice{
        .ptr = @intCast(@intFromPtr(string.ptr)),
        .len = @intCast(string.len),
    });
}

fn debug(comptime fmt_str: []const u8, args: anytype) void {
    var buff: [256]u8 = undefined;
    const str = fmt.bufPrint(&buff, fmt_str, args) catch
        unreachable;
    log(str.ptr, str.len);
}

// TODO: add errors / return len
fn writeFn(ctx: *const anyopaque, bytes: []const u8) error{}!usize {
    _ = ctx;
    log(bytes.ptr, bytes.len);
    return bytes.len;
}

/// This is packed so it can be "returned" by a js function allocating its
/// fields and returning a pointer
const InputCtx = packed struct {
    ptr: [*]const u8,
    len: usize = 0,
    pos: usize = 0,
};

// TODO: match error sets and return errors correctly
fn readFn(ctx: *InputCtx, bytes: []u8) error{OutOfMemory}!usize {
    // Check if we finished reading and need new input from js
    if (!(ctx.pos < ctx.len)) {
        // makeString(&ctx.ptr, &ctx.len);
        // bufDebug("Read {} bytes at {*}\n", .{ ctx.len, ctx.ptr });
        ctx.pos = 0;
        // Avoid continously trying to read empty strings
        if (ctx.len == 0)
            return 0;
    }
    const slice = ctx.ptr[ctx.pos..bytes.len];
    std.mem.copyForwards(u8, bytes, slice);
    // bufDebug("Copied `{s}` at {*}\n", .{ slice, bytes.ptr });
    ctx.pos += slice.len;
    return slice.len;
}

var input_ctx: InputCtx = .{ .ptr = undefined };
pub const streams: Streams = .{
    .in = .{
        .context = &input_ctx,
    },
    .out = io.Writer{
        .writeFn = writeFn,
        .context = undefined,
    },
    .err = if (verbose_errors)
        io.Writer{
            .writeFn = writeFn,
            .context = undefined,
        }
    else
        io.Writer.Discarding,
};
