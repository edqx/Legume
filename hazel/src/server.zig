const std = @import("std");
const network = @import("network");

const SendOption = @import("./root.zig").SendOption;

const log = std.log.scoped(.hazel_server);

const max_out_of_order = 10;
const ping_interval_seconds = 2;

const max_send_size = 4096;

pub const OutOfOrderMessage = struct {
    send_option: SendOption,
    assert_nonce: u16,
    message_data_buffer: []u8,
};

pub const PooledBufferNode = struct {
    node: std.DoublyLinkedList.Node,
    buffer: []u8,
    writer: std.Io.Writer,
};

pub const Connection = struct {
    endpoint: network.EndPoint,

    // send data
    send_mutex: std.Thread.Mutex = .{},
    next_send_nonce: u16 = 0,
    acknowledged_packets_bitfield: u8 = 0b11111111,
    unacknowledged_packet_buffers: std.DoublyLinkedList = .{}, // these correlate to the 0 bits in the above bitfield

    // receive data
    expected_nonce: u16 = 0,
    out_of_order_messages: [max_out_of_order]?OutOfOrderMessage = @splat(null),

    pub fn format(self: *Connection, writer: *std.Io.Writer) !void {
        try writer.print("{f}", .{self.endpoint});
    }

    pub fn takeSendNonce(self: *Connection) u16 {
        return @atomicRmw(u16, &self.next_send_nonce, .Add, 1, .seq_cst);
    }

    pub fn expectNextNonce(self: *Connection) void {
        self.expected_nonce +%= 1;
    }
};

pub fn Server(comptime Handler: type) type {
    return struct {
        const ServerT = @This();

        allocator: std.mem.Allocator,

        socket: network.Socket,
        set: network.SocketSet,

        mutex: std.Thread.Mutex = .{},
        connections: std.AutoHashMapUnmanaged(network.EndPoint, *Connection),

        message_buffer: []u8,

        send_buffer_pool: std.DoublyLinkedList = .{},

        maybe_ping_thread: ?std.Thread,
        maybe_listen_thread: ?std.Thread,
        closed_flag: std.atomic.Value(u32),

        pub fn init(self: *ServerT, allocator: std.mem.Allocator, message_buffer: []u8) !void {
            self.* = .{
                .allocator = allocator,
                .socket = try .create(.ipv4, .udp),
                .set = try .init(allocator),
                .message_buffer = message_buffer,
                .connections = .empty,
                .maybe_ping_thread = null,
                .maybe_listen_thread = null,
                .closed_flag = .init(0),
            };
        }

        pub fn deinit(self: *ServerT) void {
            self.closed_flag.store(1, .seq_cst);
            if (self.maybe_ping_thread) |thread| thread.join();
            if (self.maybe_listen_thread) |thread| thread.join();

            var maybe_node = self.send_buffer_pool.first;
            while (maybe_node) |node| {
                const pooled_buffer: *PooledBufferNode = @fieldParentPtr("node", node);
                self.allocator.free(pooled_buffer.buffer);
                maybe_node = node.next;
            }

            self.connections.deinit(self.allocator);
            self.set.deinit();
            self.socket.close();
        }

        pub fn nextHandle(self: *ServerT) usize {
            defer self.incrementing_handle += 1;
            return self.incrementing_handle;
        }

        pub fn bindStartPing(self: *ServerT, port: u16) !void {
            try self.socket.bind(.{ .address = try .parse("0.0.0.0"), .port = port });
            try self.set.add(self.socket, .{ .read = true, .write = false });

            self.maybe_ping_thread = try std.Thread.spawn(.{}, pingLoop, .{self});
        }

        pub fn listen(self: *ServerT, port: u16) !void {
            try self.bindStartPing(port);
            try self.listenLoop();
        }

        pub fn listenInAnotherThread(self: *ServerT, port: u16) !void {
            try self.bindStartPing(port);
            self.maybe_listen_thread = try std.Thread.spawn(.{}, listenLoop, .{self});
        }

        pub fn listenLoop(self: *ServerT) !void {
            while (true) {
                const result = try network.waitForSocketEvent(&self.set, std.time.ns_per_ms * 500);
                if (result == 0) { // no sockets with read ready
                    if (self.closed_flag.raw == 1) break;
                    continue;
                }

                const receive = try self.socket.receiveFrom(self.message_buffer);
                const message_slice = self.message_buffer[0..receive.numberOfBytes];

                var reader: std.Io.Reader = .fixed(message_slice);
                self.readOption(receive.sender, &reader) catch |e| switch (e) {
                    error.ReadFailed => break, // todo: this is probably fatal, but research to make sure
                    error.EndOfStream => continue, // todo: log bad message
                    else => return e,
                };
            }
        }

        pub fn pingLoop(self: *ServerT) !void {
            main_loop: while (true) {
                var connections_to_disconnect: std.ArrayListUnmanaged(*Connection) = .empty;

                {
                    self.mutex.lock();
                    defer self.mutex.unlock();

                    var connections_iter = self.connections.valueIterator();
                    while (connections_iter.next()) |connection_ptr| {
                        const connection = connection_ptr.*;

                        connection.send_mutex.lock();
                        defer connection.send_mutex.unlock();

                        if (connection.acknowledged_packets_bitfield == 0x00) {
                            try connections_to_disconnect.append(self.allocator, connection);
                            continue;
                        }

                        var unacknowledged_packet_ll_node = connection.unacknowledged_packet_buffers.first;
                        for (0..@bitSizeOf(u8)) |i| {
                            if ((connection.acknowledged_packets_bitfield & (@as(u8, 1) << @intCast(i))) == 0) {
                                const pooled_buffer: *PooledBufferNode = @fieldParentPtr("node", unacknowledged_packet_ll_node.?);
                                try self.sendRaw(connection, pooled_buffer.writer.buffered());
                                unacknowledged_packet_ll_node = unacknowledged_packet_ll_node.?.next;
                            }
                        }

                        const pooled_buffer = try self.takeBufferAsOption(connection, .ping);
                        try self.sendExpectAck(connection, pooled_buffer);
                    }
                }

                for (connections_to_disconnect.items) |connection| {
                    try self.disconnectConnection(connection);
                }

                while (self.closed_flag.raw == 0) {
                    std.Thread.Futex.timedWait(&self.closed_flag, 0, std.time.ns_per_s * ping_interval_seconds) catch |e| switch (e) {
                        error.Timeout => continue :main_loop,
                    };
                }
                break;
            }
        }

        pub fn readOption(self: *ServerT, sender_endpoint: network.EndPoint, reader: *std.Io.Reader) !void {
            const send_option = reader.takeEnum(SendOption, .little) catch |e| switch (e) {
                error.InvalidEnumTag => {
                    log.err("Got an invalid send option from {f} - is this a Hazel connection?", .{sender_endpoint});
                    return;
                },
                else => return e,
            };

            const result = safe_fetch: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :safe_fetch try self.connections.getOrPut(self.allocator, sender_endpoint);
            };

            if (result.found_existing) {
                const connection = result.value_ptr.*;

                switch (send_option) {
                    .unreliable => {
                        try self.processNormal(connection, false, reader);
                    },
                    .reliable, .hello, .ping => {
                        try self.acknowledgeAndProcessReliable(connection, send_option, reader);
                    },
                    .disconnect => {
                        try self.disconnectConnection(connection);
                    },
                    .acknowledge => {
                        try self.processAcknowledgement(connection, reader);
                    },
                }
            } else {
                if (send_option != .hello) {
                    log.err("Got non-hello from first-time sender {f}", .{sender_endpoint});
                    std.debug.assert(self.connections.remove(sender_endpoint));
                    return;
                }

                const nonce = try reader.takeInt(u16, .big);

                const sender_connection: Connection = .{
                    .endpoint = sender_endpoint,
                    .expected_nonce = nonce +% 1,
                };

                result.value_ptr.* = try Handler.acceptConnection(self, sender_connection, reader);
                try self.acknowledgeReliable(result.value_ptr.*, nonce);
            }
        }

        pub fn acknowledgeAndProcessReliable(self: *ServerT, connection: *Connection, send_option: SendOption, reader: *std.Io.Reader) !void {
            const nonce = try reader.takeInt(u16, .big);

            if (send_option == .hello) {
                connection.expected_nonce = nonce +% 1;
            } else {
                if (nonce < connection.expected_nonce) {
                    log.warn("Connection {[sender]f} sent a duplicate {[option]} message: got {[nonce]}", .{
                        .sender = connection,
                        .option = send_option,
                        .nonce = nonce,
                    });
                    try self.acknowledgeReliable(connection, nonce);
                    return;
                } else if (nonce > connection.expected_nonce) {
                    if (try self.pushToOutOfOrderBuffer(connection, send_option, nonce, reader)) {
                        try self.acknowledgeReliable(connection, nonce);
                    }
                    return;
                }

                connection.expectNextNonce();
            }

            try self.acknowledgeReliable(connection, nonce);
            try self.processReliable(connection, send_option, reader);
            try self.flushOutOfOrderBuffer(connection);
            return;
        }

        pub fn pushToOutOfOrderBuffer(self: *ServerT, connection: *Connection, send_option: SendOption, nonce: u16, reader: *std.Io.Reader) !bool {
            const buffer_idx = nonce - connection.expected_nonce - 1;
            const defeats_buffer = buffer_idx >= max_out_of_order;

            if (defeats_buffer) {
                log.err("Connection {[sender]f} has sent a {[option]} wholly out-of-order message: got {[nonce]}, expected {[expected_nonce]}", .{
                    .sender = connection,
                    .option = send_option,
                    .nonce = nonce,
                    .expected_nonce = connection.expected_nonce,
                });
                return false; // we won't even acknowledge this one
            } else {
                log.warn("Connection {[sender]f} sent a {[option]} message out-of-order: got {[nonce]}, expected {[expected_nonce]}", .{
                    .sender = connection,
                    .option = send_option,
                    .nonce = nonce,
                    .expected_nonce = connection.expected_nonce,
                });
            }

            if (connection.out_of_order_messages[buffer_idx] != null) {
                log.warn("Connection {[sender]f} sent a duplicate {[option]} out-of-order message: got {[nonce]}, expected {[expected_nonce]}", .{
                    .sender = connection,
                    .option = send_option,
                    .nonce = nonce,
                    .expected_nonce = connection.expected_nonce,
                });
                return true;
            }

            var capacity_array_list: std.ArrayListUnmanaged(u8) = try .initCapacity(self.allocator, self.message_buffer.len);
            defer capacity_array_list.deinit(self.allocator);

            try reader.appendRemaining(self.allocator, &capacity_array_list, .limited(self.message_buffer.len));

            connection.out_of_order_messages[buffer_idx] = .{
                .send_option = send_option,
                .assert_nonce = nonce,
                .message_data_buffer = try capacity_array_list.toOwnedSlice(self.allocator),
            };
            return true;
        }

        pub fn flushOutOfOrderBuffer(self: *ServerT, connection: *Connection) !void {
            // TODO: more optimised way of checking if this buffer is empty: there are no out-of-order messages to process
            for (0.., connection.out_of_order_messages) |i, maybe_message| {
                const message = maybe_message orelse {
                    // we've reached the last message which is now in order
                    // let's discard all of the ones we've processed so far

                    //   0  1  2   3    4  5  6   7    8
                    // [ 2, 3, 4, null, 6, 7, 8, null, 10 ]
                    //
                    //   0  1  2   3    4    5     6     7     8
                    // [ 6, 7, 8, null, 10, null, null, null, null ]

                    const new_first_idx = i + 1;
                    const remaining = connection.out_of_order_messages.len - new_first_idx;

                    std.mem.copyForwards(?OutOfOrderMessage, connection.out_of_order_messages[0..remaining], connection.out_of_order_messages[new_first_idx..]);
                    for (connection.out_of_order_messages[remaining..]) |*unused| {
                        unused.* = null;
                    }
                    return;
                };

                std.debug.assert(connection.expected_nonce == message.assert_nonce);
                connection.expected_nonce %= 1;

                var reader: std.Io.Reader = .fixed(message.message_data_buffer);
                try self.processReliable(connection, message.send_option, &reader);
            }
            connection.out_of_order_messages = @splat(null);
        }

        pub fn processReliable(self: *ServerT, connection: *Connection, send_option: SendOption, reader: *std.Io.Reader) !void {
            switch (send_option) {
                .ping => {},
                .reliable => {
                    try self.processNormal(connection, true, reader);
                },
                .hello => {
                    log.err("Got duplicate hello from connection {f}", .{connection});
                },
                .unreliable, .acknowledge, .disconnect => unreachable,
            }
        }

        pub fn acknowledgeReliable(self: *ServerT, connection: *Connection, nonce: u16) !void {
            var pooled_buffer = try self.takeBufferAsOption(connection, .acknowledge);
            try pooled_buffer.writer.writeInt(u16, nonce, .big);
            try pooled_buffer.writer.writeByte(connection.acknowledged_packets_bitfield);

            _ = try self.sendNoAck(connection, pooled_buffer);
        }

        pub fn processNormal(self: *ServerT, connection: *Connection, reliable: bool, reader: *std.Io.Reader) !void {
            try Handler.readNormal(self, connection, reliable, reader);
        }

        pub fn processAcknowledgement(self: *ServerT, connection: *Connection, reader: *std.Io.Reader) !void {
            connection.send_mutex.lock();
            defer connection.send_mutex.unlock();

            const nonce = try reader.takeInt(u16, .big);
            if (nonce >= connection.next_send_nonce) return;
            const packet_idx = connection.next_send_nonce - 1 - nonce;

            if (packet_idx > @bitSizeOf(u8)) {
                log.warn("Got old acknowledgement for nonce {}. We don't care", .{nonce});
                return;
            }

            const bit = @as(u8, 1) << @intCast(packet_idx);

            if ((connection.acknowledged_packets_bitfield & bit) != 0) { // already acknowledged
                return;
            }

            // We need to find the unack'd packet buffer that this previously unack'd
            // nonce is for
            var ll_node = connection.unacknowledged_packet_buffers.first.?;
            for (0..packet_idx) |newer_packet_idx| {
                const bit2 = @as(u8, 1) << @intCast(newer_packet_idx);
                if ((connection.acknowledged_packets_bitfield & bit2) == 0) {
                    ll_node = ll_node.next.?;
                }
            }

            const pooled_buffer: *PooledBufferNode = @fieldParentPtr("node", ll_node);
            connection.unacknowledged_packet_buffers.remove(ll_node);
            connection.acknowledged_packets_bitfield |= bit;

            self.returnBufferToPool(pooled_buffer);
        }

        pub fn takeBufferFromPool(self: *ServerT) !*PooledBufferNode {
            if (self.send_buffer_pool.popFirst()) |node| {
                return @fieldParentPtr("node", node);
            }

            const buffer = try self.allocator.alloc(u8, 4096);

            const pooled = try self.allocator.create(PooledBufferNode);
            pooled.* = .{
                .buffer = buffer,
                .node = .{},
                .writer = .fixed(buffer),
            };
            return pooled;
        }

        pub fn returnBufferToPool(self: *ServerT, pooled_buffer: *PooledBufferNode) void {
            pooled_buffer.writer = .fixed(pooled_buffer.buffer);
            self.send_buffer_pool.prepend(&pooled_buffer.node);
        }

        pub fn takeBufferAsOption(self: *ServerT, connection: *Connection, send_option: SendOption) !*PooledBufferNode {
            const pooled_buffer = try self.takeBufferFromPool();
            try pooled_buffer.writer.writeInt(u8, @intFromEnum(send_option), .little);
            switch (send_option) {
                .reliable, .hello, .ping => {
                    try pooled_buffer.writer.writeInt(u16, connection.takeSendNonce(), .big);
                },
                .unreliable, .disconnect, .acknowledge => {},
            }
            return pooled_buffer;
        }

        pub fn sendRaw(self: *ServerT, connection: *Connection, buffer: []u8) !void {
            _ = try self.socket.sendTo(connection.endpoint, buffer);
        }

        pub fn sendNoAck(self: *ServerT, connection: *Connection, pooled_buffer: *PooledBufferNode) !void {
            try self.sendRaw(connection, pooled_buffer.writer.buffered());
            self.returnBufferToPool(pooled_buffer);
        }

        pub fn sendExpectAck(self: *ServerT, connection: *Connection, pooled_buffer: *PooledBufferNode) !void {
            const last_unacknowledged = (connection.acknowledged_packets_bitfield & 0x80) == 0;

            // add this packet to be the most recent unacknowledged packet
            connection.acknowledged_packets_bitfield <<= 1;
            connection.unacknowledged_packet_buffers.prepend(&pooled_buffer.node);

            // If the 8th last packet was unacknowledged, it has an entry in the un-ack'd packet buffers
            // linked list that we need to remove, since it's no longer relevant.
            if (last_unacknowledged) {
                const ll_node = connection.unacknowledged_packet_buffers.pop().?;
                const last_pooled_buffer: *PooledBufferNode = @fieldParentPtr("node", ll_node);
                self.returnBufferToPool(last_pooled_buffer);
            }

            try self.sendRaw(connection, pooled_buffer.writer.buffered());
        }

        // TODO: disconnect reasons
        pub fn disconnectConnection(self: *ServerT, connection: *Connection) !void {
            {
                // Use the mutex in a new scope, because Handler.disconnectConnection
                // will likely leave the memory undefined before defer unlock() can be run
                connection.send_mutex.lock();
                defer connection.send_mutex.unlock();

                const pooled_buffer = try self.takeBufferAsOption(connection, .disconnect);
                _ = try self.sendNoAck(connection, pooled_buffer);

                var maybe_buffer_ll_node = connection.unacknowledged_packet_buffers.first;
                while (maybe_buffer_ll_node) |buffer_ll_node| {
                    maybe_buffer_ll_node = buffer_ll_node.next;

                    const unacked_pooled_buffer: *PooledBufferNode = @fieldParentPtr("node", buffer_ll_node);
                    connection.unacknowledged_packet_buffers.remove(buffer_ll_node);
                    self.returnBufferToPool(unacked_pooled_buffer);
                }

                _ = self.connections.remove(connection.endpoint);
            }
            try Handler.disconnectConnection(self, connection);
        }
    };
}
