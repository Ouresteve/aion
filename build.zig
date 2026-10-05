const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target and optimization options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the main library module
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create the executable
    const exe = b.addExecutable(.{
        .name = "aion",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Make the executable depend on our library
    exe.root_module.addImport("aion", lib_mod);

    // Install the executable so `zig build` produces it
    b.installArtifact(exe);

    // Add a "run" step: zig build run
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
   //  New Zig 0.17+ code:
run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the Aion node");
    run_step.dependOn(&run_cmd.step);

    // Add unit tests
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}