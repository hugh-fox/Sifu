/// This module defines glue code between zig, wasm and js. The extern
/// functions here must have corresponding declarations in the importObject used
/// by WebAssembly.instantiateStreaming.
const std = @import("std");
const panic = std.debug.panic;
const fmt = std.fmt;
const io = std.io;
const ArrayList = std.ArrayList;
// for debugging with zig test --test-filter, comment this import
const verbose_errors = @import("build_options").verbose_errors;
const Lexer = @import("sifu/Lexer.zig");
const parser = @import("sifu/parser.zig");
const Trie = @import("sifu/trie.zig").Trie;
const Level = parser.Level;
const Token = @import("sifu/syntax.zig").Token;
const wasm_allocator = std.heap.wasm_allocator;
extern "js" fn log(msg_ptr: [*]const u8, msg_len: usize) void;

const PackedSlice = packed struct(u64) {
    ptr: u32,
    len: u32,
};

export fn parseSliceAsTrie(ptr: [*]const u8, len: u32) u64 {
    var fbs = std.io.fixedBufferStream(ptr[0..len]);
    const reader = fbs.reader();
    const maybe_trie = parser.parseTrie(wasm_allocator, reader) catch |e|
        panic("Parser error: {}", .{e});

    return if (maybe_trie) |trie| blk: {
        const trie_ptr = wasm_allocator.create(Trie) catch |e|
            panic("Allocation of trie failed: {}", .{e});

        trie_ptr.* = trie;
        break :blk @intFromPtr(trie_ptr);
    } else 0;
}

/// Caller frees.
export fn matchSlice(trie_ptr: u32, query_ptr: [*]const u8, query_len: u32) u64 {
    const trie: *Trie = @ptrFromInt(trie_ptr);
    const slice = query_ptr[0..query_len];
    const result = trie.matchSlice(wasm_allocator, trie.len(), slice) catch |e|
        panic("Match error: {}", .{e});
    const expr = result.value orelse result.key;
    const expr_string = expr.toString(wasm_allocator) catch
        panic("Writing match expr failed", .{});
    return @bitCast(PackedSlice{
        .ptr = @intCast(@intFromPtr(expr_string.ptr)),
        .len = @intCast(expr_string.len),
    });
}

// Allocator `len` bytes using the wasm allocator
export fn alloc(len: usize) [*]const u8 {
    const slice = std.heap.wasm_allocator.alloc(u8, len) catch
        panic("Allocation of {} bytes failed", .{len});
    bufDebug("Alloc {} bytes at {*}\n", .{ slice.len, slice.ptr });
    return slice.ptr;
}

export fn free(ptr: [*]const u8, len: usize) void {
    // const ptr: [*]usize = @ptrFromInt(ptr_num);
    std.heap.wasm_allocator.free(ptr[0..len]);
}

pub fn bufDebug(comptime fmt_str: []const u8, args: anytype) void {
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
        bufDebug("Read {} bytes at {*}\n", .{ ctx.len, ctx.ptr });
        ctx.pos = 0;
        // Avoid continously trying to read empty strings
        if (ctx.len == 0)
            return 0;
    }
    const slice = ctx.ptr[ctx.pos..bytes.len];
    std.mem.copyForwards(u8, bytes, slice);
    bufDebug("Copied `{s}` at {*}\n", .{ slice, bytes.ptr });
    ctx.pos += slice.len;
    return slice.len;
}

pub const Streams = struct {
    var input_ctx: InputCtx = .{ .ptr = undefined };
    in: io.GenericReader(*InputCtx, error{OutOfMemory}, readFn) = .{
        .context = &input_ctx,
    },
    out: io.AnyWriter = io.AnyWriter{
        .writeFn = writeFn,
        .context = undefined,
    },
    err: io.AnyWriter = if (verbose_errors)
        std.io.AnyWriter{
            .writeFn = writeFn,
            .context = undefined,
        }
    else
        std.io.null_writer,
};
pub const streams = Streams{};
