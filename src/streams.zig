const std = @import("std");
const io = std.io;
const fs = std.fs;
const no_os = @import("builtin").target.os.tag == .freestanding;
const verbose_tests = @import("build_options").verbose_errors;
const wasm = @import("wasm.zig");

pub const Streams = struct {
    in: *io.Reader,
    out: *io.Writer,
    err: *io.Writer,
};

var stdin_buffer: [1024]u8 = undefined;
var stdin_reader = fs.File.stdin().reader(&stdin_buffer);
var stdout_buffer: [1024]u8 = undefined;
var stdout_writer = fs.File.stdout().writer(&stdout_buffer);
var stderr_buffer: [1024]u8 = undefined;
var stderr_writer = fs.File.stderr().writer(&stderr_buffer);
// TODO switch on verbose_tests
// var stderr_writer = if (verbose_tests)
//     stderr
// else
//     io.Writer.Discarding.init(&stderr_buffer);

pub const streams: Streams = if (no_os) wasm.streams else .{
    .in = &stdin_reader.interface,
    .out = &stdout_writer.interface,
    .err = &stderr_writer.interface,
};
