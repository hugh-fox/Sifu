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
const Streams = @import("streams.zig").Streams;
const util = @import("sifu/util.zig");
const panic = std.debug.panic;
const detect_leaks = @import("build_options").detect_leaks;
const debug_mode = @import("builtin").mode == .Debug;
const Reader = Io.Reader;
const Writer = Io.Writer;
const verbose_tests = @import("build_options").verbose_errors;
const use_tree_sitter = @import("build_options").tree_sitter;
const Parser = @import("Parser.zig");
const ts = if (use_tree_sitter) @import("tree_sitter_parser.zig") else struct {};
const debug = std.log.debug;
// @compileLog(@sizeOf(Pat));
// @compileLog(@sizeOf(Pat.Node));
// @compileLog(@sizeOf(ArrayListUnmanaged(Pat.Node)));

pub fn main(init: std.process.Init) void {
    var arena = ArenaAllocator.init(init.gpa);
    var debug_allocator = if (comptime detect_leaks)
        std.heap.DebugAllocator(.{}){}
    else {};
    const allocator = if (comptime detect_leaks)
        debug_allocator.allocator()
    else
        arena.allocator();

    const streams = Streams.init(init.io);
    repl(
        allocator,
        streams,
    ) catch |e|
        panic("{}", .{e});

    if (comptime detect_leaks)
        _ = debug_allocator.detectLeaks()
    else
        arena.deinit();
}

// TODO: Implement repl/file specific behavior
fn repl(
    allocator: Allocator,
    streams: Streams,
) !void {
    var trie = Trie{}; // This will be cleaned up with the arena
    defer trie.deinit(allocator);

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
    const pattern = if (comptime use_tree_sitter) blk: {
        const ast_option = try ts.parser.parseLine(
            &buffer,
            streams.in,
        );
        const ast_ptr = ast_option orelse panic("Empty parse\n", .{});
        defer ast_ptr.destroy();
        {
            const node = ast_ptr.rootNode();
            const text = buffer.written()[node.startByte()..node.endByte()];
            debug(
                "Parsing term node of type '{s}' and {} children with text: '{s}'",
                .{ node.kind(), node.childCount(), text },
            );
        }
        const pattern_node = try ts
            .astToPattern(allocator, buffer.written(), ast_ptr.rootNode());
        break :blk pattern_node.root[0].pattern;
    } else blk: {
        _ = streams.in.streamDelimiter(&buffer.writer, '\n') catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            else => return err,
        };
        _ = try streams.in.takeByte(); // consume the newline
        break :blk try Parser.parse(allocator, buffer.written());
    };
    // defer pattern.deinit(allocator);
    const root = pattern.root;
    debug(
        "Converted pattern {} high and {} wide, of types: ",
        .{ pattern.height, pattern.root.len },
    );
    // for (root) |app| {
    // debug("{s} ", .{@tagName(app)});
    // app.writeSExp(streams.err, 0) catch unreachable;
    // streams.err.writeByte(' ') catch unreachable;
    // }
    // pattern.debug("Pattern: {s}");

    // if (comptime detect_leaks) try debug(
    //     "String Arena Allocated: {} bytes",
    //     .{str_arena.queryCapacity()},
    // );

    // TODO: read a "file" from stdin first, until eof, then start eval/matching
    // until another eof.
    if (root.len > 0 and root[root.len - 1] == .arrow) {
        const key = root[0 .. root.len - 1];
        const val = root[root.len - 1].arrow;
        // TODO: calculate correct tree height
        _ = try trie.append(
            allocator,
            .{ .root = key, .height = pattern.height },
            // try val.copy(allocator),
            val,
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

        // var buff = ArrayList(Node).empty;
        // defer buff.deinit(allocator);
        // const result = try trie.evaluateSlice(allocator, pattern, &buff);
        debug("Eval Complete from {*}", .{trie});
        const eval = try trie.evaluateComplete(allocator, 0, pattern);
        if (eval.value) |value| {
            defer value.destroy(allocator);
            try streams.out.print("Eval at {} of length {}: ", .{ eval.index, eval.len });
            std.log.debug("WriteIndent on pattern len {}", .{value.root.len});
            try value.writeIndent(streams.out, 0);
            // for (result.root) |r| try r.writeSExp(streams.out, 0);
            try streams.out.writeByte('\n');
        } else {
            try streams.out.print("No match.\n", .{});
            return;
        }
    }

    try trie.writeIndent(streams.out, 0);
    // try trie.writeCanonical(streams.out);
}
