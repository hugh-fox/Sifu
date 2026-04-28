const std = @import("std");
const Trie = @import("sifu/trie.zig").Trie;
const Pattern = @import("sifu/trie.zig").Pattern;
const Node = @import("sifu/trie.zig").Node;
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList; // Update import
const fs = std.fs;
const Io = std.Io;
const mem = std.mem;
const wasm = @import("wasm.zig");
const builtin = @import("builtin");
const no_os = builtin.target.os.tag == .freestanding;
const util = @import("util.zig");
const Streams = @import("streams.zig").Streams;
const panic = util.panic;
const detect_leaks = @import("build_options").detect_leaks;
const debug_mode = @import("builtin").mode == .Debug;
const Reader = Io.Reader;
const Writer = Io.Writer;
const verbose_tests = @import("build_options").verbose_errors;
const parser = @import("sifu/ast.zig").parser;
const astNodeToTrie = @import("sifu/ast.zig").astNodeToTrie;
const astToPattern = @import("sifu/ast.zig").astToPattern;
const parseAll = @import("sifu/ast.zig").parseAll;
// TODO: merge these into just GPA, when it eventually implements wasm_allocator
// itself
// var gpa = if (no_os) {} else GPA{};
const GPA = util.GPA;
const debug = std.log.debug;

pub fn main(init: std.process.Init) void {
    // @compileLog(@sizeOf(Pat));
    // @compileLog(@sizeOf(Pat.Node));
    // @compileLog(@sizeOf(ArrayListUnmanaged(Pat.Node)));

    // const backing_allocator = if (no_os)
    //     std.heap.wasm_allocator
    // else
    //     std.heap.page_allocator;

    // var arena = if (comptime detect_leaks)
    //     gpa
    // else
    //     ArenaAllocator.init(backing_allocator);
    var arena = ArenaAllocator.init(init.gpa);
    const streams = Streams.init(init.io);
    repl(arena.allocator(), streams) catch |e|
        panic("{}", .{e});

    if (comptime detect_leaks)
        _ = init.gpa.detectLeaks()
    else
        arena.deinit();
}

// TODO: Implement repl/file specific behavior
fn repl(
    allocator: Allocator,
    streams: Streams,
) !void {
    var trie = Trie{}; // This will be cleaned up with the arena

    while (replStep(allocator, streams, &trie)) |_| {
        try streams.out.flush();
    } else |err| switch (err) {
        error.EndOfStream => return,
        // error.StreamTooLong => return e, // TODO: handle somehow
        else => return err,
    }
}

fn replStep(
    allocator: Allocator,
    streams: Streams,
    trie: *Trie,
) !?void {
    var buffer = std.Io.Writer.Allocating.init(allocator);
    buffer.clearRetainingCapacity();
    // defer buffer.deinit(); // TODO: proper memory management
    const ast_option = try parser.parseLine(
        &buffer,
        streams.in,
    );
    // const source = buffer.toOwnedSlice(allocator) catch |e|
    //     panic("Out of memory allocating source: {}", .{e});
    const ast_ptr = ast_option orelse panic("Nothing to parse\n", .{});
    defer ast_ptr.destroy();
    {
        const node = ast_ptr.rootNode();
        const text = buffer.written()[node.startByte()..node.endByte()];
        debug(
            "Parsing term node of type '{s}' and {} children with text: '{s}'",
            .{ node.kind(), node.childCount(), text },
        );
        streams.err.writeByte('\t') catch unreachable;
        node.format(streams.err) catch unreachable;
        streams.err.writeByte('\n') catch unreachable;
        try streams.err.flush();
    }
    // Get the optional list of one or more terms
    const pattern = if (ast_ptr.rootNode().child(0)) |pattern_root|
        astToPattern(allocator, buffer.written(), pattern_root) catch |e|
            panic("Error parsing stdin: {}", .{e})
    else
        Pattern{ .root = &.{}, .height = 0 };
    // defer pattern.deinit(allocator);

    // if (comptime detect_leaks) try debug(
    //     "String Arena Allocated: {} bytes",
    //     .{str_arena.queryCapacity()},
    // );

    const root = pattern.root;

    // debug(
    //     "Converted pattern {} high and {} wide, of types: ",
    //     .{ pattern.height, pattern.root.len },
    // );
    // for (root) |app| {
    //     debug("{s} ", .{@tagName(app)});
    //     // app.writeSExp(streams.err, 0) catch unreachable;
    //     // streams.err.writeByte(' ') catch unreachable;
    // }
    pattern.debug("Pattern: {s}");

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
        // print("Parsed ast hash: {}", .{ast.hash()});

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

        var buff = ArrayList(Node).empty;
        defer buff.deinit(allocator);
        // const result = try trie.evaluateSlice(allocator, pattern, &buff);
        const eval = try trie.evaluateComplete(allocator, 0, pattern);
        // defer if (comptime detect_leaks)
        //     eval.deinit(allocator)
        // else
        //     eval.deinit(allocator); // TODO: free an arena instead

        if (eval.value) |_| {
            try streams.out.print("Eval at {} of length {}: ", .{ eval.index, eval.len });
        } else try streams.out.print("No match.\n", .{});
        const result = eval.value orelse return;

        try result.writeIndent(streams.out, 0);
        try streams.out.writeByte('\n');
    }

    try trie.writeCanonical(streams.out);
}
