const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zeit = b.dependency("zeit", .{
        .target = target,
        .optimize = optimize,
    }).module("zeit");
    const axe = b.addModule("axe", .{
        .root_source_file = b.path("src/axe.zig"),
        .optimize = optimize,
        .target = target,
    });
    axe.addImport("zeit", zeit);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/axe.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("zeit", zeit);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    const docs_step = b.step("docs", "Generate documentation");
    const docs_obj = b.addObject(.{
        .name = "axe",
        .root_source_file = b.path("src/axe.zig"),
        .target = target,
        .optimize = optimize,
    });
    const docs = docs_obj.getEmittedDocs();
    docs_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = docs,
        .install_dir = .prefix,
        .install_subdir = "docs",
    }).step);
}
