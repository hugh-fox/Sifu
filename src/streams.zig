const std = @import("std");
const Io = std.Io;
const fs = std.fs;
const no_os = @import("builtin").target.os.tag == .freestanding;
const verbose_tests = @import("build_options").verbose_errors;
const wasm = @import("wasm.zig");

pub const Streams = struct {
    var stdin_buffer: [1024]u8 = undefined;
    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdin_reader: Io.File.Reader = undefined;
    var stdout_writer: Io.File.Writer = undefined;
    var stderr_writer: Io.File.Writer = undefined;

    in: *Io.Reader,
    out: *Io.Writer,
    err: *Io.Writer,
    pub fn init(io: Io) Streams {
        if (no_os)
            return wasm.streams
        else {
            stdin_reader = Io.File.stdin().reader(io, &stdin_buffer);
            stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
            stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
            return .{
                .in = &stdin_reader.interface,
                .out = &stdout_writer.interface,
                .err = &stderr_writer.interface,
            };
        }
    }
};

// TODO switch on verbose_tests
// var stderr_writer = if (verbose_tests)
//     stderr
// else
//     io.Writer.Discarding.init(&stderr_buffer);
