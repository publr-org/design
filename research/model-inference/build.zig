//! Model inference measurement: a research program, not part of the engine. It reads
//! `.pubd` files through the engine's own Pubd reader; nothing Publr-specific goes into
//! the engine.
//!
//!   zig build run -- <label> <doc.pubd-dir> <out.json>

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const engine = b.dependency("publr_engine", .{
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "model-inference",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "publr_engine",
                    .module = engine.module("publr_engine"),
                },
            },
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the inference on one file").dependOn(&run.step);
}
