const std = @import("std");
const sifu = @import("sifu.zig");
const Pat = @import("sifu/ast.zig").Pat;
const Ast = Pat.Node;
const syntax = @import("sifu/syntax.zig");
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const parse = @import("sifu/parser.zig").parse;
const streams = @import("streams.zig").streams;
const io = std.io;
const mem = std.mem;
const wasm = @import("wasm.zig");
const builtin = @import("builtin");
const no_os = builtin.target.os.tag == .freestanding;
const util = @import("util.zig");
const panic = util.panic;
const print = util.print;
const detect_leaks = @import("build_options").detect_leaks;
// TODO: merge these into just GPA, when it eventually implements wasm_allocator
// itself
var gpa = if (no_os) undefined else GPA{};
const GPA = util.GPA;

pub fn main() void {
    // @compileLog(@sizeOf(Pat));
    // @compileLog(@sizeOf(Pat.Node));
    // @compileLog(@sizeOf(ArrayListUnmanaged(Pat.Node)));

    const allocator = if (no_os)
        std.heap.wasm_allocator
    else
        gpa.allocator();

    repl(allocator) catch |e|
        panic("{}", .{e});

    if (comptime !no_os)
        _ = gpa.detectLeaks();
}

// TODO: Implement repl/file specific behavior
fn repl(
    allocator: Allocator,
) !void {
    var buff_writer_out = io.bufferedWriter(streams.out);
    const buff_out = buff_writer_out.writer();
    var pattern = Pat{};
    defer pattern.deinit(allocator);

    while (replStep(&pattern, allocator, buff_out)) |_| {
        try buff_writer_out.flush();
        if (comptime !no_os) try streams.err.print(
            "Pattern Allocated: {}\n",
            .{gpa.total_requested_bytes},
        );
    } else |err| switch (err) {
        error.EndOfStream => return {},
        // error.StreamTooLong => return e, // TODO: handle somehow
        else => return err,
    }
}

fn replStep(
    pattern: *Pat,
    allocator: Allocator,
    writer: anytype,
) !?void {
    var tree = try parse(allocator, streams.in) orelse
        return error.EndOfStream;
    defer tree.deinit();

    const apps = tree.root;
    const ast = Ast.ofApps(apps);

    print(
        "Parsed apps {} high and {} wide: ",
        .{ tree.height, apps.len },
    );
    try ast.write(streams.err);
    print("\nof types: ", .{});
    for (apps) |app| {
        print("{s} ", .{@tagName(app)});
        app.writeSExp(streams.err, 0) catch unreachable;
        streams.err.writeByte(' ') catch unreachable;
    }
    print("\n", .{});

    // for (fbs.getWritten()) |char| {
    // escape (from pressing alt+enter in most shells)
    // if (char == 0x1b) {}
    // }
    // TODO: put with shell command like @put instead of special
    // casing a top level insert
    if (apps.len > 0 and apps[apps.len - 1] == .arrow) {
        const key = apps[0 .. apps.len - 1];
        const val = Ast.ofApps(apps[apps.len - 1].arrow);
        // If not inserting, then try to match the expression
        try pattern.put(allocator, key, val);
    } else {
        // TODO: put into a comptime for eval kind
        // // print("Parsed ast hash: {}\n", .{ast.hash()});
        // if (repl_pat.get(ast.apps)) |got| {
        //     print("Got: ", .{});
        //     try got.write(streams.err);
        //     print("\n", .{});
        // } else print("Got null\n", .{});

        const step = try pattern.evaluateStep(allocator, apps);
        defer Ast.ofApps(step).deinit(allocator);
        print("Match Rewrite: ", .{});
        try Ast.ofApps(step).write(writer);
        try writer.writeByte('\n');

        // const eval = try pattern.evaluate(allocator, apps);
        // defer if (comptime detect_leaks)
        //     Ast.ofApps(eval).deinit(allocator)
        // else
        //     eval.deinit();
        // try writer.print("Eval: ", .{});
        // for (eval) |app| {
        //     try app.writeSExp(writer, 0);
        //     try writer.writeByte(' ');
        // }
        // try writer.writeByte('\n');
    }
    try pattern.pretty(writer);
}
