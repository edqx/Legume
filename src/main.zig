const std = @import("std");
const hazel = @import("hazel");

const Room = @import("./Room.zig");
const Legume = @import("./Legume.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();

    var room: Room = undefined;

    try room.initSpawn();

    var legume: Legume = .{
        .hazel_server = undefined,
        .pool = .init(allocator),
    };

    var message_buffer: [4096]u8 = undefined;
    try legume.hazel_server.init(allocator, &message_buffer);
    defer legume.hazel_server.deinit();

    try legume.hazel_server.listenInAnotherThread(22023);

    std.Thread.sleep(30 * std.time.ns_per_s);
}
