const std = @import("std");
const hazel = @import("hazel");

const Client = struct {
    connection: hazel.server.Connection,
};

const Handler = struct {
    pool: std.heap.MemoryPool(Client),

    pub fn acceptConnection(self: *Handler, connection: hazel.server.Connection, reader: *std.Io.Reader) !*hazel.server.Connection {
        const client = try self.pool.create();

        var buffer: [4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);

        const num_bytes = try reader.streamRemaining(&writer);

        const remaining_bytes = buffer[0..num_bytes];

        std.log.info("bytes: {x}", .{remaining_bytes});

        client.* = .{
            .connection = connection,
        };

        return &client.connection;
    }
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();

    var handler: Handler = .{
        .pool = .init(allocator),
    };

    var message_buffer: [4096]u8 = undefined;
    var server: hazel.Server(*Handler) = try .init(allocator, &message_buffer, &handler);

    try server.listen(22023);
}
