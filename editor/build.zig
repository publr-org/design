const std = @import("std");

/// PublrDesign's UI: every `.ptsx` and `.ts` module lowered by pjsx's DOM target and
/// served as it is behind an import map (`zig build` writes zig-out/site; `pe view` in
/// ../engine serves it with the engine's WASM build). No bundler, no minifier, no node.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The jit engine the chrome's classes are compiled with in the browser.
    const jit = b.dependency("publr_jit", .{
        .target = target,
        .optimize = optimize,
    });
    const jit_engine = b.addExecutable(.{
        .name = "jit_engine",
        .root_module = b.createModule(.{
            .root_source_file = jit.path("src/wasm.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding,
            }),
            .optimize = .ReleaseSmall,
        }),
    });
    jit_engine.entry = .disabled;
    jit_engine.rdynamic = true;
    jit_engine.export_memory = true;

    const pjsx_host = b.dependency("pjsx", .{
        .target = b.graph.host,
    });
    const tool = b.addExecutable(.{
        .name = "design_gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/design_gen.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{
                .{
                    .name = "pjsx",
                    .module = pjsx_host.module("pjsx"),
                },
                .{
                    .name = "publr_icons",
                    .module = b.createModule(.{
                        .root_source_file = b.path("../../icons/publr_icons.zig"),
                    }),
                },
            },
        }),
    });
    const gen = b.addRunArtifact(tool);
    gen.addDirectoryArg(b.path("."));
    gen.addDirectoryArg(b.path("../../ui"));
    gen.addDirectoryArg(b.path("../../icons"));
    gen.addDirectoryArg(b.path("../../publr-js/dist"));
    gen.addArtifactArg(jit_engine);
    gen.addFileArg(jit.path("src/preflight.css"));
    const site = gen.addOutputDirectoryArg("site");
    declare_inputs(b, gen, "app");
    declare_inputs(b, gen, "home");
    declare_inputs(b, gen, "viewer");
    declare_inputs(b, gen, "design");
    declare_inputs(b, gen, "dashboard");
    declare_inputs(b, gen, "content");
    declare_inputs(b, gen, "system");
    // Content mode loads the block editor's documents with its own model and blocks,
    // read-only (../../editor; see .agents/specs/publr-design-flow.md, "As built").
    for ([_][]const u8{ "model", "blocks", "harness", "canvas", "tests/manual", "design/model" }) |dir| {
        declare_inputs(b, gen, b.fmt("../../editor/{s}", .{dir}));
    }
    declare_inputs(b, gen, "../../ui/src");
    declare_inputs(b, gen, "../../ui/gallery/app/runtime");
    declare_inputs(b, gen, "../../ui/gallery/app/styles");
    declare_inputs(b, gen, "../../icons/src");
    declare_inputs(b, gen, "../../publr-js/dist");
    gen.addFileInput(b.path("../../jit/src/default-theme.zon"));

    const install = b.addInstallDirectory(.{
        .source_dir = site,
        .install_dir = .prefix,
        .install_subdir = "site",
    });
    b.getInstallStep().dependOn(&install.step);
}

/// A directory argument is hashed by path, so every file under it is declared as an
/// input and an edit anywhere re-runs the tool.
fn declare_inputs(b: *std.Build, run: *std.Build.Step.Run, dir: []const u8) void {
    const io = b.graph.io;
    const base = b.pathFromRoot(dir);
    var handle = std.Io.Dir.cwd().openDir(io, base, .{
        .iterate = true,
    }) catch {
        std.debug.panic("design inputs: cannot open {s}", .{base});
    };
    defer handle.close(io);
    var walker = handle.walk(b.allocator) catch @panic("out of memory");
    defer walker.deinit();
    while (walker.next(io) catch @panic("cannot walk the design inputs")) |entry| {
        if (entry.kind == .file) {
            run.addFileInput(.{
                .cwd_relative = b.pathJoin(&.{ base, b.dupe(entry.path) }),
            });
        }
    }
}
