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
pub const WLInterfaceType = enum{
    wl_display,
    wl_registry,
    wl_callback,
    wl_compositor,
    wl_shm_pool,
    wl_shm,
    wl_buffer,
    wl_data_offer,
    wl_data_source,
    wl_data_device,
    wl_data_device_manager,
    wl_shell,
    wl_shell_surface,
    wl_surface,
    wl_seat,
    wl_pointer,
    wl_keyboard,
    wl_touch,
    wl_output,
    wl_region,
    wl_subcompositor,
    wl_subsurface,
    wp_presentation,
    wp_presentation_feedback,
    wp_viewporter,
    wp_viewport,
    xdg_wm_base,
    xdg_positioner,
    xdg_surface,
    xdg_toplevel,
    xdg_popup,
};
pub const InterfaceString = struct {
    name:[]const u8,
    interface:WLInterfaceType,
};
pub const interfaceStrings = [_]InterfaceString{

    .{.name = "wl_display",.interface = .wl_display},
    .{.name = "wl_registry",.interface = .wl_registry},
    .{.name = "wl_callback",.interface = .wl_callback},
    .{.name = "wl_compositor",.interface = .wl_compositor},
    .{.name = "wl_shm_pool",.interface = .wl_shm_pool},
    .{.name = "wl_shm",.interface = .wl_shm},
    .{.name = "wl_buffer",.interface = .wl_buffer},
    .{.name = "wl_data_offer",.interface = .wl_data_offer},
    .{.name = "wl_data_source",.interface = .wl_data_source},
    .{.name = "wl_data_device",.interface = .wl_data_device},
    .{.name = "wl_data_device_manager",.interface = .wl_data_device_manager},
    .{.name = "wl_shell",.interface = .wl_shell},
    .{.name = "wl_shell_surface",.interface = .wl_shell_surface},
    .{.name = "wl_surface",.interface = .wl_surface},
    .{.name = "wl_seat",.interface = .wl_seat},
    .{.name = "wl_pointer",.interface = .wl_pointer},
    .{.name = "wl_keyboard",.interface = .wl_keyboard},
    .{.name = "wl_touch",.interface = .wl_touch},
    .{.name = "wl_output",.interface = .wl_output},
    .{.name = "wl_region",.interface = .wl_region},
    .{.name = "wl_subcompositor",.interface = .wl_subcompositor},
    .{.name = "wl_subsurface",.interface = .wl_subsurface},
    .{.name = "wp_presentation",.interface = .wp_presentation},
    .{.name = "wp_presentation_feedback",.interface = .wp_presentation_feedback},
    .{.name = "wp_viewporter",.interface = .wp_viewporter},
    .{.name = "wp_viewport",.interface = .wp_viewport},
    .{.name = "xdg_wm_base",.interface = .xdg_wm_base},
    .{.name = "xdg_positioner",.interface = .xdg_positioner},
    .{.name = "xdg_surface",.interface = .xdg_surface},
    .{.name = "xdg_toplevel",.interface = .xdg_toplevel},
    .{.name = "xdg_popup",.interface = .xdg_popup},
};
pub const WLInterface = union(enum) {
    wl_display: wl_display,
    wl_registry: wl_registry,
    wl_callback: wl_callback,
    wl_compositor: wl_compositor,
    wl_shm_pool: wl_shm_pool,
    wl_shm: wl_shm,
    wl_buffer: wl_buffer,
    wl_data_offer: wl_data_offer,
    wl_data_source: wl_data_source,
    wl_data_device: wl_data_device,
    wl_data_device_manager: wl_data_device_manager,
    wl_shell: wl_shell,
    wl_shell_surface: wl_shell_surface,
    wl_surface: wl_surface,
    wl_seat: wl_seat,
    wl_pointer: wl_pointer,
    wl_keyboard: wl_keyboard,
    wl_touch: wl_touch,
    wl_output: wl_output,
    wl_region: wl_region,
    wl_subcompositor: wl_subcompositor,
    wl_subsurface: wl_subsurface,
    wp_presentation: wp_presentation,
    wp_presentation_feedback: wp_presentation_feedback,
    wp_viewporter: wp_viewporter,
    wp_viewport: wp_viewport,
    xdg_wm_base: xdg_wm_base,
    xdg_positioner: xdg_positioner,
    xdg_surface: xdg_surface,
    xdg_toplevel: xdg_toplevel,
    xdg_popup: xdg_popup, pub fn getcallback(self:WLInterface,idx:u16) ?WLCallback {
 return switch(self) {
    .wl_display => |val| val.get_callback(idx), 
    .wl_registry => |val| val.get_callback(idx), 
    .wl_callback => |val| val.get_callback(idx), 
    .wl_compositor => |val| val.get_callback(idx), 
    .wl_shm_pool => |val| val.get_callback(idx), 
    .wl_shm => |val| val.get_callback(idx), 
    .wl_buffer => |val| val.get_callback(idx), 
    .wl_data_offer => |val| val.get_callback(idx), 
    .wl_data_source => |val| val.get_callback(idx), 
    .wl_data_device => |val| val.get_callback(idx), 
    .wl_data_device_manager => |val| val.get_callback(idx), 
    .wl_shell => |val| val.get_callback(idx), 
    .wl_shell_surface => |val| val.get_callback(idx), 
    .wl_surface => |val| val.get_callback(idx), 
    .wl_seat => |val| val.get_callback(idx), 
    .wl_pointer => |val| val.get_callback(idx), 
    .wl_keyboard => |val| val.get_callback(idx), 
    .wl_touch => |val| val.get_callback(idx), 
    .wl_output => |val| val.get_callback(idx), 
    .wl_region => |val| val.get_callback(idx), 
    .wl_subcompositor => |val| val.get_callback(idx), 
    .wl_subsurface => |val| val.get_callback(idx), 
    .wp_presentation => |val| val.get_callback(idx), 
    .wp_presentation_feedback => |val| val.get_callback(idx), 
    .wp_viewporter => |val| val.get_callback(idx), 
    .wp_viewport => |val| val.get_callback(idx), 
    .xdg_wm_base => |val| val.get_callback(idx), 
    .xdg_positioner => |val| val.get_callback(idx), 
    .xdg_surface => |val| val.get_callback(idx), 
    .xdg_toplevel => |val| val.get_callback(idx), 
    .xdg_popup => |val| val.get_callback(idx),    };
}
};

pub const wl_display = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    id: ?u32,    errorFn:?WLCallbackFn = null,
    delete_idFn:?WLCallbackFn = null,
    const error_name = "error";
    const error_arg = &[_] Arg{
        .{.name = "object_id", .argType = .Object},
        .{.name = "code", .argType = .Uint},
        .{.name = "message", .argType = .String},
    };    const delete_id_name = "delete_id";
    const delete_id_arg = &[_] Arg{
        .{.name = "id", .argType = .Uint},
    };    pub fn get_callback(self:wl_display,idx:u16) ?WLCallback {
        return switch(idx) {    0 => .{ .name = error_name, .args = error_arg, .ctx = self.ctx, .func = self.errorFn},
    1 => .{ .name = delete_id_name, .args = delete_id_arg, .ctx = self.ctx, .func = self.delete_idFn},
        else => null,
        }; }    pub fn syncFn(
        self:*wl_display,
        done:?WLCallbackFn,
        ctx:?*anyopaque,)
 !u32 {           
           const id = try self.conn.registry.addObject(.{
                       .wl_callback = .{
                           .id = null,   
                           .ctx = ctx,
                           .conn = self.conn,
        .doneFn = done,     },});
        try self.conn.sendMessage(self.id.?,0,&[_]Value{
             .{.NewId = id},
        });
      return id;
}
    pub fn get_registryFn(
        self:*wl_display,
        global:?WLCallbackFn,
        global_remove:?WLCallbackFn,
        ctx:?*anyopaque,)
 !u32 {           
           const id = try self.conn.registry.addObject(.{
                       .wl_registry = .{
                           .id = null,   
                           .ctx = ctx,
                           .conn = self.conn,
        .globalFn = global,
        .global_removeFn = global_remove,     },});
        try self.conn.sendMessage(self.id.?,1,&[_]Value{
             .{.NewId = id},
        });
      return id;
}

};

pub const wl_registry = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    id: ?u32,    globalFn:?WLCallbackFn = null,
    global_removeFn:?WLCallbackFn = null,
    const global_name = "global";
    const global_arg = &[_] Arg{
        .{.name = "name", .argType = .Uint},
        .{.name = "interface", .argType = .String},
        .{.name = "version", .argType = .Uint},
    };    const global_remove_name = "global_remove";
    const global_remove_arg = &[_] Arg{
        .{.name = "name", .argType = .Uint},
    };    pub fn get_callback(self:wl_registry,idx:u16) ?WLCallback {
        return switch(idx) {    0 => .{ .name = global_name, .args = global_arg, .ctx = self.ctx, .func = self.globalFn},
    1 => .{ .name = global_remove_name, .args = global_remove_arg, .ctx = self.ctx, .func = self.global_removeFn},
        else => null,
        }; }    pub fn bindFn(
        self:*wl_registry,
        name:Uint,
        interface:WLInterface,)
 void {
        try self.conn.sendMessage(self.id.?,0,&[_]Value{
            .{.Uint = name},
            .{.String = interface.string},
            .{.Uint = interface.version},
            .{.NewId  = interface.id},
        });
       return interface.id;
}

};

pub const wl_callback = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    id: ?u32,    doneFn:?WLCallbackFn = null,
    const done_name = "done";
    const done_arg = &[_] Arg{
        .{.name = "callback_data", .argType = .Uint},
    };    pub fn get_callback(self:wl_callback,idx:u16) ?WLCallback {
        return switch(idx) {    0 => .{ .name = done_name, .args = done_arg, .ctx = self.ctx, .func = self.doneFn},
        else => null,
        }; }
};

pub const wl_compositor = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    id: ?u32,    pub fn get_callback(self:wl_compositor,idx:u16) ?WLCallback {
_ = self;_ = idx;return null; }    pub fn create_surfaceFn(
        self:*wl_compositor,
        enter:?WLCallbackFn,
        leave:?WLCallbackFn,
        ctx:?*anyopaque,)
 !u32 {           
           const id = try self.conn.registry.addObject(.{
                       .wl_surface = .{
                           .id = null,   
                           .ctx = ctx,
                           .conn = self.conn,
        .enterFn = enter,
        .leaveFn = leave,     },});
        try self.conn.sendMessage(self.id.?,0,&[_]Value{
             .{.NewId = id},
        });
      return id;
}
    pub fn create_regionFn(
        self:*wl_compositor,
        ctx:?*anyopaque,)
 !u32 {           
           const id = try self.conn.registry.addObject(.{
                       .wl_region = .{
                           .id = null,   
                           .ctx = ctx,
                           .conn = self.conn,     },});
        try self.conn.sendMessage(self.id.?,1,&[_]Value{
             .{.NewId = id},
        });
      return id;
}

};

pub const wl_shm_pool = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    id: ?u32,    pub fn get_callback(self:wl_shm_pool,idx:u16) ?WLCallback {
_ = self;_ = idx;return null; }    pub fn create_bufferFn(
        self:*wl_shm_pool,
        release:?WLCallbackFn,
        ctx:?*anyopaque,
        offset:Int,
        width:Int,
        height:Int,
        stride:Int,
        format:Uint,)
 !u32 {           
           const id = try self.conn.registry.addObject(.{
                       .wl_buffer = .{
                           .id = null,   
                           .ctx = ctx,
                           .conn = self.conn,
        .releaseFn = release,     },});
        try self.conn.sendMessage(self.id.?,0,&[_]Value{
             .{.NewId = id},
            .{.Int = offset},
            .{.Int = width},
            .{.Int = height},
            .{.Int = stride},
            .{.Uint = format},
        });
      return id;
}
    pub fn destroyFn(
        self:*wl_shm_pool,)
 void {
        try self.conn.sendMessage(self.id.?,1,&[_]Value{
        });
}
    pub fn resizeFn(
        self:*wl_shm_pool,
        size:Int,)
 void {
        try self.conn.sendMessage(self.id.?,2,&[_]Value{
            .{.Int = size},
        });
}

};

pub const wl_shm = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    id: ?u32,    formatFn:?WLCallbackFn = null,
    const format_name = "format";
    const format_arg = &[_] Arg{
        .{.name = "format", .argType = .Uint},
    };    pub fn get_callback(self:wl_shm,idx:u16) ?WLCallback {
        return switch(idx) {    0 => .{ .name = format_name, .args = format_arg, .ctx = self.ctx, .func = self.formatFn},
        else => null,
        }; }    pub fn create_poolFn(
        self:*wl_shm,
        ctx:?*anyopaque,
        fd:Fd,
        size:Int,)
 !u32 {           
           const id = try self.conn.registry.addObject(.{
                       .wl_shm_pool = .{
                           .id = null,   
                           .ctx = ctx,
                           .conn = self.conn,     },});
        try self.conn.sendMessage(self.id.?,0,&[_]Value{
             .{.NewId = id},
            .{.Fd = fd},
            .{.Int = size},
        });
      return id;
}

};

pub const wl_buffer = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    id: ?u32,    releaseFn:?WLCallbackFn = null,
    const release_name = "release";
    const release_arg = &[_] Arg{
    };    pub fn get_callback(self:wl_buffer,idx:u16) ?WLCallback {
        return switch(idx) {    0 => .{ .name = release_name, .args = release_arg, .ctx = self.ctx, .func = self.releaseFn},
        else => null,
        }; }    pub fn destroyFn(
        self:*wl_buffer,)
 void {
        try self.conn.sendMessage(self.id.?,0,&[_]Value{
        });
}

};

pub const wl_data_offer = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    id: ?u32,    offerFn:?WLCallbackFn = null,
    source_actionsFn:?WLCallbackFn = null,
    actionFn:?WLCallbackFn = null,
    const offer_name = "offer";
    const offer_arg = &[_] Arg{
        .{.name = "mime_type", .argType = .String},
    };    const source_actions_name = "source_actions";
    const source_actions_arg = &[_] Arg{
        .{.name = "source_actions", .argType = .Uint},
    };    const action_name = "action";
    const action_arg = &[_] Arg{
        .{.name = "dnd_action", .argType = .Uint},
    };    pub fn get_callback(self:wl_data_offer,idx:u16) ?WLCallback {
        return switch(idx) {    0 => .{ .name = offer_name, .args = offer_arg, .ctx = self.ctx, .func = self.offerFn},
    1 => .{ .name = source_actions_name, .args = source_actions_arg, .ctx = self.ctx, .func = self.source_actionsFn},
    2 => .{ .name = action_name, .args = action_arg, .ctx = self.ctx, .func = self.actionFn},
        else => null,
        }; }    pub fn acceptFn(
        self:*wl_data_offer,
        serial:Uint,
        mime_type:String,)
 void {
        try self.conn.sendMessage(self.id.?,0,&[_]Value{
            .{.Uint = serial},
            .{.String = mime_type},
        });
}
    pub fn receiveFn(
        self:*wl_data_offer,
        mime_type:String,
        fd:Fd,)
 void {
        try self.conn.sendMessage(self.id.?,1,&[_]Value{
            .{.String = mime_type},
            .{.Fd = fd},
        });
}
    pub fn destroyFn(
        self:*wl_data_offer,)
 void {
        try self.conn.sendMessage(self.id.?,2,&[_]Value{
        });
}
    pub fn finishFn(
        self:*wl_data_offer,)
 void {
        try self.conn.sendMessage(self.id.?,3,&[_]Value{
        });
}
    pub fn set_actionsFn(
        self:*wl_data_offer,
        dnd_actions:Uint,
        preferred_action:Uint,)
 void {
        try self.conn.sendMessage(self.id.?,4,&[_]Value{
            .{.Uint = dnd_actions},
            .{.Uint = preferred_action},
        });
}

};

pub const wl_data_source = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    id: ?u32,    targetFn:?WLCallbackFn = null,
    sendFn:?WLCallbackFn = null,
    cancelledFn:?WLCallbackFn = null,
    dnd_drop_performedFn:?WLCallbackFn = null,
    dnd_finishedFn:?WLCallbackFn = null,
    actionFn:?WLCallbackFn = null,
    const target_name = "target";
    const target_arg = &[_] Arg{
        .{.name = "mime_type", .argType = .String},
    };    const send_name = "send";
    const send_arg = &[_] Arg{
        .{.name = "mime_type", .argType = .String},
        .{.name = "fd", .argType = .Fd},
    };    const cancelled_name = "cancelled";
    const cancelled_arg = &[_] Arg{
    };    const dnd_drop_performed_name = "dnd_drop_performed";
    const dnd_drop_performed_arg = &[_] Arg{
    };    const dnd_finished_name = "dnd_finished";
    const dnd_finished_arg = &[_] Arg{
    };    const action_name = "action";
    const action_arg = &[_] Arg{
        .{.name = "dnd_action", .argType = .Uint},
    };    pub fn get_callback(self:wl_data_source,idx:u16) ?WLCallback {
        return switch(idx) {    0 => .{ .name = target_name, .args = target_arg, .ctx = self.ctx, .func = self.targetFn},
    1 => .{ .name = send_name, .args = send_arg, .ctx = self.ctx, .func = self.sendFn},
    2 => .{ .name = cancelled_name, .args = cancelled_arg, .ctx = self.ctx, .func = self.cancelledFn},
    3 => .{ .name = dnd_drop_performed_name, .args = dnd_drop_performed_arg, .ctx = self.ctx, .func = self.dnd_drop_performedFn},
    4 => .{ .name = dnd_finished_name, .args = dnd_finished_arg, .ctx = self.ctx, .func = self.dnd_finishedFn},
    5 => .{ .name = action_name, .args = action_arg, .ctx = self.ctx, .func = self.actionFn},
        else => null,
        }; }    pub fn offerFn(
        self:*wl_data_source,
        mime_type:String,)
 void {
        try self.conn.sendMessage(self.id.?,0,&[_]Value{
            .{.String = mime_type},
        });
}
    pub fn destroyFn(
        self:*wl_data_source,)
 void {
        try self.conn.sendMessage(self.id.?,1,&[_]Value{
        });
}
    pub fn set_actionsFn(
        self:*wl_data_source,
        dnd_actions:Uint,)
 void {
        try self.conn.sendMessage(self.id.?,2,&[_]Value{
            .{.Uint = dnd_actions},
        });
}

};

pub const wl_data_device = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    id: ?u32,    data_offerFn:?WLCallbackFn = null,
    enterFn:?WLCallbackFn = null,
    leaveFn:?WLCallbackFn = null,
    motionFn:?WLCallbackFn = null,
    dropFn:?WLCallbackFn = null,
    selectionFn:?WLCallbackFn = null,
    const data_offer_name = "data_offer";
    const data_offer_arg = &[_] Arg{
        .{.name = "id", .argType = .NewId},
    };    const enter_name = "enter";
    const enter_arg = &[_] Arg{
        .{.name = "serial", .argType = .Uint},
        .{.name = "surface", .argType = .Object},
        .{.name = "x", .argType = .Fixed},
        .{.name = "y", .argType = .Fixed},
        .{.name = "id", .argType = .Object},
    };    const leave_name = "leave";
    const leave_arg = &[_] Arg{
    };    const motion_name = "motion";
    const motion_arg = &[_] Arg{
        .{.name = "time", .argType = .Uint},
        .{.name = "x", .argType = .Fixed},
        .{.name = "y", .argType = .Fixed},
    };    const drop_name = "drop";
    const drop_arg = &[_] Arg{
    };    const selection_name = "selection";
    const selection_arg = &[_] Arg{
        .{.name = "id", .argType = .Object},
    };    pub fn get_callback(self:wl_data_device,idx:u16) ?WLCallback {
        return switch(idx) {    0 => .{ .name = data_offer_name, .args = data_offer_arg, .ctx = self.ctx, .func = self.data_offerFn},
    1 => .{ .name = enter_name, .args = enter_arg, .ctx = self.ctx, .func = self.enterFn},
    2 => .{ .name = leave_name, .args = leave_arg, .ctx = self.ctx, .func = self.leaveFn},
    3 => .{ .name = motion_name, .args = motion_arg, .ctx = self.ctx, .func = self.motionFn},
    4 => .{ .name = drop_name, .args = drop_arg, .ctx = self.ctx, .func = self.dropFn},
    5 => .{ .name = selection_name, .args = selection_arg, .ctx = self.ctx, .func = self.selectionFn},
        else => null,
        }; }    pub fn start_dragFn(
        self:*wl_data_device,
        source:Object,
        origin:Object,
        icon:Object,
        serial:Uint,)
 void {
        try self.conn.sendMessage(self.id.?,0,&[_]Value{
            .{.Object = source},
            .{.Object = origin},
            .{.Object = icon},
            .{.Uint = serial},
        });
}
    pub fn set_selectionFn(
        self:*wl_data_device,
        source:Object,
        serial:Uint,)
 void {
        try self.conn.sendMessage(self.id.?,1,&[_]Value{
            .{.Object = source},
            .{.Uint = serial},
        });
}
    pub fn releaseFn(
        self:*wl_data_device,)
 void {
        try self.conn.sendMessage(self.id.?,2,&[_]Value{
        });
}

};

pub const wl_data_device_manager = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    id: ?u32,    pub fn get_callback(self:wl_data_device_manager,idx:u16) ?WLCallback {
_ = self;_ = idx;return null; }    pub fn create_data_sourceFn(
        self:*wl_data_device_manager,
        target:?WLCallbackFn,
        send:?WLCallbackFn,
        cancelled:?WLCallbackFn,
        dnd_drop_performed:?WLCallbackFn,
        dnd_finished:?WLCallbackFn,
        action:?WLCallbackFn,
        ctx:?*anyopaque,)
 !u32 {           
           const id = try self.conn.registry.addObject(.{
                       .wl_data_source = .{
                           .id = null,   
                           .ctx = ctx,
                           .conn = self.conn,
        .targetFn = target,
        .sendFn = send,
        .cancelledFn = cancelled,
        .dnd_drop_performedFn = dnd_drop_performed,
        .dnd_finishedFn = dnd_finished,
        .actionFn = action,     },});
        try self.conn.sendMessage(self.id.?,0,&[_]Value{
             .{.NewId = id},
        });
      return id;
}
    pub fn get_data_deviceFn(
        self:*wl_data_device_manager,
        data_offer:?WLCallbackFn,
        enter:?WLCallbackFn,
        leave:?WLCallbackFn,
        motion:?WLCallbackFn,
        drop:?WLCallbackFn,
        selection:?WLCallbackFn,
        ctx:?*anyopaque,
        seat:Object,)
 !u32 {           
           const id = try self.conn.registry.addObject(.{
                       .wl_data_device = .{
                           .id = null,   
                           .ctx = ctx,
                           .conn = self.conn,
        .data_offerFn = data_offer,
        .enterFn = enter,
        .leaveFn = leave,
        .motionFn = motion,
        .dropFn = drop,
        .selectionFn = selection,     },});
        try self.conn.sendMessage(self.id.?,1,&[_]Value{
             .{.NewId = id},
            .{.Object = seat},
        });
      return id;
}

};

pub const wl_shell = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    id: ?u32,    pub fn get_callback(self:wl_shell,idx:u16) ?WLCallback {
_ = self;_ = idx;return null; }    pub fn get_shell_surfaceFn(
        self:*wl_shell,
        ping:?WLCallbackFn,
        configure:?WLCallbackFn,
        popup_done:?WLCallbackFn,
        ctx:?*anyopaque,
        surface:Object,)
 !u32 {           
           const id = try self.conn.registry.addObject(.{
                       .wl_shell_surface = .{
                           .id = null,   
                           .ctx = ctx,
                           .conn = self.conn,
        .pingFn = ping,
        .configureFn = configure,
        .popup_doneFn = popup_done,     },});
        try self.conn.sendMessage(self.id.?,0,&[_]Value{
             .{.NewId = id},
            .{.Object = surface},
        });
      return id;
}

};

pub const wl_shell_surface = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    id: ?u32,    pingFn:?WLCallbackFn = null,
    configureFn:?WLCallbackFn = null,
    popup_doneFn:?WLCallbackFn = null,
    const ping_name = "ping";
    const ping_arg = &[_] Arg{
        .{.name = "serial", .argType = .Uint},
    };    const configure_name = "configure";
    const configure_arg = &[_] Arg{
        .{.name = "edges", .argType = .Uint},
        .{.name = "width", .argType = .Int},
        .{.name = "height", .argType = .Int},
    };    const popup_done_name = "popup_done";
    const popup_done_arg = &[_] Arg{
    };    pub fn get_callback(self:wl_shell_surface,idx:u16) ?WLCallback {
        return switch(idx) {    0 => .{ .name = ping_name, .args = ping_arg, .ctx = self.ctx, .func = self.pingFn},
    1 => .{ .name = configure_name, .args = configure_arg, .ctx = self.ctx, .func = self.configureFn},
    2 => .{ .name = popup_done_name, .args = popup_done_arg, .ctx = self.ctx, .func = self.popup_doneFn},
        else => null,
        }; }    pub fn pongFn(
        self:*wl_shell_surface,
        serial:Uint,)
 void {
        try self.conn.sendMessage(self.id.?,0,&[_]Value{
            .{.Uint = serial},
        });
}
    pub fn moveFn(
        self:*wl_shell_surface,
        seat:Object,
        serial:Uint,)
 void {
        try self.conn.sendMessage(self.id.?,1,&[_]Value{
            .{.Object = seat},
            .{.Uint = serial},
        });
}
    pub fn resizeFn(
        self:*wl_shell_surface,
        seat:Object,
        serial:Uint,
        edges:Uint,)
 void {
        try self.conn.sendMessage(self.id.?,2,&[_]Value{
            .{.Object = seat},
            .{.Uint = serial},
            .{.Uint = edges},
        });
}
    pub fn set_toplevelFn(
        self:*wl_shell_surface,)
 void {
        try self.conn.sendMessage(self.id.?,3,&[_]Value{
        });
}
    pub fn set_transientFn(
        self:*wl_shell_surface,
        parent:Object,
        x:Int,
        y:Int,
        flags:Uint,)
 void {
        try self.conn.sendMessage(self.id.?,4,&[_]Value{
            .{.Object = parent},
            .{.Int = x},
            .{.Int = y},
            .{.Uint = flags},
        });
}
    pub fn set_fullscreenFn(
        self:*wl_shell_surface,
        method:Uint,
        framerate:Uint,
        output:Object,)
 void {
        try self.conn.sendMessage(self.id.?,5,&[_]Value{
            .{.Uint = method},
            .{.Uint = framerate},
            .{.Object = output},
        });
}
    pub fn set_popupFn(
        self:*wl_shell_surface,
        seat:Object,
        serial:Uint,
        parent:Object,
        x:Int,
        y:Int,
        flags:Uint,)
 void {
        try self.conn.sendMessage(self.id.?,6,&[_]Value{
            .{.Object = seat},
            .{.Uint = serial},
            .{.Object = parent},
            .{.Int = x},
            .{.Int = y},
            .{.Uint = flags},
        });
}
    pub fn set_maximizedFn(
        self:*wl_shell_surface,
        output:Object,)
 void {
        try self.conn.sendMessage(self.id.?,7,&[_]Value{
            .{.Object = output},
        });
}
    pub fn set_titleFn(
        self:*wl_shell_surface,
        title:String,)
 void {
        try self.conn.sendMessage(self.id.?,8,&[_]Value{
            .{.String = title},
        });
}
    pub fn set_classFn(
        self:*wl_shell_surface,
        class_:String,)
 void {
        try self.conn.sendMessage(self.id.?,9,&[_]Value{
            .{.String = class_},
        });
}

};

pub const wl_surface = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    id: ?u32,    enterFn:?WLCallbackFn = null,
    leaveFn:?WLCallbackFn = null,
    const enter_name = "enter";
    const enter_arg = &[_] Arg{
        .{.name = "output", .argType = .Object},
    };    const leave_name = "leave";
    const leave_arg = &[_] Arg{
        .{.name = "output", .argType = .Object},
    };    pub fn get_callback(self:wl_surface,idx:u16) ?WLCallback {
        return switch(idx) {    0 => .{ .name = enter_name, .args = enter_arg, .ctx = self.ctx, .func = self.enterFn},
    1 => .{ .name = leave_name, .args = leave_arg, .ctx = self.ctx, .func = self.leaveFn},
        else => null,
        }; }    pub fn destroyFn(
        self:*wl_surface,)
 void {
        try self.conn.sendMessage(self.id.?,0,&[_]Value{
        });
}
    pub fn attachFn(
        self:*wl_surface,
        buffer:Object,
        x:Int,
        y:Int,)
 void {
        try self.conn.sendMessage(self.id.?,1,&[_]Value{
            .{.Object = buffer},
            .{.Int = x},
            .{.Int = y},
        });
}
    pub fn damageFn(
        self:*wl_surface,
        x:Int,
        y:Int,
        width:Int,
        height:Int,)
 void {
        try self.conn.sendMessage(self.id.?,2,&[_]Value{
            .{.Int = x},
            .{.Int = y},
            .{.Int = width},
            .{.Int = height},
        });
}
    pub fn frameFn(
        self:*wl_surface,
        done:?WLCallbackFn,
        ctx:?*anyopaque,)
 !u32 {           
           const id = try self.conn.registry.addObject(.{
                       .wl_callback = .{
                           .id = null,   
                           .ctx = ctx,
                           .conn = self.conn,
        .doneFn = done,     },});
        try self.conn.sendMessage(self.id.?,3,&[_]Value{
             .{.NewId = id},
        });
      return id;
}
    pub fn set_opaque_regionFn(
        self:*wl_surface,
        region:Object,)
 void {
        try self.conn.sendMessage(self.id.?,4,&[_]Value{
            .{.Object = region},
        });
}
    pub fn set_input_regionFn(
        self:*wl_surface,
        region:Object,)
 void {
        try self.conn.sendMessage(self.id.?,5,&[_]Value{
            .{.Object = region},
        });
}
    pub fn commitFn(
        self:*wl_surface,)
 void {
        try self.conn.sendMessage(self.id.?,6,&[_]Value{
        });
}
    pub fn set_buffer_transformFn(
        self:*wl_surface,
        transform:Int,)
 void {
        try self.conn.sendMessage(self.id.?,7,&[_]Value{
            .{.Int = transform},
        });
}
    pub fn set_buffer_scaleFn(
        self:*wl_surface,
        scale:Int,)
 void {
        try self.conn.sendMessage(self.id.?,8,&[_]Value{
            .{.Int = scale},
        });
}
    pub fn damage_bufferFn(
        self:*wl_surface,
        x:Int,
        y:Int,
        width:Int,
        height:Int,)
 void {
        try self.conn.sendMessage(self.id.?,9,&[_]Value{
            .{.Int = x},
            .{.Int = y},
            .{.Int = width},
            .{.Int = height},
        });
}
    pub fn offsetFn(
        self:*wl_surface,
        x:Int,
        y:Int,)
 void {
        try self.conn.sendMessage(self.id.?,10,&[_]Value{
            .{.Int = x},
            .{.Int = y},
        });
}

};

pub const wl_seat = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    id: ?u32,    capabilitiesFn:?WLCallbackFn = null,
    nameFn:?WLCallbackFn = null,
    const capabilities_name = "capabilities";
    const capabilities_arg = &[_] Arg{
        .{.name = "capabilities", .argType = .Uint},
    };    const name_name = "name";
    const name_arg = &[_] Arg{
        .{.name = "name", .argType = .String},
    };    pub fn get_callback(self:wl_seat,idx:u16) ?WLCallback {
        return switch(idx) {    0 => .{ .name = capabilities_name, .args = capabilities_arg, .ctx = self.ctx, .func = self.capabilitiesFn},
    1 => .{ .name = name_name, .args = name_arg, .ctx = self.ctx, .func = self.nameFn},
        else => null,
        }; }    pub fn get_pointerFn(
        self:*wl_seat,
        enter:?WLCallbackFn,
        leave:?WLCallbackFn,
        motion:?WLCallbackFn,
        button:?WLCallbackFn,
        axis:?WLCallbackFn,
        frame:?WLCallbackFn,
        axis_source:?WLCallbackFn,
        axis_stop:?WLCallbackFn,
        axis_discrete:?WLCallbackFn,
        ctx:?*anyopaque,)
 !u32 {           
           const id = try self.conn.registry.addObject(.{
                       .wl_pointer = .{
                           .id = null,   
                           .ctx = ctx,
                           .conn = self.conn,
        .enterFn = enter,
        .leaveFn = leave,
        .motionFn = motion,
        .buttonFn = button,
        .axisFn = axis,
        .frameFn = frame,
        .axis_sourceFn = axis_source,
        .axis_stopFn = axis_stop,
        .axis_discreteFn = axis_discrete,     },});
        try self.conn.sendMessage(self.id.?,0,&[_]Value{
             .{.NewId = id},
        });
      return id;
}
    pub fn get_keyboardFn(
        self:*wl_seat,
        keymap:?WLCallbackFn,
        enter:?WLCallbackFn,
        leave:?WLCallbackFn,
        key:?WLCallbackFn,
        modifiers:?WLCallbackFn,
        repeat_info:?WLCallbackFn,
        ctx:?*anyopaque,)
 !u32 {           
           const id = try self.conn.registry.addObject(.{
                       .wl_keyboard = .{
                           .id = null,   
                           .ctx = ctx,
                           .conn = self.conn,
        .keymapFn = keymap,
        .enterFn = enter,
        .leaveFn = leave,
        .keyFn = key,
        .modifiersFn = modifiers,
        .repeat_infoFn = repeat_info,     },});
        try self.conn.sendMessage(self.id.?,1,&[_]Value{
             .{.NewId = id},
        });
      return id;
}
    pub fn get_touchFn(
        self:*wl_seat,
        down:?WLCallbackFn,
        up:?WLCallbackFn,
        motion:?WLCallbackFn,
        frame:?WLCallbackFn,
        cancel:?WLCallbackFn,
        shape:?WLCallbackFn,
        orientation:?WLCallbackFn,
        ctx:?*anyopaque,)
 !u32 {           
           const id = try self.conn.registry.addObject(.{
                       .wl_touch = .{
                           .id = null,   
                           .ctx = ctx,
                           .conn = self.conn,
        .downFn = down,
        .upFn = up,
        .motionFn = motion,
        .frameFn = frame,
        .cancelFn = cancel,
        .shapeFn = shape,
        .orientationFn = orientation,     },});
        try self.conn.sendMessage(self.id.?,2,&[_]Value{
             .{.NewId = id},
        });
      return id;
}
    pub fn releaseFn(
        self:*wl_seat,)
 void {
        try self.conn.sendMessage(self.id.?,3,&[_]Value{
        });
}

};

pub const wl_pointer = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    id: ?u32,    enterFn:?WLCallbackFn = null,
    leaveFn:?WLCallbackFn = null,
    motionFn:?WLCallbackFn = null,
    buttonFn:?WLCallbackFn = null,
    axisFn:?WLCallbackFn = null,
    frameFn:?WLCallbackFn = null,
    axis_sourceFn:?WLCallbackFn = null,
    axis_stopFn:?WLCallbackFn = null,
    axis_discreteFn:?WLCallbackFn = null,
    const enter_name = "enter";
    const enter_arg = &[_] Arg{
        .{.name = "serial", .argType = .Uint},
        .{.name = "surface", .argType = .Object},
        .{.name = "surface_x", .argType = .Fixed},
        .{.name = "surface_y", .argType = .Fixed},
    };    const leave_name = "leave";
    const leave_arg = &[_] Arg{
        .{.name = "serial", .argType = .Uint},
        .{.name = "surface", .argType = .Object},
    };    const motion_name = "motion";
    const motion_arg = &[_] Arg{
        .{.name = "time", .argType = .Uint},
        .{.name = "surface_x", .argType = .Fixed},
        .{.name = "surface_y", .argType = .Fixed},
    };    const button_name = "button";
    const button_arg = &[_] Arg{
        .{.name = "serial", .argType = .Uint},
        .{.name = "time", .argType = .Uint},
        .{.name = "button", .argType = .Uint},
        .{.name = "state", .argType = .Uint},
    };    const axis_name = "axis";
    const axis_arg = &[_] Arg{
        .{.name = "time", .argType = .Uint},
        .{.name = "axis", .argType = .Uint},
        .{.name = "value", .argType = .Fixed},
    };    const frame_name = "frame";
    const frame_arg = &[_] Arg{
    };    const axis_source_name = "axis_source";
    const axis_source_arg = &[_] Arg{
        .{.name = "axis_source", .argType = .Uint},
    };    const axis_stop_name = "axis_stop";
    const axis_stop_arg = &[_] Arg{
        .{.name = "time", .argType = .Uint},
        .{.name = "axis", .argType = .Uint},
    };    const axis_discrete_name = "axis_discrete";
    const axis_discrete_arg = &[_] Arg{
        .{.name = "axis", .argType = .Uint},
        .{.name = "discrete", .argType = .Int},
    };    pub fn get_callback(self:wl_pointer,idx:u16) ?WLCallback {
        return switch(idx) {    0 => .{ .name = enter_name, .args = enter_arg, .ctx = self.ctx, .func = self.enterFn},
    1 => .{ .name = leave_name, .args = leave_arg, .ctx = self.ctx, .func = self.leaveFn},
    2 => .{ .name = motion_name, .args = motion_arg, .ctx = self.ctx, .func = self.motionFn},
    3 => .{ .name = button_name, .args = button_arg, .ctx = self.ctx, .func = self.buttonFn},
    4 => .{ .name = axis_name, .args = axis_arg, .ctx = self.ctx, .func = self.axisFn},
    5 => .{ .name = frame_name, .args = frame_arg, .ctx = self.ctx, .func = self.frameFn},
    6 => .{ .name = axis_source_name, .args = axis_source_arg, .ctx = self.ctx, .func = self.axis_sourceFn},
    7 => .{ .name = axis_stop_name, .args = axis_stop_arg, .ctx = self.ctx, .func = self.axis_stopFn},
    8 => .{ .name = axis_discrete_name, .args = axis_discrete_arg, .ctx = self.ctx, .func = self.axis_discreteFn},
        else => null,
        }; }    pub fn set_cursorFn(
        self:*wl_pointer,
        serial:Uint,
        surface:Object,
        hotspot_x:Int,
        hotspot_y:Int,)
 void {
        try self.conn.sendMessage(self.id.?,0,&[_]Value{
            .{.Uint = serial},
            .{.Object = surface},
            .{.Int = hotspot_x},
            .{.Int = hotspot_y},
        });
}
    pub fn releaseFn(
        self:*wl_pointer,)
 void {
        try self.conn.sendMessage(self.id.?,1,&[_]Value{
        });
}

};

pub const wl_keyboard = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    id: ?u32,    keymapFn:?WLCallbackFn = null,
    enterFn:?WLCallbackFn = null,
    leaveFn:?WLCallbackFn = null,
    keyFn:?WLCallbackFn = null,
    modifiersFn:?WLCallbackFn = null,
    repeat_infoFn:?WLCallbackFn = null,
    const keymap_name = "keymap";
    const keymap_arg = &[_] Arg{
        .{.name = "format", .argType = .Uint},
        .{.name = "fd", .argType = .Fd},
        .{.name = "size", .argType = .Uint},
    };    const enter_name = "enter";
    const enter_arg = &[_] Arg{
        .{.name = "serial", .argType = .Uint},
        .{.name = "surface", .argType = .Object},
        .{.name = "keys", .argType = .Array},
    };    const leave_name = "leave";
    const leave_arg = &[_] Arg{
        .{.name = "serial", .argType = .Uint},
        .{.name = "surface", .argType = .Object},
    };    const key_name = "key";
    const key_arg = &[_] Arg{
        .{.name = "serial", .argType = .Uint},
        .{.name = "time", .argType = .Uint},
        .{.name = "key", .argType = .Uint},
        .{.name = "state", .argType = .Uint},
    };    const modifiers_name = "modifiers";
    const modifiers_arg = &[_] Arg{
        .{.name = "serial", .argType = .Uint},
        .{.name = "mods_depressed", .argType = .Uint},
        .{.name = "mods_latched", .argType = .Uint},
        .{.name = "mods_locked", .argType = .Uint},
        .{.name = "group", .argType = .Uint},
    };    const repeat_info_name = "repeat_info";
    const repeat_info_arg = &[_] Arg{
        .{.name = "rate", .argType = .Int},
        .{.name = "delay", .argType = .Int},
    };    pub fn get_callback(self:wl_keyboard,idx:u16) ?WLCallback {
        return switch(idx) {    0 => .{ .name = keymap_name, .args = keymap_arg, .ctx = self.ctx, .func = self.keymapFn},
    1 => .{ .name = enter_name, .args = enter_arg, .ctx = self.ctx, .func = self.enterFn},
    2 => .{ .name = leave_name, .args = leave_arg, .ctx = self.ctx, .func = self.leaveFn},
    3 => .{ .name = key_name, .args = key_arg, .ctx = self.ctx, .func = self.keyFn},
    4 => .{ .name = modifiers_name, .args = modifiers_arg, .ctx = self.ctx, .func = self.modifiersFn},
    5 => .{ .name = repeat_info_name, .args = repeat_info_arg, .ctx = self.ctx, .func = self.repeat_infoFn},
        else => null,
        }; }    pub fn releaseFn(
        self:*wl_keyboard,)
 void {
        try self.conn.sendMessage(self.id.?,0,&[_]Value{
        });
}

};

pub const wl_touch = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    id: ?u32,    downFn:?WLCallbackFn = null,
    upFn:?WLCallbackFn = null,
    motionFn:?WLCallbackFn = null,
    frameFn:?WLCallbackFn = null,
    cancelFn:?WLCallbackFn = null,
    shapeFn:?WLCallbackFn = null,
    orientationFn:?WLCallbackFn = null,
    const down_name = "down";
    const down_arg = &[_] Arg{
        .{.name = "serial", .argType = .Uint},
        .{.name = "time", .argType = .Uint},
        .{.name = "surface", .argType = .Object},
        .{.name = "id", .argType = .Int},
        .{.name = "x", .argType = .Fixed},
        .{.name = "y", .argType = .Fixed},
    };    const up_name = "up";
    const up_arg = &[_] Arg{
        .{.name = "serial", .argType = .Uint},
        .{.name = "time", .argType = .Uint},
        .{.name = "id", .argType = .Int},
    };    const motion_name = "motion";
    const motion_arg = &[_] Arg{
        .{.name = "time", .argType = .Uint},
        .{.name = "id", .argType = .Int},
        .{.name = "x", .argType = .Fixed},
        .{.name = "y", .argType = .Fixed},
    };    const frame_name = "frame";
    const frame_arg = &[_] Arg{
    };    const cancel_name = "cancel";
    const cancel_arg = &[_] Arg{
    };    const shape_name = "shape";
    const shape_arg = &[_] Arg{
        .{.name = "id", .argType = .Int},
        .{.name = "major", .argType = .Fixed},
        .{.name = "minor", .argType = .Fixed},
    };    const orientation_name = "orientation";
    const orientation_arg = &[_] Arg{
        .{.name = "id", .argType = .Int},
        .{.name = "orientation", .argType = .Fixed},
    };    pub fn get_callback(self:wl_touch,idx:u16) ?WLCallback {
        return switch(idx) {    0 => .{ .name = down_name, .args = down_arg, .ctx = self.ctx, .func = self.downFn},
    1 => .{ .name = up_name, .args = up_arg, .ctx = self.ctx, .func = self.upFn},
    2 => .{ .name = motion_name, .args = motion_arg, .ctx = self.ctx, .func = self.motionFn},
    3 => .{ .name = frame_name, .args = frame_arg, .ctx = self.ctx, .func = self.frameFn},
    4 => .{ .name = cancel_name, .args = cancel_arg, .ctx = self.ctx, .func = self.cancelFn},
    5 => .{ .name = shape_name, .args = shape_arg, .ctx = self.ctx, .func = self.shapeFn},
    6 => .{ .name = orientation_name, .args = orientation_arg, .ctx = self.ctx, .func = self.orientationFn},
        else => null,
        }; }    pub fn releaseFn(
        self:*wl_touch,)
 void {
        try self.conn.sendMessage(self.id.?,0,&[_]Value{
        });
}

};

pub const wl_output = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    id: ?u32,    geometryFn:?WLCallbackFn = null,
    modeFn:?WLCallbackFn = null,
    doneFn:?WLCallbackFn = null,
    scaleFn:?WLCallbackFn = null,
    nameFn:?WLCallbackFn = null,
    descriptionFn:?WLCallbackFn = null,
    const geometry_name = "geometry";
    const geometry_arg = &[_] Arg{
        .{.name = "x", .argType = .Int},
        .{.name = "y", .argType = .Int},
        .{.name = "physical_width", .argType = .Int},
        .{.name = "physical_height", .argType = .Int},
        .{.name = "subpixel", .argType = .Int},
        .{.name = "make", .argType = .String},
        .{.name = "model", .argType = .String},
        .{.name = "transform", .argType = .Int},
    };    const mode_name = "mode";
    const mode_arg = &[_] Arg{
        .{.name = "flags", .argType = .Uint},
        .{.name = "width", .argType = .Int},
        .{.name = "height", .argType = .Int},
        .{.name = "refresh", .argType = .Int},
    };    const done_name = "done";
    const done_arg = &[_] Arg{
    };    const scale_name = "scale";
    const scale_arg = &[_] Arg{
        .{.name = "factor", .argType = .Int},
    };    const name_name = "name";
    const name_arg = &[_] Arg{
        .{.name = "name", .argType = .String},
    };    const description_name = "description";
    const description_arg = &[_] Arg{
        .{.name = "description", .argType = .String},
    };    pub fn get_callback(self:wl_output,idx:u16) ?WLCallback {
        return switch(idx) {    0 => .{ .name = geometry_name, .args = geometry_arg, .ctx = self.ctx, .func = self.geometryFn},
    1 => .{ .name = mode_name, .args = mode_arg, .ctx = self.ctx, .func = self.modeFn},
    2 => .{ .name = done_name, .args = done_arg, .ctx = self.ctx, .func = self.doneFn},
    3 => .{ .name = scale_name, .args = scale_arg, .ctx = self.ctx, .func = self.scaleFn},
    4 => .{ .name = name_name, .args = name_arg, .ctx = self.ctx, .func = self.nameFn},
    5 => .{ .name = description_name, .args = description_arg, .ctx = self.ctx, .func = self.descriptionFn},
        else => null,
        }; }    pub fn releaseFn(
        self:*wl_output,)
 void {
        try self.conn.sendMessage(self.id.?,0,&[_]Value{
        });
}

};

pub const wl_region = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    id: ?u32,    pub fn get_callback(self:wl_region,idx:u16) ?WLCallback {
_ = self;_ = idx;return null; }    pub fn destroyFn(
        self:*wl_region,)
 void {
        try self.conn.sendMessage(self.id.?,0,&[_]Value{
        });
}
    pub fn addFn(
        self:*wl_region,
        x:Int,
        y:Int,
        width:Int,
        height:Int,)
 void {
        try self.conn.sendMessage(self.id.?,1,&[_]Value{
            .{.Int = x},
            .{.Int = y},
            .{.Int = width},
            .{.Int = height},
        });
}
    pub fn subtractFn(
        self:*wl_region,
        x:Int,
        y:Int,
        width:Int,
        height:Int,)
 void {
        try self.conn.sendMessage(self.id.?,2,&[_]Value{
            .{.Int = x},
            .{.Int = y},
            .{.Int = width},
            .{.Int = height},
        });
}

};

pub const wl_subcompositor = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    id: ?u32,    pub fn get_callback(self:wl_subcompositor,idx:u16) ?WLCallback {
_ = self;_ = idx;return null; }    pub fn destroyFn(
        self:*wl_subcompositor,)
 void {
        try self.conn.sendMessage(self.id.?,0,&[_]Value{
        });
}
    pub fn get_subsurfaceFn(
        self:*wl_subcompositor,
        ctx:?*anyopaque,
        surface:Object,
        parent:Object,)
 !u32 {           
           const id = try self.conn.registry.addObject(.{
                       .wl_subsurface = .{
                           .id = null,   
                           .ctx = ctx,
                           .conn = self.conn,     },});
        try self.conn.sendMessage(self.id.?,1,&[_]Value{
             .{.NewId = id},
            .{.Object = surface},
            .{.Object = parent},
        });
      return id;
}

};

pub const wl_subsurface = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    id: ?u32,    pub fn get_callback(self:wl_subsurface,idx:u16) ?WLCallback {
_ = self;_ = idx;return null; }    pub fn destroyFn(
        self:*wl_subsurface,)
 void {
        try self.conn.sendMessage(self.id.?,0,&[_]Value{
        });
}
    pub fn set_positionFn(
        self:*wl_subsurface,
        x:Int,
        y:Int,)
 void {
        try self.conn.sendMessage(self.id.?,1,&[_]Value{
            .{.Int = x},
            .{.Int = y},
        });
}
    pub fn place_aboveFn(
        self:*wl_subsurface,
        sibling:Object,)
 void {
        try self.conn.sendMessage(self.id.?,2,&[_]Value{
            .{.Object = sibling},
        });
}
    pub fn place_belowFn(
        self:*wl_subsurface,
        sibling:Object,)
 void {
        try self.conn.sendMessage(self.id.?,3,&[_]Value{
            .{.Object = sibling},
        });
}
    pub fn set_syncFn(
        self:*wl_subsurface,)
 void {
        try self.conn.sendMessage(self.id.?,4,&[_]Value{
        });
}
    pub fn set_desyncFn(
        self:*wl_subsurface,)
 void {
        try self.conn.sendMessage(self.id.?,5,&[_]Value{
        });
}

};

pub const wp_presentation = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    id: ?u32,    clock_idFn:?WLCallbackFn = null,
    const clock_id_name = "clock_id";
    const clock_id_arg = &[_] Arg{
        .{.name = "clk_id", .argType = .Uint},
    };    pub fn get_callback(self:wp_presentation,idx:u16) ?WLCallback {
        return switch(idx) {    0 => .{ .name = clock_id_name, .args = clock_id_arg, .ctx = self.ctx, .func = self.clock_idFn},
        else => null,
        }; }    pub fn destroyFn(
        self:*wp_presentation,)
 void {
        try self.conn.sendMessage(self.id.?,0,&[_]Value{
        });
}
    pub fn feedbackFn(
        self:*wp_presentation,
        surface:Object,
        sync_output:?WLCallbackFn,
        presented:?WLCallbackFn,
        discarded:?WLCallbackFn,
        ctx:?*anyopaque,)
 !u32 {           
           const id = try self.conn.registry.addObject(.{
                       .wp_presentation_feedback = .{
                           .id = null,   
                           .ctx = ctx,
                           .conn = self.conn,
        .sync_outputFn = sync_output,
        .presentedFn = presented,
        .discardedFn = discarded,     },});
        try self.conn.sendMessage(self.id.?,1,&[_]Value{
            .{.Object = surface},
             .{.NewId = id},
        });
      return id;
}

};

pub const wp_presentation_feedback = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    id: ?u32,    sync_outputFn:?WLCallbackFn = null,
    presentedFn:?WLCallbackFn = null,
    discardedFn:?WLCallbackFn = null,
    const sync_output_name = "sync_output";
    const sync_output_arg = &[_] Arg{
        .{.name = "output", .argType = .Object},
    };    const presented_name = "presented";
    const presented_arg = &[_] Arg{
        .{.name = "tv_sec_hi", .argType = .Uint},
        .{.name = "tv_sec_lo", .argType = .Uint},
        .{.name = "tv_nsec", .argType = .Uint},
        .{.name = "refresh", .argType = .Uint},
        .{.name = "seq_hi", .argType = .Uint},
        .{.name = "seq_lo", .argType = .Uint},
        .{.name = "flags", .argType = .Uint},
    };    const discarded_name = "discarded";
    const discarded_arg = &[_] Arg{
    };    pub fn get_callback(self:wp_presentation_feedback,idx:u16) ?WLCallback {
        return switch(idx) {    0 => .{ .name = sync_output_name, .args = sync_output_arg, .ctx = self.ctx, .func = self.sync_outputFn},
    1 => .{ .name = presented_name, .args = presented_arg, .ctx = self.ctx, .func = self.presentedFn},
    2 => .{ .name = discarded_name, .args = discarded_arg, .ctx = self.ctx, .func = self.discardedFn},
        else => null,
        }; }
};

pub const wp_viewporter = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    id: ?u32,    pub fn get_callback(self:wp_viewporter,idx:u16) ?WLCallback {
_ = self;_ = idx;return null; }    pub fn destroyFn(
        self:*wp_viewporter,)
 void {
        try self.conn.sendMessage(self.id.?,0,&[_]Value{
        });
}
    pub fn get_viewportFn(
        self:*wp_viewporter,
        ctx:?*anyopaque,
        surface:Object,)
 !u32 {           
           const id = try self.conn.registry.addObject(.{
                       .wp_viewport = .{
                           .id = null,   
                           .ctx = ctx,
                           .conn = self.conn,     },});
        try self.conn.sendMessage(self.id.?,1,&[_]Value{
             .{.NewId = id},
            .{.Object = surface},
        });
      return id;
}

};

pub const wp_viewport = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    id: ?u32,    pub fn get_callback(self:wp_viewport,idx:u16) ?WLCallback {
_ = self;_ = idx;return null; }    pub fn destroyFn(
        self:*wp_viewport,)
 void {
        try self.conn.sendMessage(self.id.?,0,&[_]Value{
        });
}
    pub fn set_sourceFn(
        self:*wp_viewport,
        x:Fixed,
        y:Fixed,
        width:Fixed,
        height:Fixed,)
 void {
        try self.conn.sendMessage(self.id.?,1,&[_]Value{
            .{.Fixed = x},
            .{.Fixed = y},
            .{.Fixed = width},
            .{.Fixed = height},
        });
}
    pub fn set_destinationFn(
        self:*wp_viewport,
        width:Int,
        height:Int,)
 void {
        try self.conn.sendMessage(self.id.?,2,&[_]Value{
            .{.Int = width},
            .{.Int = height},
        });
}

};

pub const xdg_wm_base = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    id: ?u32,    pingFn:?WLCallbackFn = null,
    const ping_name = "ping";
    const ping_arg = &[_] Arg{
        .{.name = "serial", .argType = .Uint},
    };    pub fn get_callback(self:xdg_wm_base,idx:u16) ?WLCallback {
        return switch(idx) {    0 => .{ .name = ping_name, .args = ping_arg, .ctx = self.ctx, .func = self.pingFn},
        else => null,
        }; }    pub fn destroyFn(
        self:*xdg_wm_base,)
 void {
        try self.conn.sendMessage(self.id.?,0,&[_]Value{
        });
}
    pub fn create_positionerFn(
        self:*xdg_wm_base,
        ctx:?*anyopaque,)
 !u32 {           
           const id = try self.conn.registry.addObject(.{
                       .xdg_positioner = .{
                           .id = null,   
                           .ctx = ctx,
                           .conn = self.conn,     },});
        try self.conn.sendMessage(self.id.?,1,&[_]Value{
             .{.NewId = id},
        });
      return id;
}
    pub fn get_xdg_surfaceFn(
        self:*xdg_wm_base,
        configure:?WLCallbackFn,
        ctx:?*anyopaque,
        surface:Object,)
 !u32 {           
           const id = try self.conn.registry.addObject(.{
                       .xdg_surface = .{
                           .id = null,   
                           .ctx = ctx,
                           .conn = self.conn,
        .configureFn = configure,     },});
        try self.conn.sendMessage(self.id.?,2,&[_]Value{
             .{.NewId = id},
            .{.Object = surface},
        });
      return id;
}
    pub fn pongFn(
        self:*xdg_wm_base,
        serial:Uint,)
 void {
        try self.conn.sendMessage(self.id.?,3,&[_]Value{
            .{.Uint = serial},
        });
}

};

pub const xdg_positioner = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    id: ?u32,    pub fn get_callback(self:xdg_positioner,idx:u16) ?WLCallback {
_ = self;_ = idx;return null; }    pub fn destroyFn(
        self:*xdg_positioner,)
 void {
        try self.conn.sendMessage(self.id.?,0,&[_]Value{
        });
}
    pub fn set_sizeFn(
        self:*xdg_positioner,
        width:Int,
        height:Int,)
 void {
        try self.conn.sendMessage(self.id.?,1,&[_]Value{
            .{.Int = width},
            .{.Int = height},
        });
}
    pub fn set_anchor_rectFn(
        self:*xdg_positioner,
        x:Int,
        y:Int,
        width:Int,
        height:Int,)
 void {
        try self.conn.sendMessage(self.id.?,2,&[_]Value{
            .{.Int = x},
            .{.Int = y},
            .{.Int = width},
            .{.Int = height},
        });
}
    pub fn set_anchorFn(
        self:*xdg_positioner,
        anchor:Uint,)
 void {
        try self.conn.sendMessage(self.id.?,3,&[_]Value{
            .{.Uint = anchor},
        });
}
    pub fn set_gravityFn(
        self:*xdg_positioner,
        gravity:Uint,)
 void {
        try self.conn.sendMessage(self.id.?,4,&[_]Value{
            .{.Uint = gravity},
        });
}
    pub fn set_constraint_adjustmentFn(
        self:*xdg_positioner,
        constraint_adjustment:Uint,)
 void {
        try self.conn.sendMessage(self.id.?,5,&[_]Value{
            .{.Uint = constraint_adjustment},
        });
}
    pub fn set_offsetFn(
        self:*xdg_positioner,
        x:Int,
        y:Int,)
 void {
        try self.conn.sendMessage(self.id.?,6,&[_]Value{
            .{.Int = x},
            .{.Int = y},
        });
}
    pub fn set_reactiveFn(
        self:*xdg_positioner,)
 void {
        try self.conn.sendMessage(self.id.?,7,&[_]Value{
        });
}
    pub fn set_parent_sizeFn(
        self:*xdg_positioner,
        parent_width:Int,
        parent_height:Int,)
 void {
        try self.conn.sendMessage(self.id.?,8,&[_]Value{
            .{.Int = parent_width},
            .{.Int = parent_height},
        });
}
    pub fn set_parent_configureFn(
        self:*xdg_positioner,
        serial:Uint,)
 void {
        try self.conn.sendMessage(self.id.?,9,&[_]Value{
            .{.Uint = serial},
        });
}

};

pub const xdg_surface = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    id: ?u32,    configureFn:?WLCallbackFn = null,
    const configure_name = "configure";
    const configure_arg = &[_] Arg{
        .{.name = "serial", .argType = .Uint},
    };    pub fn get_callback(self:xdg_surface,idx:u16) ?WLCallback {
        return switch(idx) {    0 => .{ .name = configure_name, .args = configure_arg, .ctx = self.ctx, .func = self.configureFn},
        else => null,
        }; }    pub fn destroyFn(
        self:*xdg_surface,)
 void {
        try self.conn.sendMessage(self.id.?,0,&[_]Value{
        });
}
    pub fn get_toplevelFn(
        self:*xdg_surface,
        configure:?WLCallbackFn,
        close:?WLCallbackFn,
        configure_bounds:?WLCallbackFn,
        ctx:?*anyopaque,)
 !u32 {           
           const id = try self.conn.registry.addObject(.{
                       .xdg_toplevel = .{
                           .id = null,   
                           .ctx = ctx,
                           .conn = self.conn,
        .configureFn = configure,
        .closeFn = close,
        .configure_boundsFn = configure_bounds,     },});
        try self.conn.sendMessage(self.id.?,1,&[_]Value{
             .{.NewId = id},
        });
      return id;
}
    pub fn get_popupFn(
        self:*xdg_surface,
        configure:?WLCallbackFn,
        popup_done:?WLCallbackFn,
        repositioned:?WLCallbackFn,
        ctx:?*anyopaque,
        parent:Object,
        positioner:Object,)
 !u32 {           
           const id = try self.conn.registry.addObject(.{
                       .xdg_popup = .{
                           .id = null,   
                           .ctx = ctx,
                           .conn = self.conn,
        .configureFn = configure,
        .popup_doneFn = popup_done,
        .repositionedFn = repositioned,     },});
        try self.conn.sendMessage(self.id.?,2,&[_]Value{
             .{.NewId = id},
            .{.Object = parent},
            .{.Object = positioner},
        });
      return id;
}
    pub fn set_window_geometryFn(
        self:*xdg_surface,
        x:Int,
        y:Int,
        width:Int,
        height:Int,)
 void {
        try self.conn.sendMessage(self.id.?,3,&[_]Value{
            .{.Int = x},
            .{.Int = y},
            .{.Int = width},
            .{.Int = height},
        });
}
    pub fn ack_configureFn(
        self:*xdg_surface,
        serial:Uint,)
 void {
        try self.conn.sendMessage(self.id.?,4,&[_]Value{
            .{.Uint = serial},
        });
}

};

pub const xdg_toplevel = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    id: ?u32,    configureFn:?WLCallbackFn = null,
    closeFn:?WLCallbackFn = null,
    configure_boundsFn:?WLCallbackFn = null,
    const configure_name = "configure";
    const configure_arg = &[_] Arg{
        .{.name = "width", .argType = .Int},
        .{.name = "height", .argType = .Int},
        .{.name = "states", .argType = .Array},
    };    const close_name = "close";
    const close_arg = &[_] Arg{
    };    const configure_bounds_name = "configure_bounds";
    const configure_bounds_arg = &[_] Arg{
        .{.name = "width", .argType = .Int},
        .{.name = "height", .argType = .Int},
    };    pub fn get_callback(self:xdg_toplevel,idx:u16) ?WLCallback {
        return switch(idx) {    0 => .{ .name = configure_name, .args = configure_arg, .ctx = self.ctx, .func = self.configureFn},
    1 => .{ .name = close_name, .args = close_arg, .ctx = self.ctx, .func = self.closeFn},
    2 => .{ .name = configure_bounds_name, .args = configure_bounds_arg, .ctx = self.ctx, .func = self.configure_boundsFn},
        else => null,
        }; }    pub fn destroyFn(
        self:*xdg_toplevel,)
 void {
        try self.conn.sendMessage(self.id.?,0,&[_]Value{
        });
}
    pub fn set_parentFn(
        self:*xdg_toplevel,
        parent:Object,)
 void {
        try self.conn.sendMessage(self.id.?,1,&[_]Value{
            .{.Object = parent},
        });
}
    pub fn set_titleFn(
        self:*xdg_toplevel,
        title:String,)
 void {
        try self.conn.sendMessage(self.id.?,2,&[_]Value{
            .{.String = title},
        });
}
    pub fn set_app_idFn(
        self:*xdg_toplevel,
        app_id:String,)
 void {
        try self.conn.sendMessage(self.id.?,3,&[_]Value{
            .{.String = app_id},
        });
}
    pub fn show_window_menuFn(
        self:*xdg_toplevel,
        seat:Object,
        serial:Uint,
        x:Int,
        y:Int,)
 void {
        try self.conn.sendMessage(self.id.?,4,&[_]Value{
            .{.Object = seat},
            .{.Uint = serial},
            .{.Int = x},
            .{.Int = y},
        });
}
    pub fn moveFn(
        self:*xdg_toplevel,
        seat:Object,
        serial:Uint,)
 void {
        try self.conn.sendMessage(self.id.?,5,&[_]Value{
            .{.Object = seat},
            .{.Uint = serial},
        });
}
    pub fn resizeFn(
        self:*xdg_toplevel,
        seat:Object,
        serial:Uint,
        edges:Uint,)
 void {
        try self.conn.sendMessage(self.id.?,6,&[_]Value{
            .{.Object = seat},
            .{.Uint = serial},
            .{.Uint = edges},
        });
}
    pub fn set_max_sizeFn(
        self:*xdg_toplevel,
        width:Int,
        height:Int,)
 void {
        try self.conn.sendMessage(self.id.?,7,&[_]Value{
            .{.Int = width},
            .{.Int = height},
        });
}
    pub fn set_min_sizeFn(
        self:*xdg_toplevel,
        width:Int,
        height:Int,)
 void {
        try self.conn.sendMessage(self.id.?,8,&[_]Value{
            .{.Int = width},
            .{.Int = height},
        });
}
    pub fn set_maximizedFn(
        self:*xdg_toplevel,)
 void {
        try self.conn.sendMessage(self.id.?,9,&[_]Value{
        });
}
    pub fn unset_maximizedFn(
        self:*xdg_toplevel,)
 void {
        try self.conn.sendMessage(self.id.?,10,&[_]Value{
        });
}
    pub fn set_fullscreenFn(
        self:*xdg_toplevel,
        output:Object,)
 void {
        try self.conn.sendMessage(self.id.?,11,&[_]Value{
            .{.Object = output},
        });
}
    pub fn unset_fullscreenFn(
        self:*xdg_toplevel,)
 void {
        try self.conn.sendMessage(self.id.?,12,&[_]Value{
        });
}
    pub fn set_minimizedFn(
        self:*xdg_toplevel,)
 void {
        try self.conn.sendMessage(self.id.?,13,&[_]Value{
        });
}

};

pub const xdg_popup = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    id: ?u32,    configureFn:?WLCallbackFn = null,
    popup_doneFn:?WLCallbackFn = null,
    repositionedFn:?WLCallbackFn = null,
    const configure_name = "configure";
    const configure_arg = &[_] Arg{
        .{.name = "x", .argType = .Int},
        .{.name = "y", .argType = .Int},
        .{.name = "width", .argType = .Int},
        .{.name = "height", .argType = .Int},
    };    const popup_done_name = "popup_done";
    const popup_done_arg = &[_] Arg{
    };    const repositioned_name = "repositioned";
    const repositioned_arg = &[_] Arg{
        .{.name = "token", .argType = .Uint},
    };    pub fn get_callback(self:xdg_popup,idx:u16) ?WLCallback {
        return switch(idx) {    0 => .{ .name = configure_name, .args = configure_arg, .ctx = self.ctx, .func = self.configureFn},
    1 => .{ .name = popup_done_name, .args = popup_done_arg, .ctx = self.ctx, .func = self.popup_doneFn},
    2 => .{ .name = repositioned_name, .args = repositioned_arg, .ctx = self.ctx, .func = self.repositionedFn},
        else => null,
        }; }    pub fn destroyFn(
        self:*xdg_popup,)
 void {
        try self.conn.sendMessage(self.id.?,0,&[_]Value{
        });
}
    pub fn grabFn(
        self:*xdg_popup,
        seat:Object,
        serial:Uint,)
 void {
        try self.conn.sendMessage(self.id.?,1,&[_]Value{
            .{.Object = seat},
            .{.Uint = serial},
        });
}
    pub fn repositionFn(
        self:*xdg_popup,
        positioner:Object,
        token:Uint,)
 void {
        try self.conn.sendMessage(self.id.?,2,&[_]Value{
            .{.Object = positioner},
            .{.Uint = token},
        });
}

};

