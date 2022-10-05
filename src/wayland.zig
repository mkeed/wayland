const std = @import("std");
pub fn getServerFile(alloc: std.mem.Allocator) !std.ArrayList(u8) {
    var alist = std.ArrayList(u8).init(alloc);
    var writer = alist.writer();
    errdefer alist.deinit();
    if (std.os.getenv("XDG_RUNTIME_DIR")) |dir| {
        if (std.os.getenv("WAYLAND_DISPLAY")) |data| {
            try std.fmt.format(writer, "{s}/{s}", .{ dir, data });
        } else {
            try std.fmt.format(writer, "{s}/{s}", .{ dir, "wayland-0" });
        }
    } else {
        return error.RuntimeNotSet;
    }
    return alist;
}

pub const Arg = struct {
    value: ValueType,
    name: []const u8,
};

pub const FixedVal = struct {
    whole: u24,
    part: u8,
};

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

pub fn fmtMessage(msgBuffer: *std.ArrayList(u8), interface: u32, opcode: u16, message: []const Value) ![]const u8 {
    msgBuffer.clearRetainingCapacity();
    var writer = msgBuffer.writer();
    try writer.writeIntNative(u32, interface);
    try writer.writeIntNative(u32, 0); // tmp
    for (message) |msg| {
        std.log.err("msg:[{}][{}]", .{ msgBuffer.items.len, std.fmt.fmtSliceHexUpper(msgBuffer.items) });
        switch (msg) {
            .Fixed => |val| {
                std.log.err("TODO implement fixed {}", .{val});
                return error.TODOError;
            },
            .NewId, .Fd, .Uint, .Object => |ui| {
                //std.log.err("write int :{}", .{ui});
                try writer.writeIntNative(u32, ui);
            },
            .Int => |i| {
                //std.log.err("write int :{}", .{i});
                try writer.writeIntNative(i32, i);
            },
            .Array, .String => |data| {
                try writer.writeIntNative(u32, @truncate(u32, data.len + 1));
                _ = try writer.write(data);
                const padbytes = [4]u8{ 0, 0, 0, 0 };
                _ = try writer.write(padbytes[0..padLen(data.len)]);
                std.log.err("msg:[{}][{}]", .{ data.len, padLen(data.len) });
            },
        }
    }
    std.mem.writeIntSliceNative(u32, msgBuffer.items[4..8], opcode | @intCast(u32, @truncate(u16, msgBuffer.items.len)) << 16);

    return msgBuffer.items;
}

pub const WaylandCallBackFn = *const fn (ctx: ?*anyopaque, connection: *WaylandConnection, args: []const Value) void;

pub const WaylandCallBack = struct {
    name: []const u8,
    args: []const Arg,
    ctx: ?*anyopaque,
    func: ?WaylandCallBackFn = null,
};

pub const WaylandObject = struct {
    name: []const u8,
    callbacks: []const WaylandCallBack,
};

pub const WaylandConnection = struct {
    stream: std.net.Stream,
    readBuffer: std.ArrayList(u8),
    writeBuffer: std.ArrayList(u8),
    argsBuffer: std.ArrayList(Value),
    objects: std.AutoHashMap(u32, WaylandObject),
    pub fn init(alloc: std.mem.Allocator) !WaylandConnection {
        errdefer wc.deinit();
        try wc.readBuffer.ensureTotalCapacity(4096);
        try wc.writeBuffer.ensureTotalCapacity(4096);
        try wc.objects.put(1, .{
            .name = "wl_display",
            .callbacks = &.{},
        });

        return wc;
    }
    pub fn addObject(self: *WaylandConnection, id: u32, object: WaylandObject) !void {
        try self.objects.put(id, object);
    }
    pub fn sendMessage(self: *WaylandConnection, interface: u32, opcode: u16, message: []const Value) !void {
        self.writeBuffer.clearRetainingCapacity();
        const msg = try fmtMessage(&self.writeBuffer, interface, opcode, message);
        std.log.info("Send Message:[{x}][{}]", .{ msg.len, std.fmt.fmtSliceHexUpper(msg) });
        var count: usize = 0;
        while (count + 4 <= msg.len) : (count += 4) {
            std.log.info("{} ", .{std.fmt.fmtSliceHexUpper(msg[count .. count + 4])});
        }
        self.stream.writer().writeAll(msg) catch |err| {
            std.log.err("error writing message:{}", .{err});
        };
    }

    pub fn readMessage(self: *WaylandConnection) !void {
        const obj = try self.stream.reader().readIntNative(u32);
        const lenCode = try self.stream.reader().readIntNative(u32);
        const len = @truncate(u16, lenCode >> 16);
        const code = @truncate(u16, lenCode);

        if (self.readBuffer.items.len < len) {
            try self.readBuffer.resize(len);
        }
        const dataLen = try self.stream.reader().read(self.readBuffer.items[0 .. len - 8]);
        const data = self.readBuffer.items[0..dataLen];
        std.log.info("Read obj:{} opcode:{} len:{}", .{ obj, code, len });
        if (self.objects.get(obj)) |object| {
            //std.log.info("Got message[{s}]", .{object.name});
            //std.log.info("Data:[{}]", .{std.fmt.fmtSliceHexUpper(data)});
            if (code < object.callbacks.len) {
                const op = object.callbacks[code];
                var idx: usize = 0;
                self.argsBuffer.clearRetainingCapacity();
                for (op.args) |arg| {
                    switch (arg.value) {
                        .Uint => {
                            defer idx += 4;
                            const val = std.mem.readIntSliceNative(u32, data[idx..]);
                            std.log.info("Arg :[{s}] => {}[{x}]", .{ arg.name, val, val });
                            try self.argsBuffer.append(.{ .Uint = val });
                        },
                        .NewId => {
                            defer idx += 4;
                            const val = std.mem.readIntSliceNative(u32, data[idx..]);
                            try self.argsBuffer.append(.{ .NewId = val });
                            std.log.info("Arg :[{s}] => {}", .{ arg.name, val });
                        },
                        .Int => {
                            defer idx += 4;
                            const val = std.mem.readIntSliceNative(i32, data[idx..]);
                            try self.argsBuffer.append(.{ .Int = val });
                            std.log.info("Arg :[{s}] => {}", .{ arg.name, val });
                        },
                        .Fixed => {
                            defer idx += 4;
                            const val = std.mem.readIntSliceNative(u32, data[idx..]);
                            try self.argsBuffer.append(.{ .Fixed = .{ .whole = @truncate(u24, val >> 8), .part = @truncate(u8, val) } });
                            std.log.info("Arg :[{s}] => {}", .{ arg.name, val });
                        },
                        .String => {
                            const strlen = std.mem.readIntSliceNative(u32, data[idx..]);
                            idx += 4;
                            const str = data[idx .. idx + strlen];
                            idx += paddedSize(str);
                            const strNoZero = str[0 .. str.len - 1];
                            try self.argsBuffer.append(.{ .String = strNoZero });
                            std.log.info("Arg :[{s}] => [{s}]", .{ arg.name, str });
                        },
                        .Object => {
                            defer idx += 4;
                            const val = std.mem.readIntSliceNative(u32, data[idx..]);
                            try self.argsBuffer.append(.{ .Object = val });
                            std.log.info("Arg :[{s}] => {}", .{ arg.name, val });
                        },
                        .Array => {
                            const arrlen = std.mem.readIntSliceNative(u32, data[idx..]);
                            idx += 4;
                            const arr = data[idx .. idx + arrlen];
                            idx += paddedSize(arr);
                            try self.argsBuffer.append(.{ .Array = arr });
                            std.log.info("Arg :[{s}] => {}", .{ arg.name, std.fmt.fmtSliceHexUpper(arr) });
                        },
                        .Fd => {
                            defer idx += 4;
                            const val = std.mem.readIntSliceNative(u32, data[idx..]);
                            try self.argsBuffer.append(.{ .Fd = val });
                            std.log.info("Arg :[{s}] => {}", .{ arg.name, val });
                        },
                    }
                }
                if (op.func) |func| {
                    func(op.ctx, self, self.argsBuffer.items);
                }
            }
        }
    }

    pub fn deinit(self: *WaylandConnection) void {
        self.stream.close();
        self.readBuffer.deinit();
        self.writeBuffer.deinit();
        self.objects.deinit();
        self.argsBuffer.deinit();
    }
};
