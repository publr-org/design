//! Bring in, step 1: a design system read from any source design file. A research
//! program, not part of the engine: it reads sources through the engine's `.fig`
//! importer and Pubd reader, and writes Pubd through its writer; nothing Publr-specific
//! goes into the engine.
//!
//!   zig build -Doptimize=ReleaseFast
//!   zig-out/bin/bring-in gather <source.fig | doc.pubd> <evidence.json>
//!   zig-out/bin/bring-in build <plan.json> <out.pubd>
//!   zig-out/bin/bring-in verify <evidence.json> <plan.json> <coverage.json>

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const engine = b.dependency("publr_engine", .{
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "bring-in",
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
    run.addPassthruArgs();
    b.step("run", "Run bring-in").dependOn(&run.step);
}
