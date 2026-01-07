const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Backend module - this is your Zig code in the backend/ directory
    const backend_mod = b.addModule("backend", .{
        .root_source_file = b.path("backend/root.zig"),
        .target = target,
    });

    // Executable that uses the backend
    const exe = b.addExecutable(.{
        .name = "cranium",
        .root_module = b.createModule(.{
            .root_source_file = b.path("backend/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "backend", .module = backend_mod },
            },
        }),
    });

    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Tests for backend module
    const backend_tests = b.addTest(.{
        .root_module = backend_mod,
    });

    const run_backend_tests = b.addRunArtifact(backend_tests);

    // Tests for executable
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Test step runs all tests
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_backend_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Check step for ZLS build-on-save feature
    // This allows ZLS to compile and check for errors on save
    // We check both the backend module and the main executable
    const check_step = b.step("check", "Check the code for errors");
    
    // Check the backend module by creating a test that imports it
    const backend_check = b.addTest(.{
        .root_module = backend_mod,
    });
    check_step.dependOn(&b.addRunArtifact(backend_check).step);
    
    // Also check the main executable
    const check_exe = b.addExecutable(.{
        .name = "check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("backend/main.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "backend", .module = backend_mod },
            },
        }),
    });
    check_step.dependOn(&b.addInstallArtifact(check_exe, .{}).step);
}
