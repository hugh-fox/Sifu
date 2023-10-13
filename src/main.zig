const std = @import("std");
const sifu = @import("sifu.zig");
const Pat = @import("sifu/ast.zig").Pat;
const Ast = Pat.Node;
const syntax = @import("sifu/syntax.zig");
const interpreter = @import("sifu/interpreter.zig");
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const Lexer = @import("sifu/Lexer.zig");
const parse = @import("sifu/parser.zig").parse;
const io = std.io;
const fs = std.fs;
const log = std.log.scoped(.sifu_cli);
const mem = std.mem;
const print = std.debug.print;

pub fn main() !void {
    // var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    // defer _ = gpa_alloc.deinit();
    // const gpa = gpa_alloc.allocator();
    var arena = ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const stdin = io.getStdIn().reader();
    const stdout = io.getStdOut().writer();
    var buff_writer = io.bufferedWriter(stdout);
    const buff_stdout = buff_writer.writer();
    const buff_size = 4096;
    var buff: [buff_size]u8 = undefined;
    var fbs = io.fixedBufferStream(&buff);

    // TODO: Fix repl specific behavior
    //    - restart parsing after 2 newlines
    //    - exit on EOF
    var lexer = Lexer.init(allocator);
    var repl_pat = Pat{};
    while (stdin.streamUntilDelimiter(fbs.writer(), '\n', fbs.buffer.len)) |_| {
        var fbs_reader = io.fixedBufferStream(fbs.getWritten());
        for (fbs_reader.getWritten()) |char| {
            // escape (from pressing alt+enter in most terminals)
            if (char == 0x1b) {}
        }
        const ast = try parse(allocator, &lexer, fbs_reader.reader()) orelse
            // Match the empty apps for just a newline
            if ((repl_pat.matchExactPrefix(&.{})).pat_ptr.node) |node|
            node.*
        else
            Ast.ofApps(&.{});

        // try ast.write(buff_stdout);
        // _ = try buff_writer.write("\n");
        // for (ast.apps) |debug_ast|
        //     try debug_ast.write(buff_stdout);

        const apps = ast.apps;
        if (ast.apps.len > 0) blk: {
            switch (apps[0]) {
                .key => |key| if (mem.eql(u8, key.lit, "->")) {
                    var updated = false;
                    _ = updated;
                    const result = try repl_pat.insert(
                        allocator,
                        apps[1].apps,
                        try Ast.createApps(allocator, apps[2..]),
                    );
                    _ = result;

                    // try buff_stdout.print("{}\n", .{updated});
                    break :blk;
                },
                else => {},
            }
            // If not inserting, then try to match the expression
            if (repl_pat.match(apps)) |matched| {
                try matched.write(buff_stdout);
                _ = try buff_writer.write("\n");
            } else print("No match\n", .{});
        }

        try repl_pat.write(buff_stdout);
        try buff_writer.flush();
        fbs.reset();
    } else |e| switch (e) {
        error.EndOfStream => return {},
        // error.StreamTooLong => return e, // TODO: handle somehow
        else => return e,
    }
}
