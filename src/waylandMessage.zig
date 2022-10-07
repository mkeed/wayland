const std = @import("std");

pub fn paddedSize(data: []const u8) u32 {
    return @truncate(u32, (data.len + 3) / 4) * 4;
}
pub fn padLen(len: usize) usize {
    return switch (@truncate(u2, len)) {
        1 => 3,
        2 => 2,
        3 => 1,
        0 => 0,
    };
}

pub const ArgType = enum {
    Int,
    Uint,
    Fixed,
    String,
    Object,
    Array,
    Fd,
    NewId,
};

pub const Argument = union(ArgType) {
    Int: i32,
    Uint: u32,
    Object: u32,
    Fixed: FixedVal,
    String: std.ArrayList(u8),
    Array: std.ArrayList(u8),
    Fd: u32,
    NewId: u32,
    pub fn deinit(self: Argument) void {
        switch (self) {
            .Fixed, .String => |val| {
                val.deinit();
            },
        }
    }
    pub fn toString(alloc: std.mem.Allocator, val: []const u8) !Argument {
        var str = std.ArrayList(u8).init(alloc);
        try str.appendSlice(val);
        return Argument{
            .String = str,
        };
    }
    pub fn toArray(alloc: std.mem.Allocator, val: []const u8) !Argument {
        var str = std.ArrayList(u8).init(alloc);
        try str.appendSlice(val);
        return Argument{
            .Array = str,
        };
    }
};

pub const WaylandMessage = struct {
    object: u32,
    opcode: u16,
    args: std.ArrayList(Argument),
};

pub const WaylandInterface = struct {
    fd: std.os.fd_t,
    readBuffer: [8196]u8,
    pub fn init(alloc: std.mem.allocator, path: []const u8) !WaylandInterface {
        const sockfd = try os.socket(
            os.AF.UNIX,
            os.SOCK.STREAM | os.SOCK.CLOEXEC | os.SOCK.NONBLOCK,
            0,
        );
        errdefer os.closeSocket(sockfd);

        var addr = try std.net.Address.initUnix(path);

        try os.connect(sockfd, &addr.any, addr.getOsSockLen());

        return WaylandInterface{
            .fd = sockfd,
            .readBuffer = undefined,
        };
    }
    pub fn readMessages(self: *WaylandInterface, alloc: std.mem.Allocator, objectMap: ObjectMap) std.ArrayList(WaylandMessage) {
        var arr = std.ArrayList(WaylandMessage).init(alloc);
        const len = try std.os.read(&self.readBuffer);
    }
};
