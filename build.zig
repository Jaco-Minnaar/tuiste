const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zg = b.dependency("zg", .{});

    // The public `tuiste` module — the library itself.
    const mod = b.addModule("tuiste", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "Graphemes", .module = zg.module("Graphemes") },
            .{ .name = "DisplayWidth", .module = zg.module("DisplayWidth") },
            .{ .name = "code_point", .module = zg.module("code_point") },
        },
    });

    const demo = b.addExecutable(.{
        .name = "demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tuiste", .module = mod },
            },
        }),
    });
    b.installArtifact(demo);

    const run_step = b.step("run", "Run the demo example");
    const run_cmd = b.addRunArtifact(demo);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
