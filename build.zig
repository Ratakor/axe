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
    const clog = b.addModule("clog", .{
        .root_source_file = b.path("src/clog.zig"),
        .optimize = optimize,
        .target = target,
    });
    clog.addImport("chameleon", chameleon);
    clog.addImport("zeit", zeit);
}
