const std = @import("std");

pub const server = @import("server.zig");
pub const Server = server.Server;

pub const SendOption = enum(u8) {
    unreliable = 0,
    reliable = 1,
    hello = 8,
    disconnect = 9,
    acknowledge = 10,
    ping = 12,
};

// We're relying on the fact that we only ever use writers/readers into fixed buffers
// in our hazel implementation.
pub fn Message(comptime TagType: type) type {
    return struct {
        tag: TagType,
        limited_reader: std.Io.Reader.Limited,

        pub fn discardRemaining(self: *@This()) !void {
            _ = try self.limited_reader.unlimited.discard(self.limited_reader.remaining);
        }
    };
}

pub fn takeMessage(TagType: type, reader: *std.Io.Reader) !Message(TagType) {
    const length = try reader.takeInt(u16, .little);
    const tag = try reader.takeEnum(TagType, .little);

    return .{
        .tag = tag,
        // We don't need a buffer since we're reading from a fixed in-memory buffer anyway,
        // so there's no syscalls where it may be optimal to buffer through.
        .limited_reader = .init(reader, .limited(length), &.{}),
    };
}

pub fn beginMessage(writer: *std.Io.Writer, tag: u8) !usize {
    const pos = writer.end;
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u8, tag, .little);
    return pos;
}

pub fn endMessage(writer: *std.Io.Writer, pos: usize) !void {
    const message_len = writer.end - pos - 3;
    if (message_len > std.math.maxInt(u16)) return error.MessageTooLarge;

    const restore = writer.end;
    writer.end = pos;
    try writer.writeInt(u16, @intCast(message_len), .little);
    writer.end = restore;
}
