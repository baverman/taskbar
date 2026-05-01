const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "taskbar",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
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
}
