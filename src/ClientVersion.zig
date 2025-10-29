const std = @import("std");

const ClientVersion = @This();

year: u32,
month: u32,
day: u32,
revision: u32,

pub fn parseFromInt(i: u32) ClientVersion {
    var num = i;
    var result: ClientVersion = undefined;
    result.year = @divFloor(num, 25000);
    num %= 25000;
    result.month = @divFloor(num, 1800);
    num %= 1800;
    result.day = @divFloor(num, 50);
    result.revision = num % 50;
    return result;
}

pub fn format(self: ClientVersion, writer: *std.Io.Writer) !void {
    try writer.print("{}.{}.{}-rev.{}", .{ self.year, self.month, self.day, self.revision });
}
