const std = @import("std");
const sifu = @import("sifu.zig");
const Trie = @import("sifu/trie.zig").Trie;
// const Pattern = @import("sifu/pattern.zig").Pattern;
const Pattern = @import("sifu/trie.zig").Pattern;
const Node = @import("sifu/trie.zig").Node;
const Lexer = @import("sifu/Lexer.zig");
const syntax = @import("sifu/syntax.zig");
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
const parseFile = @import("sifu/parser.zig").parseFile;
const astNodeToTrie = @import("sifu/ast.zig").astNodeToTrie;
// TODO: merge these into just GPA, when it eventually implements wasm_allocator
// itself
var gpa = if (no_os) {} else GPA{};
const GPA = util.GPA;

const ts = @import("tree-sitter");
extern fn tree_sitter_zig() callconv(.c) *ts.Language;

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

    // repl(arena.allocator()) catch |e|
    //     panic("{}", .{e});

    var lexer = Lexer.init(arena.allocator(), streams.in);
    defer lexer.deinit();

    const tokens = lexer.readAll() catch |e| {
        panic("Error lexing stdin: {}", .{e});
    };
    var ast = parseFile(arena.allocator(), tokens) catch |e| {
        panic("Error parsing stdin: {}", .{e});
    };
    defer ast.deinit(arena.allocator());

    // const trie = try astNodeToTrie(arena.allocator(), ast);
    // try trie.writeCanonical(streams.out);

    if (comptime detect_leaks)
        _ = gpa.detectLeaks()
    else
        arena.deinit();
}

// // TODO: Implement repl/file specific behavior
// fn repl(
//     allocator: Allocator,
// ) !void {
//     var trie = Trie{}; // This will be cleaned up with the arena

//     while (replStep(&trie, allocator)) |_| {
//         try streams.out.flush();
//         try streams.err.flush();
//     } else |err| switch (err) {
//         error.EndOfStream => return,
//         // error.StreamTooLong => return e, // TODO: handle somehow
//         else => return err,
//     }
// }

// fn replStep(
//     trie: *Trie,
//     allocator: Allocator,
// ) !?void {
//     var str_arena, const pattern = try Parser.parse(allocator, streams.in);

//     if (pattern.isEmpty())
//         return null;
//     defer pattern.deinit(allocator);

//     // if (comptime detect_leaks) try streams.err.print(
//     //     "String Arena Allocated: {} bytes\n",
//     //     .{str_arena.queryCapacity()},
//     // );

//     const root = pattern.root;

//     // streams.out.print("replStep\n", .{}) catch unreachable;
//     // streams.out.flush() catch unreachable;
//     // print(
//     //     "Parsed pattern {} high and {} wide: ",
//     //     .{ pattern.height, pattern.root.len },
//     // );

//     // print("\nof types: ", .{});
//     // for (root) |app| {
//     //     print("{s} ", .{@tagName(app)});
//     //     app.writeSExp(streams.err, 0) catch unreachable;
//     //     streams.err.writeByte(' ') catch unreachable;
//     // }
//     print("\n", .{});

//     // TODO: read a "file" from stdin first, until eof, then start eval/matching
//     // until another eof.
//     if (root.len > 0 and root[root.len - 1] == .arrow) {
//         const key = root[0 .. root.len - 1];
//         const val = root[root.len - 1].arrow;
//         // TODO: calculate correct tree height
//         _ = try trie.append(
//             allocator,
//             .{ .root = key, .height = pattern.height },
//             try val.copy(allocator),
//         );
//     } else {
//         // Free the rest of the match's string allocations. Those used in
//         // rewriting must be completely copied.
//         defer str_arena.deinit();

//         // If not inserting, then try to match the expression
//         // TODO: put into a comptime for eval kind
//         // print("Parsed ast hash: {}\n", .{ast.hash()});
//         // TODO: change to get by index or something
//         // if (trie.get(pattern)) |got| {
//         //     print("Got: ", .{});
//         //     try got.write(streams.err);
//         //     print("\n", .{});
//         // } else print("Got null\n", .{});

//         // const match = try trie.match(allocator, 0, pattern);
//         // print("Matched {} nodes ", .{match.len});
//         // if (match.value) |value| {
//         //     try writer.print("at {}: ", .{match.index});
//         //     try value.writeIndent(writer, 0);
//         // } else print("null", .{});
//         // try writer.writeByte('\n');

//         // const result = try trie.evaluate(allocator, pattern);
//         // defer result.deinit(allocator);
//         // try result.write(writer);
//         // try writer.writeByte('\n');

//         // const result = try trie.evaluateComplete(allocator, 0, pattern);
//         // _ = result;

//         // if (result.value) |*value|
//         //     value.deinit(allocator);
//         // try result.value.write(writer);
//         // try writer.writeByte('\n');

//         // const index, const step = try trie.evaluateStep(allocator, 0, pattern);
//         // defer step.deinit(allocator);
//         // print("Match at {}, Rewrite: ", .{index});
//         // try step.write(writer);
//         // try writer.writeByte('\n');

//         var buff = ArrayList(Node){};
//         defer buff.deinit(allocator);
//         const eval = try trie.evaluateSlice(allocator, pattern, &buff);
//         defer if (comptime detect_leaks)
//             eval.deinit(allocator)
//         else
//             eval.deinit(allocator); // TODO: free an arena instead

//         try streams.out.print("Eval: ", .{});
//         try pattern.writeIndent(streams.out, 0);
//         try streams.out.writeByte('\n');
//     }

//     try trie.writeCanonical(streams.out);
// }
