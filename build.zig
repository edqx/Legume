const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const win32 = b.dependency("win32", .{});
    const hazel = b.dependency("hazel", .{});

    const legume_module = b.addModule("hazel", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hazel", .module = hazel.module("hazel") },
            .{ .name = "win32", .module = win32.module("win32") },
        },
        // .link_libc = true,
    });

    const legume_executable = b.addExecutable(.{
        .name = "Legume",
        .root_module = legume_module,
    });

    b.installArtifact(legume_executable);
}
