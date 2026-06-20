const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Parser = @import("Parser.zig");
const trie_module = @import("sifu/trie.zig");
const Trie = trie_module.Trie;
const Pattern = trie_module.Pattern;
const ts = @import("tree_sitter_parser.zig");
const ts_parser = ts.parser;
const Io = std.Io;
const Dir = Io.Dir;

const test_dir = "test";
const parsable_dir = test_dir ++ "/Parsable";
const behavior_dir = test_dir ++ "/Behavior";

fn openDir(parent: Dir, path: []const u8, iterate: bool) !Dir {
    return Dir.openDir(parent, testing.io, path, .{ .iterate = iterate });
}

fn readFile(dir: Dir, name: []const u8, allocator: Allocator) ![]const u8 {
    return dir.readFileAlloc(testing.io, name, allocator, .unlimited);
}

fn parseWithTreeSitter(content: []const u8) !*ts_parser.Tree {
    const parser = try ts_parser.createParser();
    defer parser.destroy();
    return parser.parseStringEncoding(content, null, ts_parser.ts.Input.Encoding.utf8) orelse
        return error.TreeSitterParseFailed;
}

fn runParsableTest(allocator: Allocator, comptime name: []const u8) !void {
    const dir = try openDir(Dir.cwd(), parsable_dir, false);
    defer dir.close(testing.io);
    const content = try readFile(dir, name ++ ".sifu", allocator);

    var zig_pattern = try Parser.parse(allocator, content);
    defer zig_pattern.deinit(allocator);
    const zig_str = try zig_pattern.toString(allocator);

    const ast = try parseWithTreeSitter(content);
    defer ast.destroy();
    var ts_pattern = try ts.astToPattern(allocator, content, ast.rootNode());
    defer ts_pattern.deinit(allocator);
    const ts_str = try ts_pattern.toString(allocator);

    try testing.expectEqualStrings(zig_str, ts_str);
}

const TestCase = struct {
    query: []const u8,
    expected: []const u8,
};

const ParsedTestFile = struct {
    trie: []const u8,
    tests: []const TestCase,
};

fn parseTestFile(allocator: Allocator, content: []const u8) !ParsedTestFile {
    const section_delimiter = "\n\n# ===\n\n";
    const case_delimiter = "\n\n# ---\n\n";

    var tests: ArrayList(TestCase) = .empty;

    var sections = mem.splitSequence(u8, content, section_delimiter);
    const trie_section = sections.first();

    while (sections.next()) |test_section| {
        const delim_pos = mem.indexOf(u8, test_section, case_delimiter) orelse {
            std.debug.print(
                "ERROR: test section has no # --- delimiter: '{s}'\n",
                .{test_section},
            );
            return error.MissingDelimiter;
        };
        const query = test_section[0..delim_pos];
        const expected = mem.trimEnd(u8, test_section[delim_pos + case_delimiter.len ..], &.{'\n'});
        try tests.append(allocator, .{ .query = query, .expected = expected });
    }

    return .{ .trie = trie_section, .tests = try tests.toOwnedSlice(allocator) };
}

/// How long a single sifu invocation may run before we give up and kill it.
const sifu_timeout: Io.Timeout = .{
    .duration = .{ .raw = .fromSeconds(1), .clock = .awake },
};

/// Most output we'll capture from one invocation. A runaway query that streams
/// output forever keeps its stdout readable, so the `poll`-based deadline never
/// fires (poll only reports a timeout when *no* data is ready); this bound kills
/// it instead.
const max_output_bytes: usize = 4 << 10; // 4 KiB

/// Whether `deadline` has elapsed. Lets the drain loop give up on a child that
/// keeps stdout readable, where `fill` alone would never surface error.Timeout.
fn deadlinePassed(deadline: Io.Timeout) bool {
    const remaining = deadline.toDurationFromNow(testing.io) orelse return false;
    return remaining.raw.toMilliseconds() <= 0;
}

/// Writes all of `bytes` to `file`, giving up once `deadline` passes so a
/// child that stops reading its stdin can never wedge the test.
fn writeAllTimeout(file: Io.File, bytes: []const u8, deadline: Io.Timeout) !void {
    var index: usize = 0;
    while (index < bytes.len) {
        const data = [_][]const u8{bytes[index..]};
        const result = try Io.operateTimeout(
            testing.io,
            .{ .file_write_streaming = .{
                .file = file,
                .header = &.{},
                .data = &data,
                .splat = 1,
            } },
            deadline,
        );
        index += try result.file_write_streaming;
    }
}

/// Spawns the sifu executable, feeds it `trie_content` on stdin and `query` as
/// an argument, and returns its stdout. Caller owns the returned slice. Every
/// stream (stdin, stdout, stderr) shares a single deadline, so a hung child is
/// always killed rather than blocking the test forever.
fn runSifu(allocator: Allocator, trie_content: []const u8, query: []const u8) ![]u8 {
    // This exe is built with -DDetectLeaks so the integration tests catch leaks
    // and use-after-free in the evaluator.
    const sifu_exe = @import("integration_options").sifu_exe;

    var child = try std.process.spawn(testing.io, .{
        .argv = &.{ sifu_exe, query },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    errdefer child.kill(testing.io);

    // Anchor a single deadline that bounds the whole interaction.
    const deadline = sifu_timeout.toDeadline(testing.io);

    // Send the trie definition, then close stdin so the child sees EOF.
    try writeAllTimeout(child.stdin.?, trie_content, deadline);
    child.stdin.?.close(testing.io);
    child.stdin = null;

    // Drain stdout and stderr concurrently into heap-grown buffers; reading
    // both at once avoids deadlocking on a child that fills either pipe.
    var reader_buffer: Io.File.MultiReader.Buffer(1) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(
        allocator,
        testing.io,
        reader_buffer.toStreams(),
        &.{child.stdout.?},
    );
    defer multi_reader.deinit();

    // Drain stdout, bounding both wall-clock time and total bytes. `fill` blocks
    // until data arrives or `deadline` passes: an idle hang surfaces here as
    // error.Timeout, while a chatty infinite loop is caught by the checks below.
    // Either way the errdefer above kills the child.
    while (true) {
        if (deadlinePassed(deadline)) return error.Timeout;
        if (multi_reader.reader(0).bufferedLen() > max_output_bytes)
            return error.OutputTooLarge;
        multi_reader.fill(1, deadline) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
    }
    try multi_reader.checkAnyError();

    _ = try child.wait(testing.io);

    return multi_reader.toOwnedSlice(0);
}

fn runBehaviorTest(allocator: Allocator, comptime name: []const u8) !void {
    const behavior = try openDir(Dir.cwd(), behavior_dir, false);
    defer behavior.close(testing.io);

    const file_content = try readFile(behavior, name ++ ".sifu", allocator);
    const parsed = try parseTestFile(allocator, file_content);

    var passed: usize = 0;
    var failed: usize = 0;

    for (parsed.tests, 0..) |test_case, i| {
        const actual = runSifu(allocator, parsed.trie, test_case.query) catch |err| {
            std.debug.print("  FAIL: test {d} - sifu error: {}\n", .{ i + 1, err });
            failed += 1;
            continue;
        };
        defer allocator.free(actual);

        testing.expectEqualStrings(test_case.expected, actual) catch {
            std.debug.print("  FAIL test {d}: expected '{s}', got '{s}'\n", .{
                i + 1,
                test_case.expected,
                actual,
            });
            failed += 1;
            continue;
        };
        passed += 1;
    }

    std.debug.print(
        "Behavior: " ++ name ++ ": {d} passed, {d} failed\n",
        .{ passed, failed },
    );
    if (failed > 0) return error.TestsFailed;
    if (passed == 0) return error.NoTestsRun;
}

/// Identifiers used to build random expressions, mixing ASCII and multibyte
/// UTF-8 (CJK, Greek, accented). Each is a single valid sifu token.
const random_idents = [_][]const u8{
    "foo", "Bar",  "x",    "Const", "你好",
    "世界", "猫Cat", "Δ",    "λ",     "café",
    "T",   "ab12", "X你",   "变量",    "f",
};

/// Appends a random, already-canonical expression to `out`: space-separated
/// atoms, each either an identifier or a parenthesized sub-expression. Because
/// the layout is canonical, evaluating it against an empty trie must echo it
/// back verbatim (a no-op).
fn genExpr(out: *ArrayList(u8), allocator: Allocator, rng: std.Random, depth: u8) !void {
    const atoms = rng.intRangeAtMost(usize, 1, 4);
    for (0..atoms) |i| {
        if (i > 0) try out.append(allocator, ' ');
        // Only nest while we have depth budget, and not for every atom.
        if (depth > 0 and rng.boolean()) {
            try out.append(allocator, '(');
            try genExpr(out, allocator, rng, depth - 1);
            try out.append(allocator, ')');
        } else {
            const ident = random_idents[rng.uintLessThan(usize, random_idents.len)];
            try out.appendSlice(allocator, ident);
        }
    }
}

/// Evaluates random expressions against an empty trie and asserts each is
/// echoed back unchanged. Guards against the lexer dropping UTF-8 bytes.
fn runEmptyTrieNoop(allocator: Allocator) !void {
    const seed: u64 = 0x5ec0ffee;
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    for (0..64) |_| {
        var expr: ArrayList(u8) = .empty;
        defer expr.deinit(allocator);
        try genExpr(&expr, allocator, rng, 3);

        const actual = try runSifu(allocator, "", expr.items);
        defer allocator.free(actual);

        testing.expectEqualStrings(expr.items, actual) catch |err| {
            std.debug.print("seed {d}: empty-trie eval changed '{s}' -> '{s}'\n", .{
                seed, expr.items, actual,
            });
            return err;
        };
    }
}

const build_options = @import("build_options");
const parsable_files = build_options.parsable_files;
const behavior_files = build_options.behavior_files;

/// File names passed after `--` (e.g. `zig build integration -- In Math`).
/// Empty means run every test.
const test_filters = build_options.test_filters;

/// Whether `name` should run given the filters passed on the command line.
/// With no filters everything runs; otherwise `name` must contain one of them.
fn nameSelected(name: []const u8) bool {
    if (test_filters.len == 0) return true;
    for (test_filters) |filter| {
        if (mem.indexOf(u8, name, filter) != null) return true;
    }
    return false;
}

/// Behavior tests known to fail that we explicitly skip for now.
const behavior_skips = [_][]const u8{};

/// Whether `name` is on the hardcoded skip list.
fn isSkipped(name: []const u8) bool {
    for (behavior_skips) |skip| {
        if (mem.eql(u8, name, skip)) return true;
    }
    return false;
}

comptime {
    for (parsable_files) |name| {
        _ = struct {
            test "Parsable" {
                if (!nameSelected(name)) return error.SkipZigTest;
                var arena = std.heap.ArenaAllocator.init(testing.allocator);
                defer arena.deinit();
                std.debug.print("{s}: ", .{name});
                runParsableTest(arena.allocator(), name) catch |err| {
                    std.debug.print("FAILED: {}\n", .{err});
                    return err;
                };
                std.debug.print("PASSED\n", .{});
            }
        };
    }

    _ = struct {
        test "EmptyTrieNoop" {
            if (!nameSelected("EmptyTrieNoop")) return error.SkipZigTest;
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            try runEmptyTrieNoop(arena.allocator());
        }
    };

    for (behavior_files) |file| {
        _ = struct {
            test "Behavior" {
                if (!nameSelected(file)) return error.SkipZigTest;
                if (isSkipped(file)) return error.SkipZigTest;
                var arena = std.heap.ArenaAllocator.init(testing.allocator);
                defer arena.deinit();
                try runBehaviorTest(arena.allocator(), file);
            }
        };
    }
}
