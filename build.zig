const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const edge_commit = b.option([]const u8, "edge-commit", "Full commit SHA of an edge channel build") orelse "";
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "edge_commit", edge_commit);
    const build_options_mod = build_options.createModule();

    const c_mod = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    }).createModule();

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (target.result.os.tag == .macos) root_mod.linkSystemLibrary("sqlite3", .{});
    root_mod.link_libc = true;
    root_mod.addImport("c", c_mod);
    root_mod.addImport("build_options", build_options_mod);

    const exe = b.addExecutable(.{
        .name = "csw",
        .root_module = root_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run csw");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (target.result.os.tag == .macos) test_mod.linkSystemLibrary("sqlite3", .{});
    test_mod.link_libc = true;
    test_mod.addImport("c", c_mod);
    test_mod.addImport("build_options", build_options_mod);

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
