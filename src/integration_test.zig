const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Parser = @import("Parser.zig");
const trie_module = @import("sifu/trie.zig");
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

fn runParsableTest(allocator: Allocator, comptime name: []const u8) !void {
    const dir = try openDir(Dir.cwd(), parsable_dir, false);
    defer dir.close(testing.io);
    const content = try readFile(dir, name ++ ".sifu", allocator);
    _ = try Parser.parse(allocator, content);
}

fn runBehaviorTest(allocator: Allocator, comptime folder: []const u8) !void {
    const behavior = try openDir(Dir.cwd(), behavior_dir, false);
    defer behavior.close(testing.io);

    const test_dir_handle = try openDir(behavior, folder, false);
    defer test_dir_handle.close(testing.io);

    const trie_content = try readFile(test_dir_handle, folder ++ ".sifu", allocator);
    var trie = try Parser.parseTrie(allocator, trie_content);
    defer trie.deinit(allocator);

    const expected_dir = try openDir(test_dir_handle, "Expected", false);
    defer expected_dir.close(testing.io);

    const query_dir = try openDir(test_dir_handle, "Query", true);
    defer query_dir.close(testing.io);

    var query_walker = try Dir.walk(query_dir, allocator);
    defer query_walker.deinit();

    var passed: usize = 0;
    var failed: usize = 0;

    while (try query_walker.next(testing.io)) |query_entry| {
        if (query_entry.kind != .file) continue;
        if (!mem.endsWith(u8, query_entry.basename, ".sifu")) continue;

        const query_content = try readFile(query_entry.dir, query_entry.basename, allocator);
        var query_pattern = Parser.parse(allocator, query_content) catch |err| {
            std.debug.print("  FAIL: {s} - query parse error: {}\n", .{ query_entry.basename, err });
            failed += 1;
            continue;
        };
        defer query_pattern.deinit(allocator);

        const eval_result = trie.evaluateComplete(allocator, 0, query_pattern) catch |err| {
            std.debug.print("  FAIL: {s} - eval error: {}\n", .{ query_entry.basename, err });
            failed += 1;
            continue;
        };
        const actual_output = if (eval_result.value) |value| blk: {
            var val = value;
            defer val.deinit(allocator);
            break :blk val.toString(allocator) catch "";
        } else "";

        const expected_content = readFile(expected_dir, query_entry.basename, allocator) catch |err| {
            std.debug.print("  SKIP: Expected/{s} - {}\n", .{ query_entry.basename, err });
            continue;
        };
        const expected_trimmed = mem.trim(u8, expected_content, &std.ascii.whitespace);
        const actual_trimmed = mem.trim(u8, actual_output, &std.ascii.whitespace);

        if (!mem.eql(u8, expected_trimmed, actual_trimmed)) {
            std.debug.print("  FAIL: {s}\n    Expected: '{s}'\n    Actual:   '{s}'\n", .{ query_entry.basename, expected_trimmed, actual_trimmed });
            failed += 1;
        } else {
            passed += 1;
        }
    }

    std.debug.print("Behavior: " ++ folder ++ ": {d} passed, {d} failed\n", .{ passed, failed });
    if (failed > 0) return error.TestsFailed;
    if (passed == 0) return error.NoTestsRun;
}

const build_options = @import("build_options");
const parsable_files = build_options.parsable_files;
const behavior_folders = build_options.behavior_folders;

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

    for (behavior_folders) |folder| {
        _ = struct {
            test "Behavior" {
                var arena = std.heap.ArenaAllocator.init(testing.allocator);
                defer arena.deinit();
                try runBehaviorTest(arena.allocator(), folder);
            }
        };
    }
}
