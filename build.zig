const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const chameleon = b.dependency("chameleon", .{
        .target = target,
        .optimize = optimize,
    }).module("chameleon");
    const zeit = b.dependency("zeit", .{
        .target = target,
        .optimize = optimize,
    }).module("zeit");
    const axe = b.addModule("axe", .{
        .root_source_file = b.path("src/axe.zig"),
        .optimize = optimize,
        .target = target,
    });
    axe.addImport("chameleon", chameleon);
    axe.addImport("zeit", zeit);
}
