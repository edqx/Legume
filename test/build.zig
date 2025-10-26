const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const hazel = b.dependency("hazel", .{});

    const testtest = b.addModule("hazel", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hazel", .module = hazel.module("hazel") },
        },
    });

    const testtestexe = b.addExecutable(.{
        .name = "testtest",
        .root_module = testtest,
    });

    b.installArtifact(testtestexe);
}
