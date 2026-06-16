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
    const use_tree_sitter = b.option(
        bool,
        "TreeSitter",
        "Use the tree-sitter parser instead of the recursive descent parser",
    ) orelse false;
    const build_options = b.addOptions();
    build_options.addOption(bool, "verbose_errors", verbose_errors);
    build_options.addOption(bool, "detect_leaks", detect_leaks);
    build_options.addOption(bool, "tree_sitter", use_tree_sitter);

    const tree_sitter_sifu = b.dependency("tree_sitter_sifu", .{
        .target = target,
        .optimize = optimize,
    });
    const cli = b.dependency("cli", .{
        .target = target,
        .optimize = optimize,
    });

    const module = b.addModule("sifu", .{
        .root_source_file = b.path("src/sifu/trie.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "sifu",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                .{ .name = "module", .module = module },
            },
        }),
    });
    exe.root_module.addImport("cli", cli.module("cli"));
    if (use_tree_sitter)
        exe.root_module.addImport("tree_sitter_sifu", tree_sitter_sifu.module("tree_sitter_sifu"));

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
    wasm_lib.export_memory = true;
    wasm_lib.rdynamic = true;
    const run_wasm = b.addInstallArtifact(
        wasm_lib,
        .{ .dest_dir = .{ .override = .{ .custom = "../../Sifu-Site/public/dist/" } } },
    );
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
    wasi_exe.root_module.addImport("tree_sitter_sifu", tree_sitter_sifu.module("tree_sitter_sifu"));
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
    const test_step = b.step("test", "Run all tests (unit + integration)");
    test_step.dependOn(&run_unit_tests.step);

    // Integration tests for test/ folder
    const integration_tests = b.addTest(.{
        .name = "integration",
        // Importing the source modules drags in their unit `test` blocks too
        // (some of which are also named "Behavior:"); restrict this binary to
        // the tests generated in integration_test.zig by their module prefix.
        .filters = &.{"integration_test.comptime"},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/integration_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    integration_tests.root_module.addImport("tree_sitter_sifu", tree_sitter_sifu.module("tree_sitter_sifu"));

    // Collect test files at build time
    var parsable_list: std.ArrayListUnmanaged([]const u8) = .empty;
    var parsable_dir = b.build_root.handle.openDir(b.graph.io, "test/Parsable", .{ .iterate = true }) catch @panic("Could not open test/Parsable");
    defer parsable_dir.close(b.graph.io);
    var parsable_iter = parsable_dir.iterate();
    while (parsable_iter.next(b.graph.io) catch null) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".sifu")) {
            parsable_list.append(b.allocator, b.dupe(entry.name[0 .. entry.name.len - 5])) catch @panic("OOM");
        }
    }
    build_options.addOption([]const []const u8, "parsable_files", parsable_list.items);

    var behavior_list: std.ArrayListUnmanaged([]const u8) = .empty;
    var behavior_dir = b.build_root.handle.openDir(b.graph.io, "test/Behavior", .{ .iterate = true }) catch @panic("Could not open test/Behavior");
    defer behavior_dir.close(b.graph.io);
    var behavior_iter = behavior_dir.iterate();
    while (behavior_iter.next(b.graph.io) catch null) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".sifu")) {
            behavior_list.append(b.allocator, b.dupe(entry.name[0 .. entry.name.len - 5])) catch @panic("OOM");
        }
    }
    build_options.addOption([]const []const u8, "behavior_files", behavior_list.items);

    // Names passed after `--` (e.g. `zig build integration -- In Math`) restrict
    // which test files run; empty means run everything.
    const test_filters: []const []const u8 = if (b.args) |args| args else &.{};
    build_options.addOption([]const []const u8, "test_filters", test_filters);

    integration_tests.root_module.addOptions("build_options", build_options);
    const integration_options = b.addOptions();
    integration_options.addOptionPath("sifu_exe", exe.getEmittedBin());
    integration_tests.root_module.addOptions("integration_options", integration_options);
    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_test_step = b.step("integration", "Run integration tests on test/ folder");
    integration_test_step.dependOn(&run_integration_tests.step);

    // `zig build test` runs the unit tests above plus the integration tests.
    test_step.dependOn(&run_integration_tests.step);

    unit_tests.root_module.addOptions("build_options", build_options);
    wasm_lib.root_module.addOptions("build_options", build_options);
    wasi_exe.root_module.addOptions("build_options", build_options);
    exe.root_module.addOptions("build_options", build_options);
}
