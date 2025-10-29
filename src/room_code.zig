const std = @import("std");

const v2characters = "QWXRTYLPESDFGHUJKZOCVBINMA";
const v2indices: []const u32 = &.{ 25, 21, 19, 10, 8, 11, 12, 13, 22, 15, 16, 6, 24, 23, 18, 7, 0, 3, 9, 4, 14, 20, 1, 2, 5, 17 };

pub const RoomCode = union(enum) {
    v1: u32,
    v2: u32,

    pub fn fromInt(id: i32) RoomCode {
        return if (id >= 0) return .{ .v1 = @bitCast(id) } else .{ .v2 = @bitCast(id) };
    }

    pub fn asInt(self: RoomCode) i32 {
        return switch (self) {
            inline else => |id| @bitCast(id),
        };
    }

    fn fromV2Parts(a: u32, b: u32, c: u32, d: u32, e: u32, f: u32) RoomCode {
        const one = (a + 26 * b) & 0x3ff;
        const two = c + 26 * (d + 26 * (e + 26 * f));

        return .{ .v2 = one | ((two << 10) & 0x3ffffc00) | 0x80000000 };
    }

    pub fn fromSlice(slice: []const u8) !RoomCode {
        switch (slice.len) {
            4 => {
                return .{ .v1 = std.mem.bytesToValue(u32, slice[0..4]) };
            },
            6 => {
                const a = v2indices[slice[0] - 'A'];
                const b = v2indices[slice[1] - 'A'];
                const c = v2indices[slice[2] - 'A'];
                const d = v2indices[slice[3] - 'A'];
                const e = v2indices[slice[4] - 'A'];
                const f = v2indices[slice[5] - 'A'];

                return .fromV2Parts(a, b, c, d, e, f);
            },
            else => return error.InvalidLength,
        }
    }

    pub fn format(self: RoomCode, writer: *std.Io.Writer) !void {
        switch (self) {
            .v1 => |id| {
                const ascii_bytes: [4]u8 = std.mem.toBytes(id);
                try writer.print("{s}", .{ascii_bytes});
            },
            .v2 => |id| {
                const a = id & 0x3ff;
                const b = (id >> 10) & 0xfffff;

                try writer.print("{c}{c}{c}{c}{c}{c}", .{
                    v2characters[a % 26],
                    v2characters[@divFloor(a, 26)],
                    v2characters[b % 26],
                    v2characters[@divFloor(b, 26) % 26],
                    v2characters[@divFloor(b, 26 * 26) % 26],
                    v2characters[@divFloor(b, 26 * 26 * 26) % 26],
                });
            },
        }
    }
};
