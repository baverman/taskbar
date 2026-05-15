const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const translate_c = b.dependency("translate_c", .{
        .target = target,
        .optimize = .Debug,
    });
    const zix11 = b.dependency("zix11", .{
        .target = target,
        .optimize = optimize,
    });
    const c_headers: Translator = .init(translate_c, .{
        .name = "x11",
        .c_source_file = b.path("src/x11.h"),
        .target = target,
        .optimize = optimize,
    });
    c_headers.linkSystemLibrary("cairo", .{ .use_pkg_config = .force });

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_module.addImport("c", c_headers.mod);
    exe_module.addImport("zix11", zix11.module("zix11"));

    const exe = b.addExecutable(.{
        .name = "taskbar",
        .root_module = exe_module,
    });

    exe_module.linkSystemLibrary("pangocairo-1.0", .{ .use_pkg_config = .force });
    exe_module.linkSystemLibrary("cairo", .{ .use_pkg_config = .force });

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
    test_module.addImport("c", c_headers.mod);
    test_module.addImport("zix11", zix11.module("zix11"));

    const tests = b.addTest(.{
        .root_module = test_module,
        // .use_llvm = true,
    });
    test_module.linkSystemLibrary("pangocairo-1.0", .{ .use_pkg_config = .force });
    test_module.linkSystemLibrary("cairo", .{ .use_pkg_config = .force });

    const test_run = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&test_run.step);
}
