const std = @import("std");
const network = @import("network");

const log = std.log.scoped(.hazel_server);

pub const SendOption = enum(u8) {
    unreliable = 0,
    reliable = 1,
    hello = 8,
    disconnect = 9,
    acknowledge = 10,
    ping = 12,
};

pub const Connection = struct {
    pub const Info = struct {
        endpoint: network.EndPoint,
    };

    info: Info,

    pub fn init(info: Info) Connection {
        return .{ .info = info };
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
                    error.ReadFailed => break,
                    error.EndOfStream => continue, // todo: log bad message
                    else => return e,
                };
            }
        }

        pub fn readOption(self: *ServerT, sender_endpoint: network.EndPoint, reader: *std.Io.Reader) !void {
            const option = try reader.takeEnum(SendOption, .little);

            const result = safe_fetch: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :safe_fetch try self.connections.getOrPut(self.allocator, sender_endpoint);
            };

            std.log.info("got option: {} from {f}", .{ option, sender_endpoint });

            if (result.found_existing) {
                switch (option) {
                    .unreliable => {
                        //
                    },
                    .reliable => {
                        //
                    },
                    .hello => {
                        //
                    },
                    .disconnect => {
                        //
                    },
                    .acknowledge => {
                        //
                    },
                    .ping => {
                        //
                    },
                }
            } else {
                if (option != .hello) {
                    log.err("Got non-hello from first-time sender {f}", .{sender_endpoint});
                    std.debug.assert(self.connections.remove(sender_endpoint));
                    return;
                }

                const info: Connection.Info = .{
                    .endpoint = sender_endpoint,
                };

                result.value_ptr.* = try self.handler.acceptConnection(info, reader);
            }
        }
    };
}
