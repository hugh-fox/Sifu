const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const Allocator = std.mem.Allocator;
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

    // TODO
    _ = ts_str;
    _ = zig_str;
    // try testing.expectEqualStrings(zig_str, ts_str);
}

const TestCase = struct {
    query: []const u8,
    expected: []const u8,
};

fn parseTestFile(content: []const u8) !struct { trie: []const u8, tests: []const TestCase } {
    const section_delimiter = "\n\n#===\n\n";
    const case_delimiter = "\n\n#---\n\n";

    var tests_buf: [64]TestCase = undefined;
    var test_count: usize = 0;

    var sections = mem.splitSequence(u8, content, section_delimiter);
    const trie_section = sections.first();

    while (sections.next()) |test_section| {
        const trimmed = mem.trim(u8, test_section, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        const delim_pos = mem.indexOf(u8, test_section, case_delimiter) orelse {
            std.debug.print("ERROR: test section has no #--- delimiter: '{s}'\n", .{trimmed});
            return error.MissingDelimiter;
        };
        const query = mem.trim(u8, test_section[0..delim_pos], &std.ascii.whitespace);
        const expected = mem.trim(u8, test_section[delim_pos + case_delimiter.len ..], &std.ascii.whitespace);
        tests_buf[test_count] = .{ .query = query, .expected = expected };
        test_count += 1;
    }

    return .{ .trie = trie_section, .tests = tests_buf[0..test_count] };
}

fn runBehaviorTest(allocator: Allocator, comptime name: []const u8) !void {
    const behavior = try openDir(Dir.cwd(), behavior_dir, false);
    defer behavior.close(testing.io);

    const file_content = try readFile(behavior, name ++ ".sifu", allocator);
    const parsed = try parseTestFile(file_content);

    var zig_trie = try Parser.parseTrie(allocator, parsed.trie);
    defer zig_trie.deinit(allocator);
    const zig_trie_str = try zig_trie.toString(allocator);

    const ast = try parseWithTreeSitter(parsed.trie);
    defer ast.destroy();
    var ts_trie = try ts.astNodeToTrie(allocator, parsed.trie, ast);
    defer ts_trie.deinit(allocator);
    const ts_trie_str = try ts_trie.toString(allocator);

    // TODO
    _ = ts_trie_str;
    _ = zig_trie_str;
    // try testing.expectEqualStrings(zig_trie_str, ts_trie_str);

    var passed: usize = 0;
    var failed: usize = 0;

    for (parsed.tests, 0..) |test_case, i| {
        var zig_query = Parser.parse(allocator, test_case.query) catch |err| {
            std.debug.print("  FAIL: test {d} - zig query parse error: {}\n", .{ i + 1, err });
            failed += 1;
            continue;
        };
        defer zig_query.deinit(allocator);

        const query_ast = parseWithTreeSitter(test_case.query) catch |err| {
            std.debug.print("  FAIL: test {d} - tree-sitter query parse failed: {}\n", .{ i + 1, err });
            failed += 1;
            continue;
        };
        defer query_ast.destroy();
        var ts_query = ts.astToPattern(allocator, test_case.query, query_ast.rootNode()) catch |err| {
            std.debug.print("  FAIL: test {d} - tree-sitter query conversion error: {}\n", .{ i + 1, err });
            failed += 1;
            continue;
        };
        defer ts_query.deinit(allocator);

        const zig_query_str = zig_query.toString(allocator) catch |err| {
            std.debug.print("  FAIL: test {d} - zig query toString error: {}\n", .{ i + 1, err });
            failed += 1;
            continue;
        };
        const ts_query_str = ts_query.toString(allocator) catch |err| {
            std.debug.print("  FAIL: test {d} - ts query toString error: {}\n", .{ i + 1, err });
            failed += 1;
            continue;
        };

        testing.expectEqualStrings(zig_query_str, ts_query_str) catch {
            failed += 1;
            continue;
        };

        const eval_result = zig_trie.evaluateComplete(allocator, 0, zig_query) catch |err| {
            std.debug.print("  FAIL: test {d} - eval error: {}\n", .{ i + 1, err });
            failed += 1;
            continue;
        };
        const actual_output = if (eval_result.value) |value| blk: {
            var val = value;
            defer val.deinit(allocator);
            break :blk try val.toString(allocator);
        } else "";

        const actual_trimmed = mem.trim(u8, actual_output, &std.ascii.whitespace);

        testing.expectEqualStrings(test_case.expected, actual_trimmed) catch {
            failed += 1;
            continue;
        };
        passed += 1;
    }

    std.debug.print("Behavior: " ++ name ++ ": {d} passed, {d} failed\n", .{ passed, failed });
    if (failed > 0) return error.TestsFailed;
    if (passed == 0) return error.NoTestsRun;
}

const build_options = @import("build_options");
const parsable_files = build_options.parsable_files;
const behavior_files = build_options.behavior_files;

comptime {
    for (parsable_files) |name| {
        _ = struct {
            test "Parsable" {
                var arena = std.heap.ArenaAllocator.init(testing.allocator);
                defer arena.deinit();
                runParsableTest(arena.allocator(), name) catch |err| {
                    std.debug.print(name ++ " FAILED: {}\n", .{err});
                    return err;
                };
                std.debug.print(name ++ " PASSED\n", .{});
            }
        };
    }

    for (behavior_files) |file| {
        _ = struct {
            test "Behavior" {
                var arena = std.heap.ArenaAllocator.init(testing.allocator);
                defer arena.deinit();
                try runBehaviorTest(arena.allocator(), file);
            }
        };
    }
}
