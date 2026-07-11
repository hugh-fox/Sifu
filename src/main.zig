const std = @import("std");
const Io = std.Io;
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const cli = @import("cli");
const ArrayList = std.ArrayList;
const Allocating = std.Io.Writer.Allocating;
const Trie = @import("sifu/trie.zig").Trie;
const debug = std.log.debug;
const verbose = @import("build_options").verbose;

var config = struct {
    interactive: bool = false,
    compile: bool = false,
    verbose: bool = false,
    source: ?[]const u8 = null,
    trie: ?[]const u8 = null,
    evaluate: ?[]const u8 = null,
}{};

pub const std_options: std.Options = .{ .log_level = if (verbose) .debug else .info };

fn noOp() !void {}

pub fn main(init: std.process.Init) !void {
    var arena = ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

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
                    .long_name = "source",
                    .short_alias = 's',
                    .help = "source file to parse into the trie to evaluate against",
                    .value_ref = r.mkRef(&config.source),
                },
                .{
                    .long_name = "trie",
                    .short_alias = 't',
                    .help = "expression parsed as the trie to evaluate against (top-level, no braces)",
                    .value_ref = r.mkRef(&config.trie),
                },
                .{
                    .long_name = "evaluate",
                    .short_alias = 'e',
                    .help = "expression to evaluate",
                    .value_ref = r.mkRef(&config.evaluate),
                },
            }),
            .target = cli.CommandTarget{
                .action = cli.CommandAction{
                    .positional_args = .{},
                    .exec = noOp,
                },
            },
        },
    };
    _ = try r.getAction(&app);

    const stdin_is_piped = !(std.Io.File.stdin().isTty(init.io) catch false);
    _ = stdin_is_piped;

    // if (config.compile) {
    //     if (expr.len == 0) {
    //         panic("error: -c/--compile needs an expression to compile\n", .{});
    //     }
    //     const wat = try compiler.compile(allocator, trie, expr);
    //     try streams.out.print("{s}\n", .{wat});
    //     try streams.out.flush();
    //     return;
    // }
    if (config.interactive) {
        var stack = ArrayList(u8).empty;
        errdefer stack.deinit(allocator);

        // if (stdin_is_piped) {
        //     // Reopen TTY for interactive input when stdin was a pipe
        //     const tty_file = try Io.Dir.openFileAbsolute(init.io, "/dev/tty", .{});
        //     var tty_reader = tty_file.reader(init.io, &stdin_buf);
        // }

        return repl(allocator, init.io, &stack);
    }
}

// Parsing is matching is evaluation. Parens don't need parsing
// into tree structure, just track their start / len on a separate
// stack in paren context. Each evaluator runs in sequence each byte,
// and tracks its own context. Trie and match eval are the same thing.
// No difference between adding parenthesis and infix -> postfix.

fn repl(allocator: Allocator, io: Io, stack: *ArrayList(u8)) !void {
    var in_buffer: [1024]u8 = undefined;
    var out_buffer: [1024]u8 = undefined;
    var stdin_reader = Io.File.stdin().reader(io, &in_buffer);
    var stdout_writer = Io.File.stdout().writer(io, &out_buffer);
    const in = &stdin_reader.interface;
    const out = &stdout_writer.interface;

    var trie = Trie{};
    try trie.append(allocator, "A", "B");

    _ = stack;

    var current = trie;
    var match_index: usize = 0;
    var pattern_len: usize = 0;

    // Parse initial trie
    while (in.takeByte()) |next| : (pattern_len += 1) {
        if (current.map.get(next)) |next_trie| {
            debug("Got: '{c}'", .{next});
            current = next_trie;
        } else {
            // Check if there is a value index greater than or equal to current
            const leaf_index = std.sort.lowerBound(
                struct { usize, []const u8 },
                current.leaves.items,
                match_index,
                struct {
                    pub fn compareFn(
                        lhs: usize,
                        rhs: struct { usize, []const u8 },
                    ) std.math.Order {
                        const index, const value = rhs;
                        _ = value;
                        return std.math.order(lhs, index);
                    }
                }.compareFn,
            );
            if (leaf_index == current.leaves.items.len) {
                debug("No value found", .{});
                // If no value, we output and continue
                try out.writeByte(next);
            } else {
                debug("Value found at leaf: {}", .{leaf_index});
                // Output the value (TODO: eval the value too)
                try out.print("{s}\n", .{current.leaves.items[leaf_index][1]});
            }
            // Reset match
            current = trie;
            match_index = 0;
        }
        try out.flush();
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.ReadFailed => return err,
    }
}
