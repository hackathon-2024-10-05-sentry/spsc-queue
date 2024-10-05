const std = @import("std");

pub fn build(b: *std.Build) void {
    const zig_bench = b.createModule(.{
        .root_source_file = b.path("zig-bench/bench.zig"),
    });

    const maolonglong_spsc_queue = b.createModule(.{ .root_source_file = b.path("third-party/maolonglong/spsc_queue/src/spsc_queue.zig") });

    // Add the two new libraries here
    const spscqueue = b.createModule(.{
        .root_source_file = b.path("src/queue/spscqueue.zig"),
    });

    const spscqueueslot = b.createModule(.{
        .root_source_file = b.path("src/queue/spscqueueslot.zig"),
    });

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "spsc-queue",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "spsc-queue",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("bench", zig_bench);

    // Import the new libraries into the executable
    exe.root_module.addImport("queue/spscqueue", spscqueue);
    exe.root_module.addImport("queue/spscqueueslot", spscqueueslot);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Unit testing for libraries
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // Unit testing for executable
    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_unit_tests.root_module.addImport("bench", zig_bench);
    exe_unit_tests.root_module.addImport("maolonglong/spsc_queue", maolonglong_spsc_queue);

    // Import the new libraries into the test executable
    exe_unit_tests.root_module.addImport("queue/spscqueue", spscqueue);
    exe_unit_tests.root_module.addImport("queue/spscqueueslot", spscqueueslot);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
