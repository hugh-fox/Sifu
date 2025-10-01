const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "sifu",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // This is commented out so as to not build the x86 default when targeting
    // wasm.
    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    // b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the patternlication depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the pattern");
    run_step.dependOn(&run_cmd.step);

    const wasm_lib = b.addExecutable(.{
        .name = "sifu",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding,
            }),
            .optimize = std.builtin.OptimizeMode.ReleaseSmall,
        }),
    });
    wasm_lib.entry = .disabled;
    wasm_lib.rdynamic = true;
    wasm_lib.root_module.pic = true;
    wasm_lib.import_memory = true;
    const run_wasm = b.addInstallArtifact(wasm_lib, .{});
    run_wasm.step.dependOn(b.getInstallStep());
    const wasm_step = b.step("wasm", "Build a wasm lib");
    wasm_step.dependOn(&run_wasm.step);

    const wasi_exe = b.addExecutable(.{
        .name = "sifu-wasi",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .wasi,
            }),
            .optimize = optimize,
        }),
    });
    const run_wasi = b.addInstallArtifact(wasi_exe, .{});
    run_wasi.step.dependOn(b.getInstallStep());
    const wasi_step = b.step("wasi", "Build a wasm exe");
    wasi_step.dependOn(&run_wasi.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    if (b.args) |args| {
        run_cmd.addArgs(args);
        run_unit_tests.addArgs(args);
    }
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const verbose_errors = b.option(
        bool,
        "VerboseErrors",
        "Write all error and debug information to stderr",
    ) orelse false;
    const detect_leaks = b.option(
        bool,
        "DetectLeaks",
        "Use GPA's with leak detection instead of arenas",
    ) orelse false;
    const build_options = b.addOptions();
    build_options.addOption(bool, "verbose_errors", verbose_errors);
    build_options.addOption(bool, "detect_leaks", detect_leaks);
    unit_tests.root_module.addOptions("build_options", build_options);
    wasm_lib.root_module.addOptions("build_options", build_options);
    wasi_exe.root_module.addOptions("build_options", build_options);
    exe.root_module.addOptions("build_options", build_options);
}
