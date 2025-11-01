const std = @import("std");
const Trie = @import("sifu/trie.zig").Trie;
const Pattern = @import("sifu/trie.zig").Pattern;
const Node = @import("sifu/trie.zig").Node;
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList; // Update import
const io = std.io;
const fs = std.fs;
const mem = std.mem;
const wasm = @import("wasm.zig");
const builtin = @import("builtin");
const no_os = builtin.target.os.tag == .freestanding;
const util = @import("util.zig");
const panic = util.panic;
const print = util.print;
const detect_leaks = @import("build_options").detect_leaks;
const debug_mode = @import("builtin").mode == .Debug;
const Reader = io.Reader;
const Writer = io.Writer;
const Streams = @import("streams.zig").Streams;
const streams = @import("streams.zig").streams;
const verbose_tests = @import("build_options").verbose_errors;
const parser = @import("sifu/ast.zig").parser;
const astNodeToTrie = @import("sifu/ast.zig").astNodeToTrie;
const astNodeToPattern = @import("sifu/ast.zig").astNodeToPattern;
const parseAll = @import("sifu/ast.zig").parseAll;
// TODO: merge these into just GPA, when it eventually implements wasm_allocator
// itself
var gpa = if (no_os) {} else GPA{};
const GPA = util.GPA;

pub fn main() void {
    // @compileLog(@sizeOf(Pat));
    // @compileLog(@sizeOf(Pat.Node));
    // @compileLog(@sizeOf(ArrayListUnmanaged(Pat.Node)));

    const backing_allocator = if (no_os)
        std.heap.wasm_allocator
    else
        std.heap.page_allocator;

    var arena = if (comptime detect_leaks)
        gpa
    else
        ArenaAllocator.init(backing_allocator);

    repl(arena.allocator()) catch |e|
        panic("{}", .{e});

    if (comptime detect_leaks)
        _ = gpa.detectLeaks()
    else
        arena.deinit();
}

// TODO: Implement repl/file specific behavior
fn repl(
    allocator: Allocator,
) !void {
    var trie = Trie{}; // This will be cleaned up with the arena

    while (replStep(allocator, &trie)) |_| {
        try streams.out.flush();
        try streams.err.flush();
    } else |err| switch (err) {
        error.EndOfStream => return,
        // error.StreamTooLong => return e, // TODO: handle somehow
        else => return err,
    }
}

fn replStep(
    allocator: Allocator,
    trie: *Trie,
) !?void {
    var buffer = std.Io.Writer.Allocating.init(allocator);
    buffer.clearRetainingCapacity();
    defer buffer.deinit();
    const ast_option = try parser.parseLine(
        &buffer,
        streams.in,
    );
    // const source = buffer.toOwnedSlice(allocator) catch |e|
    //     panic("Out of memory allocating source: {}", .{e});
    const ast_ptr = ast_option orelse panic("Nothing to parse\n", .{});
    defer ast_ptr.destroy();

    const pattern = astNodeToPattern(allocator, buffer.written(), ast_ptr.rootNode()) catch |e|
        panic("Error parsing stdin: {}", .{e});
    // defer pattern.deinit(allocator);

    if (pattern.isEmpty())
        return null;
    defer pattern.deinit(allocator);

    // if (comptime detect_leaks) try streams.err.print(
    //     "String Arena Allocated: {} bytes\n",
    //     .{str_arena.queryCapacity()},
    // );

    const root = pattern.root;

    // streams.out.print("replStep\n", .{}) catch unreachable;
    // streams.out.flush() catch unreachable;
    // print(
    //     "Parsed pattern {} high and {} wide: ",
    //     .{ pattern.height, pattern.root.len },
    // );

    // print("\nof types: ", .{});
    // for (root) |app| {
    //     print("{s} ", .{@tagName(app)});
    //     app.writeSExp(streams.err, 0) catch unreachable;
    //     streams.err.writeByte(' ') catch unreachable;
    // }
    print("\n", .{});

    // TODO: read a "file" from stdin first, until eof, then start eval/matching
    // until another eof.
    if (root.len > 0 and root[root.len - 1] == .arrow) {
        const key = root[0 .. root.len - 1];
        const val = root[root.len - 1].arrow;
        // TODO: calculate correct tree height
        _ = try trie.append(
            allocator,
            .{ .root = key, .height = pattern.height },
            try val.copy(allocator),
        );
    } else {
        // Free the rest of the match's string allocations. Those used in
        // rewriting must be completely copied.
        // defer str_arena.deinit();

        // If not inserting, then try to match the expression
        // TODO: put into a comptime for eval kind
        // print("Parsed ast hash: {}\n", .{ast.hash()});

        // const match = try trie.match(allocator, 0, pattern);
        // print("Matched {} nodes ", .{match.len});
        // if (match.value) |value| {
        //     try writer.print("at {}: ", .{match.index});
        //     try value.writeIndent(writer, 0);
        // } else print("null", .{});
        // try writer.writeByte('\n');

        // const result = try trie.evaluate(allocator, pattern);
        // defer result.deinit(allocator);
        // try result.write(writer);
        // try writer.writeByte('\n');

        // const result = try trie.evaluateComplete(allocator, 0, pattern);
        // _ = result;

        // if (result.value) |*value|
        //     value.deinit(allocator);
        // try result.value.write(writer);
        // try writer.writeByte('\n');

        // const index, const step = try trie.evaluateStep(allocator, 0, pattern);
        // defer step.deinit(allocator);
        // print("Match at {}, Rewrite: ", .{index});
        // try step.write(writer);
        // try writer.writeByte('\n');

        var buff = ArrayList(Node){};
        defer buff.deinit(allocator);
        const eval = try trie.evaluateSlice(allocator, pattern, &buff);
        defer if (comptime detect_leaks)
            eval.deinit(allocator)
        else
            eval.deinit(allocator); // TODO: free an arena instead

        try streams.out.print("Eval: ", .{});
        try pattern.writeIndent(streams.out, 0);
        try streams.out.writeByte('\n');
    }

    try trie.writeCanonical(streams.out);
}
