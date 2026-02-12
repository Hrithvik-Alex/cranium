const std = @import("std");

fn addMacFrameworkPaths(b: *std.Build, lib: *std.Build.Step.Compile) void {
    if (lib.root_module.resolved_target.?.result.os.tag != .macos) return;

    var sdk_path_opt: ?[]const u8 = null;
    if (std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" },
    }) catch null) |result| {
        defer b.allocator.free(result.stdout);
        defer b.allocator.free(result.stderr);
        if (result.term.Exited == 0) {
            const trimmed = std.mem.trimRight(u8, result.stdout, "\r\n");
            sdk_path_opt = b.allocator.dupe(u8, trimmed) catch null;
        }
    }

    if (sdk_path_opt) |sdk| {
        defer b.allocator.free(sdk);
        const framework_path = b.pathJoin(&.{ sdk, "System/Library/Frameworks" });
        lib.addSystemFrameworkPath(.{ .cwd_relative = framework_path });
    }

    lib.addSystemFrameworkPath(.{ .cwd_relative = "/System/Library/Frameworks" });
    lib.addSystemFrameworkPath(.{ .cwd_relative = "/Library/Frameworks" });
}

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

    // ============================================
    // Static library for Swift/Xcode consumption
    // ============================================
    // Build for macOS (both ARM and Intel)
    const macos_aarch64_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
    });

    const macos_x86_64_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .macos,
    });

    // ARM64 (Apple Silicon) static library
    const lib_aarch64 = b.addLibrary(.{
        .linkage = .static,
        .name = "cranium",
        .root_module = b.createModule(.{
            .root_source_file = b.path("backend/exports.zig"),
            .target = macos_aarch64_target,
            .optimize = optimize,
        }),
    });
    addMacFrameworkPaths(b, lib_aarch64);
    lib_aarch64.linkFramework("CoreText");
    lib_aarch64.linkFramework("CoreGraphics");
    lib_aarch64.linkFramework("CoreFoundation");
    lib_aarch64.linkFramework("Metal");
    lib_aarch64.linkFramework("QuartzCore");

    // x86_64 (Intel) static library
    const lib_x86_64 = b.addLibrary(.{
        .linkage = .static,
        .name = "cranium_x86_64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("backend/exports.zig"),
            .target = macos_x86_64_target,
            .optimize = optimize,
        }),
    });
    addMacFrameworkPaths(b, lib_x86_64);
    lib_x86_64.linkFramework("CoreText");
    lib_x86_64.linkFramework("CoreGraphics");
    lib_x86_64.linkFramework("CoreFoundation");
    lib_x86_64.linkFramework("Metal");
    lib_x86_64.linkFramework("QuartzCore");

    // Install both libraries
    const install_lib_aarch64 = b.addInstallArtifact(lib_aarch64, .{});
    const install_lib_x86_64 = b.addInstallArtifact(lib_x86_64, .{});

    // Install the C header
    const install_header = b.addInstallHeaderFile(b.path("include/cranium.h"), "cranium.h");

    // Create a "lib" step that builds the static library + header
    const lib_step = b.step("lib", "Build static library for Swift/Xcode");
    lib_step.dependOn(&install_lib_aarch64.step);
    lib_step.dependOn(&install_lib_x86_64.step);
    lib_step.dependOn(&install_header.step);

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
