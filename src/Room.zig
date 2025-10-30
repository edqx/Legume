const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32").everything;

const Room = @This();

const log = std.log.scoped(.legume_room);

fixed_update_thread: std.Thread,
delta_seconds: f64,

pub fn initSpawn(self: *Room) !void {
    self.fixed_update_thread = try .spawn(.{}, fixedUpdateMain, .{self});
    self.delta_seconds = 0;
}

pub fn fixedUpdateMain(self: *Room) void {
    fixedUpdateInterval(self) catch |e| {
        log.err("{}", .{e});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace);
        }
    };
}

pub fn fixedUpdateInterval(self: *Room) !void {
    const fixed_hz = 50;
    const tick_duration = @as(f64, 1.0) / @as(f64, fixed_hz);
    const sleep_heuristic = @max(@divFloor(1000, fixed_hz) - 4, 0);

    switch (builtin.os.tag) {
        .windows => {
            _ = win32.timeBeginPeriod(1);
            defer _ = win32.timeEndPeriod(1);

            var ifrequency: win32.LARGE_INTEGER = undefined;
            if (win32.QueryPerformanceFrequency(&ifrequency) == win32.FALSE) {
                return error.CouldNotQueryPerformanceCounter;
            }

            const frequency: f64 = @floatFromInt(ifrequency.QuadPart);

            var last_tick: win32.LARGE_INTEGER = undefined;
            var current_tick: win32.LARGE_INTEGER = undefined;

            if (win32.QueryPerformanceCounter(&last_tick) == win32.FALSE) {
                return error.CouldNotQueryPerformanceCounter;
            }

            while (true) {
                defer self.delta_seconds = 0;
                std.Thread.sleep(std.time.ns_per_ms * sleep_heuristic);

                while (self.delta_seconds < tick_duration) {
                    defer last_tick = current_tick;

                    if (win32.QueryPerformanceCounter(&current_tick) == win32.FALSE) {
                        return error.CouldNotQueryPerformanceCounter;
                    }
                    const num_ticks: f64 = @floatFromInt(current_tick.QuadPart - last_tick.QuadPart);
                    self.delta_seconds += num_ticks / frequency;
                }

                try self.fixedUpdate();
            }
        },
        else => {
            var last_time: std.posix.timespec = try std.posix.clock_gettime(.MONOTONIC);
            var current_time: std.posix.timespec = undefined;

            while (true) {
                self.delta_seconds = 0;
                std.Thread.sleep(std.time.ns_per_ms * sleep_heuristic);

                while (self.delta_seconds < tick_duration) {
                    defer last_time = current_time;
                    current_time = try std.posix.clock_gettime(.MONOTONIC);

                    const dif_seconds = current_time.sec - last_time.sec;
                    const dif_ns: f64 = @floatFromInt((current_time.nsec - last_time.nsec) + dif_seconds * std.time.ns_per_s);
                    self.delta_seconds += dif_ns / @as(f64, @floatFromInt(std.time.ns_per_s));
                }

                try self.fixedUpdate();
            }
        },
    }
}

pub fn fixedUpdate(self: *Room) !void {
    std.log.info("{d}", .{self.delta_seconds});
}
