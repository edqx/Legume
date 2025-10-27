const std = @import("std");
const network = @import("network");

const log = std.log.scoped(.hazel_server);

const max_out_of_order = 10;

pub const SendOption = enum(u8) {
    unreliable = 0,
    reliable = 1,
    hello = 8,
    disconnect = 9,
    acknowledge = 10,
    ping = 12,
};

pub const OutOfOrderMessage = struct {
    send_option: SendOption,
    assert_nonce: u16,
    message_data_buffer: []u8,
};

pub const Connection = struct {
    endpoint: network.EndPoint,
    expected_nonce: u16 = 0,

    out_of_order_messages: [max_out_of_order]?OutOfOrderMessage,

    pub fn format(self: *Connection, writer: *std.Io.Writer) !void {
        try writer.print("{f}", .{self.endpoint});
    }
};

pub fn Server(comptime Handler: type) type {
    return struct {
        const ServerT = @This();

        allocator: std.mem.Allocator,

        socket: network.Socket,
        message_buffer: []u8,

        mutex: std.Thread.Mutex = .{},
        connections: std.AutoHashMapUnmanaged(network.EndPoint, *Connection),

        handler: Handler,

        pub fn init(allocator: std.mem.Allocator, message_buffer: []u8, handler: Handler) !ServerT {
            return .{
                .allocator = allocator,
                .socket = try .create(.ipv4, .udp),
                .message_buffer = message_buffer,
                .connections = .empty,
                .handler = handler,
            };
        }

        pub fn deinit(self: *ServerT) void {
            self.connections.deinit(self.allocator);
            self.socket.close();
        }

        pub fn nextHandle(self: *ServerT) usize {
            defer self.incrementing_handle += 1;
            return self.incrementing_handle;
        }

        pub fn listen(self: *ServerT, port: u16) !void {
            try self.socket.bind(.{ .address = try .parse("0.0.0.0"), .port = port });

            while (true) {
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

        pub fn readOption(self: *ServerT, sender_endpoint: network.EndPoint, reader: *std.Io.Reader) !void {
            const send_option = reader.takeEnum(SendOption, .little) catch |e| switch (e) {
                error.InvalidEnumTag => {
                    std.log.err("Got an invalid send option from {f} - is this a Hazel connection?", .{sender_endpoint});
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
                const sender = result.value_ptr.*;

                switch (send_option) {
                    .unreliable => {
                        try self.processNormal(sender, false, reader);
                    },
                    .reliable, .hello, .ping => {
                        try self.acknowledgeAndProcessReliable(sender, send_option, reader);
                    },
                    .disconnect => {
                        log.info("Disconnect from connection {f}", .{sender});
                    },
                    .acknowledge => {
                        //
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
                    .out_of_order_messages = @splat(null),
                };

                result.value_ptr.* = try self.handler.acceptConnection(sender_connection, reader);
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

                connection.expected_nonce = nonce +% 1;
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
                std.log.err("Connection {[sender]f} has sent a {[option]} wholly out-of-order message: got {[nonce]}, expected {[expected_nonce]}", .{
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
                    log.warn("Got duplicate hello from connection {f}", .{connection});
                },
                .unreliable, .acknowledge, .disconnect => unreachable,
            }
        }

        pub fn acknowledgeReliable(self: *ServerT, connection: *Connection, nonce: u16) !void {
            var buffer: [4]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buffer);

            try writer.writeByte(@intFromEnum(SendOption.acknowledge));
            try writer.writeInt(u16, nonce, .big);
            try writer.writeByte(0xff); // TODO: replace with un-acknowledged packets from client

            _ = try self.socket.sendTo(connection.endpoint, &buffer);
        }

        pub fn processNormal(self: *ServerT, connection: *Connection, reliable: bool, reader: *std.Io.Reader) !void {
            log.info("Got normal message", .{});
            _ = self;
            _ = connection;
            _ = reliable;
            _ = reader;
        }
    };
}
