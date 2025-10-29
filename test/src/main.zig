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

    pub fn readNormal(self: *Handler, connection: *hazel.server.Connection, is_reliable: bool, reader: *std.Io.Reader) !void {
        _ = self;
        _ = connection;
        _ = is_reliable;
        _ = reader;
    }

    pub fn disconnectConnection(self: *Handler, connection: *hazel.server.Connection) !void {
        const client: *Client = @fieldParentPtr("connection", connection);
        self.pool.destroy(client);
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
    defer server.deinit();

    try server.listenInAnotherThread(22023);

    std.Thread.sleep(30 * std.time.ns_per_s);
}
