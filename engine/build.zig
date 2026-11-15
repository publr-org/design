const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library: what a host imports as `publr_engine`.
    const engine = b.addModule("publr_engine", .{
        .root_source_file = b.path("src/engine.zig"),
        .target = target,
        .optimize = optimize,
    });

    // `pe`: the command line (import, render, score).
    const pe = b.addExecutable(.{
        .name = "pe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{
                .name = "publr_engine",
                .module = engine,
            }},
        }),
    });
    b.installArtifact(pe);

    const run = b.addRunArtifact(pe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run pe").dependOn(&run.step);

    // `zig build serve -- [doc.pubd-dir renders-dir] [--port N]`: the accuracy page, after
    // building the UI it serves (../editor's zig-out/site).
    const ui = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    ui.setCwd(b.path("../editor"));
    ui.has_side_effects = true;
    const serve = b.addRunArtifact(pe);
    serve.step.dependOn(&ui.step);
    serve.addArg("serve");
    if (b.args) |args| {
        if (args.len < 2 or std.mem.startsWith(u8, args[0], "--")) serve.addArgs(&.{ "corpus/landing/landing.pubd", "corpus/landing/renders" });
        serve.addArgs(args);
    } else serve.addArgs(&.{ "corpus/landing/landing.pubd", "corpus/landing/renders" });
    b.step("serve", "Serve the accuracy page (default: the landing corpus)").dependOn(&serve.step);

    // `zig build wasm`: zig-out/web/publr_engine.wasm, the engine for the browser viewer
    // (src/wasm.zig). Always optimized unless -Dwasm-optimize says otherwise: a Debug
    // build renders far too slowly to pan.
    const wasm_optimize = b.option(std.builtin.OptimizeMode, "wasm-optimize", "Optimization for the WASM build (default ReleaseFast)") orelse .ReleaseFast;
    // -Dwasm-names keeps function names (profiling in the browser).
    const wasm_names = b.option(bool, "wasm-names", "Keep function names in the WASM build (profiling)") orelse false;
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_features_add = std.Target.wasm.featureSet(&.{
            .simd128,
            .bulk_memory,
            .nontrapping_fptoint,
            .sign_ext,
        }),
    });
    const wasm_engine = b.createModule(.{
        .root_source_file = b.path("src/engine.zig"),
        .target = wasm_target,
        .optimize = wasm_optimize,
    });
    const wasm = b.addExecutable(.{
        .name = "publr_engine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
            .strip = !wasm_names,
            .imports = &.{.{
                .name = "publr_engine",
                .module = wasm_engine,
            }},
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.stack_size = 8 * 1024 * 1024;
    wasm.max_memory = 4 * 1024 * 1024 * 1024;
    const install_wasm = b.addInstallArtifact(wasm, .{
        .dest_dir = .{
            .override = .{
                .custom = "web",
            },
        },
    });
    b.step("wasm", "Build the engine for the browser (zig-out/web/publr_engine.wasm)").dependOn(&install_wasm.step);

    const unit = b.addTest(.{
        .root_module = engine,
    });
    const test_step = b.step("test", "Run the unit tests and tidy");
    test_step.dependOn(&b.addRunArtifact(unit).step);

    // Publr's tidy, with only the options rule: optional parameters are one trailing
    // `options: Options` whose fields all have defaults.
    const tidy = b.addExecutable(.{
        .name = "tidy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("../../publr/scripts/tidy.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_tidy = b.addRunArtifact(tidy);
    run_tidy.addArgs(&.{ "--only=options", "build.zig", "src" });
    run_tidy.setCwd(b.path("."));
    run_tidy.has_side_effects = true;
    b.step("tidy", "Check the options rule").dependOn(&run_tidy.step);
    test_step.dependOn(&run_tidy.step);
}
