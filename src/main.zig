/// === For testing memory usage ===
// @compileLog(@sizeOf(Trie));
// @compileLog(@sizeOf(Pattern.Node));
// @compileLog(@sizeOf(Pattern));
///
const std = @import("std");
const Trie = @import("sifu/trie.zig").Trie;
const Pattern = @import("sifu/trie.zig").Pattern;
const Node = @import("sifu/trie.zig").Node;
const interpreter = @import("interpreter.zig");
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const fs = std.fs;
const Io = std.Io;
const mem = std.mem;
const wasm = @import("wasm.zig");
const builtin = @import("builtin");
const no_os = builtin.target.os.tag == .freestanding;
const Streams = @import("streams.zig").Streams;
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
const cli = @import("cli");
const compiler = @import("compiler.zig");
var config = struct {
    interactive: bool = false,
    compile: bool = false,
    expression: []const u8 = "",
}{};

fn noOp() !void {}

pub fn main(init: std.process.Init) !void {
    var arena = ArenaAllocator.init(init.gpa);
    var debug_allocator = if (comptime detect_leaks)
        std.heap.DebugAllocator(.{}){}
    else {};
    const allocator = if (comptime detect_leaks)
        debug_allocator.allocator()
    else
        arena.allocator();
    defer {
        if (comptime detect_leaks)
            _ = debug_allocator.detectLeaks()
        else
            arena.deinit();
    }

    const streams = Streams.init(init.io);

    var r = cli.AppRunner.init(&init);
    defer r.deinit();

    const app = cli.App{
        .command = cli.Command{
            .name = "sifu",
            .description = .{ .one_line = "Sifu interactive REPL" },
            .options = try r.allocOptions(&.{
                .{
                    .long_name = "interactive",
                    .short_alias = 'i',
                    .help = "start interactive REPL",
                    .value_ref = r.mkRef(&config.interactive),
                },
                .{
                    .long_name = "compile",
                    .short_alias = 'c',
                    .help = "compile the expression to WAT using wat.sifu",
                    .value_ref = r.mkRef(&config.compile),
                },
            }),
            .target = cli.CommandTarget{
                .action = cli.CommandAction{
                    .positional_args = .{
                        .optional = try r.allocPositionalArgs(&.{
                            .{
                                .name = "expression",
                                .help = "expression to evaluate",
                                .value_ref = r.mkRef(&config.expression),
                            },
                        }),
                    },
                    .exec = noOp,
                },
            },
        },
    };
    _ = try r.getAction(&app);

    const stdin_is_piped = !(std.Io.File.stdin().isTty(init.io) catch false);
    const has_expr = config.expression.len > 0;

    var trie = Trie{};
    defer trie.deinit(allocator);

    if (stdin_is_piped)
        try loadTrie(allocator, streams, &trie);

    // Compile mode: evaluate the expression against the piped `wat.sifu` rules
    // and render the result as WAT text via the string interpreter.
    if (config.compile) {
        if (!has_expr) {
            try streams.err.print("error: -c/--compile needs an expression to compile\n", .{});
            try streams.err.flush();
            return;
        }
        const wat = try compiler.compile(allocator, trie, config.expression);
        try streams.out.print("{s}\n", .{wat});
        try streams.out.flush();
        return;
    }

    if (config.interactive) {
        if (stdin_is_piped) {
            // Reopen TTY for interactive input after loading trie from pipe
            var tty_buffer: [1024]u8 = undefined;
            const tty_file = try Io.Dir.openFileAbsolute(init.io, "/dev/tty", .{});
            var tty_reader = tty_file.reader(init.io, &tty_buffer);
            const tty_streams = Streams{
                .in = &tty_reader.interface,
                .out = streams.out,
                .err = streams.err,
            };
            return replWithTrie(allocator, tty_streams, &trie);
        }
        return replWithTrie(allocator, streams, &trie);
    }

    if (has_expr) {
        try evalExpr(allocator, streams, &trie, config.expression);
    } else if (stdin_is_piped) {
        try trie.writeCanonical(streams.out);
        try streams.out.flush();
    }
}

fn loadTrie(allocator: Allocator, streams: Streams, trie: *Trie) !void {
    // Read all of stdin at once to support multi-line patterns
    var buffer = std.Io.Writer.Allocating.init(allocator);
    defer buffer.deinit();
    while (true) {
        _ = streams.in.streamDelimiter(&buffer.writer, '\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try buffer.writer.writeByte('\n');
        _ = streams.in.takeByte() catch break;
    }
    const content = buffer.written();
    if (content.len > 0) {
        trie.* = try Parser.parseTrie(allocator, content);
    }
}

fn evalExpr(allocator: Allocator, streams: Streams, trie: *Trie, expr: []const u8) !void {
    var pattern = try Parser.parse(allocator, expr);
    defer pattern.deinit(allocator);

    debug("Eval Complete from {*}", .{trie});
    var eval = try interpreter.evaluateComplete(trie.*, allocator, pattern);
    if (eval) |*value| {
        defer @constCast(value).deinit(allocator);
        try value.writeIndent(streams.out, 0);
    } else {
        try streams.out.print("No match.", .{});
    }
    try streams.out.flush();
}

fn repl(allocator: Allocator, streams: Streams) !void {
    var trie = Trie{};
    defer trie.deinit(allocator);
    return replWithTrie(allocator, streams, &trie);
}

fn replWithTrie(allocator: Allocator, streams: Streams, trie: *Trie) !void {
    while (replStep(allocator, streams, trie)) |_| {
        try streams.out.flush();
    } else |err| switch (err) {
        error.EndOfStream => return,
        else => return err,
    }
}

fn replStep(allocator: Allocator, streams: Streams, trie: *Trie) !?void {
    var buffer = std.Io.Writer.Allocating.init(allocator);
    defer buffer.deinit();
    var pattern = if (comptime use_tree_sitter) blk: {
        const ast_option = try ts.parser.parseLine(&buffer, streams.in);
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
        break :blk try ts.astToPattern(allocator, buffer.written(), ast_ptr.rootNode());
    } else blk: {
        _ = streams.in.streamDelimiter(&buffer.writer, '\n') catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            else => return err,
        };
        _ = try streams.in.takeByte();
        break :blk try Parser.parse(allocator, buffer.written());
    };
    defer pattern.deinit(allocator);
    const root = pattern.root;
    debug(
        "Converted pattern {} high and {} wide, of types: ",
        .{ pattern.height, pattern.root.len },
    );

    if (root.len > 0 and root[root.len - 1] == .arrow) {
        const constant = root[0 .. root.len - 1];
        const val = root[root.len - 1].arrow;
        _ = try trie.append(
            allocator,
            .{ .root = constant, .height = pattern.height },
            val,
        );
    } else {
        debug("Eval Complete from {*}", .{trie});
        var eval = try interpreter.evaluateComplete(trie.*, allocator, pattern);
        if (eval) |*value| {
            defer @constCast(value).deinit(allocator);
            std.log.debug("WriteIndent on pattern len {}", .{value.root.len});
            try value.writeIndent(streams.out, 0);
            try streams.out.writeByte('\n');
        } else {
            return;
        }
    }

    try trie.writeCanonical(streams.out);
}
