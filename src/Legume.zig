const std = @import("std");
const hazel = @import("hazel");

const ClientVersion = @import("./ClientVersion.zig");
const RoomCode = @import("./room_code.zig").RoomCode;

const Room = @import("./Room.zig");

const Legume = @This();

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

hazel_server: hazel.Server(Legume),
pool: std.heap.MemoryPool(Client),

pub fn acceptConnection(hazel_server: *hazel.Server(Legume), connection: hazel.server.Connection, reader: *std.Io.Reader) !*hazel.server.Connection {
    const self: *Legume = @fieldParentPtr("hazel_server", hazel_server);

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

pub fn readNormal(hazel_server: *hazel.Server(Legume), connection: *hazel.server.Connection, is_reliable: bool, reader: *std.Io.Reader) !void {
    const self: *Legume = @fieldParentPtr("hazel_server", hazel_server);

    while (reader.bufferedLen() > 0) {
        var message = try hazel.takeMessage(RootMessageTag, reader);

        switch (message.tag) {
            .host_game => {
                const room_code: RoomCode = try .fromSlice("REDSUS");

                connection.send_mutex.lock();
                defer connection.send_mutex.unlock();

                const pooled_buffer = try self.hazel_server.takeBufferAsOption(connection, .reliable);

                const host_game = try hazel.beginMessage(&pooled_buffer.writer, 0);
                try pooled_buffer.writer.writeInt(i32, room_code.asInt(), .little);
                try hazel.endMessage(&pooled_buffer.writer, host_game);

                try self.hazel_server.sendExpectAck(connection, pooled_buffer);
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

pub fn disconnectConnection(hazel_server: *hazel.Server(Legume), connection: *hazel.server.Connection) !void {
    const self: *Legume = @fieldParentPtr("hazel_server", hazel_server);

    const client: *Client = @fieldParentPtr("connection", connection);
    self.pool.destroy(client);
}
