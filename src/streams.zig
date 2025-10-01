const std = @import("std");
const io = std.io;
const no_os = @import("builtin").target.os.tag == .freestanding;
const wasm = @import("wasm.zig");
const verbose_tests = @import("build_options").verbose_errors;

var stdin_buffer: [1024]u8 = undefined;
var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
var stdout_buffer: [1024]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
var stderr_buffer: [1024]u8 = undefined;
var stderr_writer = std.fs.File.stdout().writer(&stderr_buffer);

const stdout = &stdout_writer.interface;
pub const streams = if (no_os) wasm.streams else .{
    .in = &stdin_reader.interface,
    .out = &stdout_writer.interface,
    .err = if (verbose_tests)
        &stderr_writer.interface
    else
        std.io.null_writer,
};
