const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "taskbar",
        .root_module = exe_module,
        .use_llvm = true,
    });

    exe.linkSystemLibrary2("pangocairo-1.0", .{ .use_pkg_config = .force });
    exe.linkSystemLibrary2("cairo", .{ .use_pkg_config = .force });
    exe.linkSystemLibrary2("X11", .{ .use_pkg_config = .force });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the panel");
    run_step.dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/layout_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const tests = b.addTest(.{
        .root_module = test_module,
        .use_llvm = true,
    });
    tests.linkSystemLibrary2("pangocairo-1.0", .{ .use_pkg_config = .force });
    tests.linkSystemLibrary2("cairo", .{ .use_pkg_config = .force });
    tests.linkSystemLibrary2("X11", .{ .use_pkg_config = .force });

    const test_run = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&test_run.step);
}
