const std = @import("std");
const hazel = @import("hazel");

const ClientVersion = @import("./ClientVersion.zig");
const RoomCode = @import("./room_code.zig").RoomCode;

const log = std.log.scoped(.legume);

pub const Client = struct {
    client_version: ClientVersion,
    connection: hazel.server.Connection,
};

pub const RootMessageTag = enum(u8) {
    host_game,
    join_game,
    start_game,
    remove_game,
    remove_player,
    game_data,
    game_data_to,
    joined_game,
    end_game,
    get_game_list_v1,
    alter_game,
    kick_player,
    wait_for_host,
    redirect,
    master_server_list,
    get_game_list_v2 = 16,
    report_player,
    set_game_session = 20,
    set_active_pod_type,
    query_platform_ids,
    query_lobby_info,
};

const Handler = struct {
    server: *hazel.Server(*Handler),
    pool: std.heap.MemoryPool(Client),

    pub fn acceptConnection(self: *Handler, connection: hazel.server.Connection, reader: *std.Io.Reader) !*hazel.server.Connection {
        const client = try self.pool.create();

        _ = try reader.discardAll(1);

        const client_version: ClientVersion = .parseFromInt(try reader.takeInt(u32, .little));

        log.info("Client connected, version: {f}", .{client_version});

        client.* = .{
            .client_version = client_version,
            .connection = connection,
        };

        return &client.connection;
    }

    pub fn readNormal(self: *Handler, connection: *hazel.server.Connection, is_reliable: bool, reader: *std.Io.Reader) !void {
        while (reader.bufferedLen() > 0) {
            var message = try hazel.takeMessage(RootMessageTag, reader);

            switch (message.tag) {
                .host_game => {
                    const room_code: RoomCode = try .fromSlice("REDSUS");

                    connection.send_mutex.lock();
                    defer connection.send_mutex.unlock();

                    const pooled_buffer = try self.server.takeBufferAsOption(connection, .reliable);

                    const host_game = try hazel.beginMessage(&pooled_buffer.writer, 0);
                    try pooled_buffer.writer.writeInt(i32, room_code.asInt(), .little);
                    try hazel.endMessage(&pooled_buffer.writer, host_game);

                    try self.server.sendExpectAck(connection, pooled_buffer);
                },
                .join_game => {
                    const room_id = try reader.takeInt(i32, .little);
                    const room_code: RoomCode = .fromInt(room_id);

                    log.info("Client trying to join room {f}", .{room_code});
                },
                else => {},
            }

            try message.discardRemaining();
        }
        _ = is_reliable;
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
        .server = undefined,
        .pool = .init(allocator),
    };

    var message_buffer: [4096]u8 = undefined;
    var server: hazel.Server(*Handler) = try .init(allocator, &message_buffer, &handler);
    handler.server = &server;
    defer server.deinit();

    try server.listenInAnotherThread(22023);

    std.Thread.sleep(30 * std.time.ns_per_s);
}
