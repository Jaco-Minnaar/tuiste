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

    const examples = [_]struct { name: []const u8, src: []const u8, step: []const u8, desc: []const u8 }{
        .{ .name = "demo", .src = "examples/demo.zig", .step = "run", .desc = "Run the demo example" },
        .{ .name = "input", .src = "examples/input.zig", .step = "input", .desc = "Run the text-input example" },
    };
    for (examples) |ex| {
        const exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex.src),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "tuiste", .module = mod },
                },
            }),
        });
        b.installArtifact(exe);

        const step = b.step(ex.step, ex.desc);
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        step.dependOn(&run_cmd.step);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
