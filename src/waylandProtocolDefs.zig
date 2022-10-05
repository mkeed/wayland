const std = @import("std");
const debug = false;
pub const ValueType = enum {
    Int,
    Uint,
    Fixed,
    String,
    Object,
    Array,
    Fd,
    NewId,
};

pub const Value = union(ArgType) {
    Int: i32,
    Uint: u32,
    Object: u32,
    Fixed: FixedVal,
    String: []const u8,
    Array: []const u8,
    Fd: u32,
    NewId: u32,
};

pub const Arg = struct {
    name: []const u8,
    argType: ArgType,
};

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

pub fn castTo(comptime T: type, ctx: *anyopaque) *T {
    return @ptrCast(*T, @alignCast(@alignOf(T), ctx));
}

pub const WLConnection = struct {
    stream: std.net.Stream,
    readBuffer: std.ArrayList(u8),
    writeBuffer: std.ArrayList(u8),
    registry: Registry,
    argsBuffer: std.ArrayList(Value),
    alloc: std.mem.Allocator,
    pub fn init(alloc: std.mem.Allocator) !*WLConnection {
        var self = try alloc.create(WLConnection);
        errdefer alloc.destroy(self);
        const serverFile = try getServerFile(alloc);
        defer serverFile.deinit();

        var connection = try std.net.connectUnixSocket(serverFile.items);
        errdefer connection.close();
        var wl_object = WLObject{
            .id = 1,
            .interface = .{
                .wl_display = .{
                    .ctx = self,
                    .conn = self,
                    .id = 1,
                    .errorFn = errorFn,
                    .delete_idFn = delete_idFn,
                },
            },
        };
        self.* = WLConnection{
            .stream = connection,
            .readBuffer = std.ArrayList(u8).init(alloc),
            .writeBuffer = std.ArrayList(u8).init(alloc),
            .registry = try Registry.init(alloc, wl_object),
            .argsBuffer = std.ArrayList(Value).init(alloc),
            .alloc = alloc,
        };
        return self;
    }
    pub fn errorFn(ctx: ?*anyopaque, conn: *WLConnection, args: []const Value) void {
        //var conn = castTo(WLConnection, ctx.?);
        _ = ctx;
        _ = conn;
        const id = args[0].Object;
        const code = args[1].Uint;
        const message = args[2].String;

        std.log.err("error on Object {} code:[{}] msg:[{s}] ", .{ id, code, message });
    }
    pub fn delete_idFn(ctx: ?*anyopaque, conn: *WLConnection, args: []const Value) void {
        _ = ctx;
        _ = conn;
        _ = args;
    }
    pub fn getObject(
        self: *WLConnection,
        id: u32,
    ) ?WLObject {
        return self.registry.getObject(id);
    }
    fn paddedSize(data: []const u8) u32 {
        return @truncate(u32, (data.len + 3) / 4) * 4;
    }
    fn padLen(len: usize) usize {
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
            if (debug) {
                std.log.err("msg:[{}][{}]", .{ msgBuffer.items.len, std.fmt.fmtSliceHexUpper(msgBuffer.items) });
            }
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
                    if (debug) {
                        std.log.err("msg:[{}][{}]", .{ data.len, padLen(data.len) });
                    }
                },
            }
        }
        std.mem.writeIntSliceNative(u32, msgBuffer.items[4..8], opcode | @intCast(u32, @truncate(u16, msgBuffer.items.len)) << 16);

        return msgBuffer.items;
    }
    pub fn sendMessage(self: *WLConnection, interface: u32, opcode: u16, message: []const Value) !void {
        self.writeBuffer.clearRetainingCapacity();
        const msg = try fmtMessage(&self.writeBuffer, interface, opcode, message);
        if (debug) {
            std.log.info("Send Message:[{x}][{}]", .{ msg.len, std.fmt.fmtSliceHexUpper(msg) });
        }
        var count: usize = 0;
        while (count + 4 <= msg.len) : (count += 4) {
            if (debug) {
                std.log.info("{} ", .{std.fmt.fmtSliceHexUpper(msg[count .. count + 4])});
            }
        }
        self.stream.writer().writeAll(msg) catch |err| {
            if (debug) {
                std.log.err("error writing message:{}", .{err});
            }
        };
    }
    pub fn readMessage(self: *WLConnection) !void {
        const obj = try self.stream.reader().readIntNative(u32);
        const lenCode = try self.stream.reader().readIntNative(u32);
        const len = @truncate(u16, lenCode >> 16);
        const code = @truncate(u16, lenCode);

        if (debug) {
            std.log.err("obj:{} len:{} code:{} lenCode:{}", .{ obj, len, code, lenCode });
        }

        if (self.readBuffer.items.len < len) {
            try self.readBuffer.resize(len);
        }
        const dataLen = try self.stream.reader().readAll(self.readBuffer.items[0 .. len - 8]);
        const data = self.readBuffer.items[0..dataLen];
        if (debug) {
            std.log.info("Read obj:{} opcode:{} len:{}:data:[{}]", .{
                obj,
                code,
                len,
                std.fmt.fmtSliceHexUpper(data),
            });
        }
        if (self.registry.getObject(obj)) |object| {
            if (object.interface.getcallback(code)) |op| {
                if (debug) {
                    std.log.err("object:{s}", .{op.name});
                }
                var idx: usize = 0;
                for (op.args) |arg| {
                    switch (arg.argType) {
                        .Uint => {
                            defer idx += 4;
                            const val = std.mem.readIntSliceNative(u32, data[idx..]);
                            if (debug) {
                                std.log.info("Arg :[{s}] => {}[{x}]", .{ arg.name, val, val });
                            }
                            try self.argsBuffer.append(.{ .Uint = val });
                        },
                        .NewId => {
                            defer idx += 4;
                            const val = std.mem.readIntSliceNative(u32, data[idx..]);
                            try self.argsBuffer.append(.{ .NewId = val });
                            if (debug) {
                                std.log.info("Arg :[{s}] => {}", .{ arg.name, val });
                            }
                        },
                        .Int => {
                            defer idx += 4;
                            const val = std.mem.readIntSliceNative(i32, data[idx..]);
                            try self.argsBuffer.append(.{ .Int = val });
                            if (debug) {
                                std.log.info("Arg :[{s}] => {}", .{ arg.name, val });
                            }
                        },
                        .Fixed => {
                            defer idx += 4;
                            const val = std.mem.readIntSliceNative(u32, data[idx..]);
                            try self.argsBuffer.append(.{ .Fixed = .{ .whole = @truncate(u24, val >> 8), .part = @truncate(u8, val) } });
                            if (debug) {
                                std.log.info("Arg :[{s}] => {}", .{ arg.name, val });
                            }
                        },
                        .String => {
                            const strlen = std.mem.readIntSliceNative(u32, data[idx..]);
                            idx += 4;
                            const str = data[idx .. idx + strlen];
                            idx += paddedSize(str);
                            const strNoZero = str[0 .. str.len - 1];
                            try self.argsBuffer.append(.{ .String = strNoZero });
                            if (debug) {
                                std.log.info("Arg :[{s}] => [{s}]", .{ arg.name, str });
                            }
                        },
                        .Object => {
                            defer idx += 4;
                            const val = std.mem.readIntSliceNative(u32, data[idx..]);
                            try self.argsBuffer.append(.{ .Object = val });
                            if (debug) {
                                std.log.info("Arg :[{s}] => {}", .{ arg.name, val });
                            }
                        },
                        .Array => {
                            const arrlen = std.mem.readIntSliceNative(u32, data[idx..]);
                            idx += 4;
                            const arr = data[idx .. idx + arrlen];
                            idx += paddedSize(arr);
                            try self.argsBuffer.append(.{ .Array = arr });
                            if (debug) {
                                std.log.info("Arg :[{s}] => {}", .{ arg.name, std.fmt.fmtSliceHexUpper(arr) });
                            }
                        },
                        .Fd => {
                            defer idx += 4;
                            const val = std.mem.readIntSliceNative(u32, data[idx..]);
                            try self.argsBuffer.append(.{ .Fd = val });
                            if (debug) {
                                std.log.info("Arg :[{s}] => {}", .{ arg.name, val });
                            }
                        },
                    }
                }
                if (op.func) |func| {
                    func(op.ctx, self, self.argsBuffer.items);
                } else {
                    std.log.info("no function found => {}:{}", .{ obj, code });
                }
                self.argsBuffer.clearRetainingCapacity();
            } else {
                std.log.info("Invalid callback returned object:{}, code:{}", .{ obj, code });
            }
        }
    }
    pub fn deinit(self: *WLConnection) void {
        self.stream.close();
        self.readBuffer.deinit();
        self.writeBuffer.deinit();
        self.registry.deinit();
        self.alloc.destroy(self);
    }
};

const WLCallbackFn = *const fn (ctx: ?*anyopaque, connection: *WLConnection, args: []const Value) void;
pub const WLCallback = struct {
    name: []const u8,
    args: []const Arg,
    ctx: ?*anyopaque,
    func: ?WLCallbackFn = null,
};

pub const ArgType = enum { Int, Uint, Fixed, String, Object, NewId, Array, Fd };

pub const String = []const u8;
pub const Uint = u32;
pub const Int = u32;
pub const Fixed = u32;
pub const FixedVal = struct {
    whole: u24,
    part: u8,
};

pub const Object = u32;
pub const NewId = u32;
pub const Fd = u32;
pub const Array = u32;

pub const Registry = struct {
    pub fn init(
        alloc: std.mem.Allocator,
        obj: WLObject,
    ) !Registry {
        var items = std.ArrayList(WLObject).init(alloc);
        errdefer items.deinit();

        try items.append(obj);

        return Registry{
            .items = items,
            .interfaces = std.ArrayList(InterfaceDef).init(alloc),
            .nextId = 2,
        };
    }
    pub fn deinit(self: Registry) void {
        self.items.deinit();
        self.interfaces.deinit();
    }
    pub fn getObject(self: Registry, id: u32) ?WLObject {
        for (self.items.items) |item| {
            if (item.id == id) return item;
        }
        return null;
    }
    pub fn getInterface(self: *Registry, interface: WLInterfaceType) ?u32 {
        for (self.interfaces.items) |i| {
            if (interface == i.interface) return i.id;
        }
        return null;
    }
    pub fn addObject(self: *Registry, interface: WLInterface) !u32 {
        defer self.nextId += 1;
        std.log.err("nextId =>{}", .{self.nextId});
        try self.items.append(.{ .id = self.nextId, .interface = interface });
        return self.nextId;
    }
    pub fn global(ctx: ?*anyopaque, conn: *WLConnection, args: []const Value) void {
        std.log.info("name:{} interface:{s} version:{}", .{ args[0].Uint, args[1].String, args[2].Uint });
        const self = castTo(Registry, ctx.?);
        const name = args[1].String;
        const id = args[0].Uint;
        for (interfaceStrings) |str| {
            if (std.mem.eql(u8, name, str.name)) {
                self.interfaces.append(.{ .interface = str.interface, .id = id }) catch {};
            }
        }
        _ = conn;
    }
    pub fn global_remove(ctx: ?*anyopaque, conn: *WLConnection, args: []const Value) void {
        _ = ctx;
        _ = conn;
        _ = args;
    }

    items: std.ArrayList(*WLObject),
    interfaces: std.ArrayList(InterfaceDef),
    nextId: u32,
};

pub const InterfaceDef = struct {
    interface: WLInterfaceType,
    id: usize,
};

pub const WLObject = struct {
    id: u32,
    interface: WLInterface,
};
