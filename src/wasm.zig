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
const Match = Trie.Match;
const Streams = @import("streams.zig").Streams;
pub const VarBindings = trie_module.VarBindings;
pub const VarPatternBindings = trie_module.VarPatternBindings;

// const Node = Pattern.Node;
const wasm_allocator = std.heap.wasm_allocator;
extern "js" fn log(msg_ptr: [*]const u8, msg_len: usize) void;
extern "js" fn err(msg_ptr: [*]const u8, msg_len: usize) void;

const PackedSlice = packed struct(u64) {
    ptr: u32,
    len: u32,
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
    log(ptr, len);

    trie_ptr.* = Parser.parseTrie(wasm_allocator, ptr[0..len]) catch
        panic("Error parsing trie");

    return @intFromPtr(trie_ptr);
}

/// Convenience function for directly passing a string to parse
fn parseStrMatch(
    trie: Trie,
    allocator: Allocator,
    bound: usize,
    query_str: []const u8,
) !Match {
    var query = try Parser.parse(allocator, query_str);
    defer query.deinit(allocator);
    var term_bindings = VarBindings{};
    var pattern_bindings = VarPatternBindings{};
    return trie.match(allocator, bound, &term_bindings, &pattern_bindings, query);
}

/// Caller frees.
export fn matchStr(trie_ptr: u32, query_ptr: [*]const u8, query_len: u32) u64 {
    const trie: *Trie = @ptrFromInt(trie_ptr);
    const slice = query_ptr[0..query_len];
    const result = parseStrMatch(trie.*, wasm_allocator, trie.size(), slice) catch
        panic("Match error");
    const expr = result.value orelse
        panic("No match");
    // result.key;
    const expr_string = expr.toString(wasm_allocator) catch
        panic("Writing match expr failed");

    return @bitCast(PackedSlice{
        .ptr = @intCast(@intFromPtr(expr_string.ptr)),
        .len = @intCast(expr_string.len),
    });
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

fn bufDebug(comptime fmt_str: []const u8, args: anytype) void {
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
