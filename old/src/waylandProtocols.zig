const std = @import("std");
const xml = @import("xml.zig");
const waylandFile = "/usr/share/wayland/wayland.xml";
const protocolsDir = "/usr/share/wayland-protocols/";

const stages = [_][]const u8{
    "stable",
    //"unstable",
    //"staging",
};



pub const Protocol = struct {
    pub const Description = struct {
        pub fn init(alloc: std.mem.Allocator, node: *xml.XMLNode) !Description {
            var summary = std.ArrayList(u8).init(alloc);
            var value = std.ArrayList(u8).init(alloc);
            if (node.getTag("summary")) |val| {
                try summary.appendSlice(val);
            }
            for (node.contents.items) |content| {
                switch (content) {
                    .str => |str| {
                        try value.appendSlice(str);
                    },
                    .node => {
                        try value.appendSlice("<XMLNode>");
                    },
                }
            }
            return Description{
                .summary = summary,
                .value = value,
            };
        }
        pub fn deinit(self: Description) void {
            self.summary.deinit();
            self.value.deinit();
        }
        pub fn format(self: Description, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = fmt;
            _ = options;
            try std.fmt.format(writer, "Summary:{s}", .{self.summary.items});
        }
        summary: std.ArrayList(u8),
        value: std.ArrayList(u8),
    };
    pub const WayEnum = struct {
        pub const Entry = struct {
            pub fn init(alloc: std.mem.Allocator) Entry {
                return .{
                    .name = std.ArrayList(u8).init(alloc),
                    .value = 0,
                    .summary = std.ArrayList(u8).init(alloc),
                };
            }
            pub fn deinit(self: Entry) void {
                self.name.deinit();
                self.summary.deinit();
            }
            name: std.ArrayList(u8),
            value: usize,
            summary: std.ArrayList(u8),
        };
        pub fn init(alloc: std.mem.Allocator) WayEnum {
            return .{
                .alloc = alloc,
                .name = std.ArrayList(u8).init(alloc),
                .description = std.ArrayList(u8).init(alloc),
                .entries = std.ArrayList(Entry).init(alloc),
            };
        }
        pub fn deinit(self: WayEnum) void {
            self.name.deinit();
            self.description.deinit();
            for (self.entries.items) |ei| {
                ei.deinit();
            }
            self.deinit();
        }
        alloc: std.mem.Allocator,
        name: std.ArrayList(u8),
        description: std.ArrayList(u8),
        entries: std.ArrayList(Entry),
    };

    pub const Arg = struct {
        const ArgParse = struct {
            str: []const u8,
            val: ValueType,
        };
        const datatypes = [_]ArgParse{
            .{ .str = "uint", .val = .Uint },
            .{ .str = "int", .val = .Int },
            .{ .str = "new_id", .val = .NewId },
            .{ .str = "fixed", .val = .Fixed },
            .{ .str = "object", .val = .Object },
            .{ .str = "string", .val = .String },
            .{ .str = "array", .val = .Array },
            .{ .str = "fd", .val = .Fd },
        };
        fn parseType(name: []const u8) !ValueType {
            for (datatypes) |dt| {
                if (std.mem.eql(u8, name, dt.str)) {
                    return dt.val;
                }
            }
            std.log.err("Type not found:[{s}]", .{name});
            return error.TypeNotFound;
        }
        pub fn init(alloc: std.mem.Allocator, node: *xml.XMLNode, list: *std.ArrayList(Arg)) !void {
            const name = node.getTag("name") orelse return error.MisisngField;
            const typename = node.getTag("type") orelse return error.MissingField;
            const typeval = try parseType(typename);
            const interface = node.getTag("interface");

            var arg = Arg{
                .name = std.ArrayList(u8).init(alloc),
                .interface = null,
                .argType = typeval,
            };
            errdefer arg.deinit();

            try arg.name.appendSlice(name);

            if (typeval == .NewId) {
                if (interface) |i| {
                    arg.interface = std.ArrayList(u8).init(alloc);
                    try arg.interface.?.appendSlice(i);
                }
            }
            try list.append(arg);
        }
        pub fn deinit(self: Arg) void {
            self.name.deinit();
            if (self.interface) |si| {
                si.deinit();
            }
        }
        pub fn generate(self: Arg, writer: anytype) !void {
            const int = if (self.interface) |i| i.items else "null";
            try std.fmt.format(writer,
                \\Arg{{.name = "{s}", .valueType = .{s},.interface = "{s}"}},
            , .{ self.name.items, self.argType.toString(), int });
        }
        pub fn format(self: Arg, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = fmt;
            _ = options;
            const int = if (self.interface) |i| i.items else "";
            try std.fmt.format(writer, "[{s} => {s} {s}], ", .{ self.name.items, self.argType.toString(), int });
        }
        name: std.ArrayList(u8),
        interface: ?std.ArrayList(u8),
        argType: ValueType,
    };

    pub const ValueType = enum {
        Int,
        Uint,
        Fixed,
        String,
        Object,
        NewId,
        Array,
        Fd,
        pub fn toString(self: ValueType) []const u8 {
            return switch (self) {
                .Int => "Int",
                .Uint => "Uint",
                .Fixed => "Fixed",
                .String => "String",
                .Object => "Object",
                .NewId => "NewId",
                .Array => "Array",
                .Fd => "Fd",
            };
        }
    };

    pub const Request = struct {
        pub fn init(
            alloc: std.mem.Allocator,
            node: *xml.XMLNode,
            prots: *Protocols,
            requestId: u32,
        ) !Request {
            var req = Request{
                .prots = prots,
                .name = std.ArrayList(u8).init(alloc),
                .args = std.ArrayList(Arg).init(alloc),
                .requestId = requestId,
            };
            errdefer req.deinit();
            const name = node.getTag("name") orelse return error.MissingValue;
            try req.name.appendSlice(name);
            var argIter = node.nodesIter(&.{"arg"});
            while (argIter.next()) |argItem| {
                try Arg.init(alloc, argItem, &req.args);
                //try req.args.append(arg);
            }
            return req;
        }
        pub fn deinit(self: Request) void {
            self.name.deinit();
            for (self.args.items) |ai| {
                ai.deinit();
            }
            self.args.deinit();
        }
        pub fn format(self: Request, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = options;
            if (std.mem.eql(u8, fmt, "args")) {
                try self.argsFmt(writer);
            } else if (std.mem.eql(u8, fmt, "body")) {
                try self.bodyFmt(writer);
            } else {
                @panic("error");
            }
        }
        pub fn generate(self: Request, writer: anytype) !void {
            try std.fmt.format(writer,
                \\Request{{
                \\    .name = "{s}",
                \\    .args = &.{{
            , .{self.name.items});
            for (self.args.items) |arg| {
                try arg.generate(writer);
            }

            try std.fmt.format(writer, "}},\n}},", .{});
        }
        pub fn returnType(self: Request, buffer: []u8) ![]const u8 {
            for (self.args.items) |arg| {
                if (arg.argType == .NewId) {
                    if (arg.interface) |_| {
                        return try std.fmt.bufPrint(buffer, "!u32", .{});
                    }
                }
            }
            return try std.fmt.bufPrint(buffer, "void", .{});
        }
        pub fn bodyFmt(
            self: Request,
            writer: anytype,
        ) !void {
            var createinterface: ?[]const u8 = null;
            //try std.fmt.format(writer, "\n        _ = self;", .{});
            for (self.args.items) |arg| {
                switch (arg.argType) {
                    .NewId => {
                        createinterface = "return id;";
                        if (arg.interface) |interface| {
                            try std.fmt.format(writer,
                                \\           
                                \\           const id = try self.conn.registry.addObject(.{{
                                \\                       .{s} = .{{
                                \\                           .id = null,   
                                \\                           .ctx = ctx,
                                \\                           .conn = self.conn,
                            , .{interface.items});
                            const inter = self.prots.findInterface(interface.items) orelse unreachable;
                            for (inter.events.items) |ev| {
                                try std.fmt.format(writer, "\n        .{s}Fn = {s},", .{ ev.name.items, ev.name.items });
                            }
                            try std.fmt.format(writer, "     }},}});", .{});
                        } else {
                            createinterface = " return interface.id;";
                            //try std.fmt.format(writer, "\n        _ = interface;", .{});
                        }
                    },
                    else => {
                        //try std.fmt.format(writer, "\n        _ = {s};", .{arg.name.items});
                    },
                }
            }
            try std.fmt.format(writer, "\n        try self.conn.sendMessage(self.id.?,{},&[_]Value{{", .{self.requestId});

            for (self.args.items) |arg| {
                switch (arg.argType) {
                    .NewId => {
                        if (arg.interface) |_| {
                            try std.fmt.format(writer, "\n             .{{.NewId = id}},", .{});
                        } else {
                            try std.fmt.format(writer, "\n            .{{.String = interface.string}},", .{});
                            try std.fmt.format(writer, "\n            .{{.Uint = interface.version}},", .{});
                            try std.fmt.format(writer, "\n            .{{.NewId  = interface.id}},", .{});
                        }
                    },
                    else => {
                        try std.fmt.format(writer, "\n            .{{.{s} = {s}}},", .{ arg.argType.toString(), arg.name.items });
                    },
                }
            }

            try std.fmt.format(writer, "\n        }});", .{});
            if (createinterface) |ci| {
                try std.fmt.format(writer, "\n      {s}", .{ci});
            }
        }

        pub fn argsFmt(
            self: Request,
            writer: anytype,
        ) !void {
            for (self.args.items) |arg| {
                switch (arg.argType) {
                    .NewId => {
                        if (arg.interface) |interface| {
                            const inter = self.prots.findInterface(interface.items) orelse unreachable;
                            for (inter.events.items) |ev| {
                                try std.fmt.format(writer, "\n        {s}:?WLCallbackFn,", .{ev.name.items});
                            }
                            try std.fmt.format(writer, "\n        ctx:?*anyopaque,", .{});
                        } else {
                            try std.fmt.format(writer, "\n        interface:WLInterface,", .{});
                        }
                    },
                    else => {
                        try std.fmt.format(writer, "\n        {s}:{s},", .{ arg.name.items, arg.argType.toString() });
                    },
                }
            }
        }
        prots: *Protocols,
        name: std.ArrayList(u8),
        args: std.ArrayList(Arg),
        requestId: u32,
    };
    pub const Event = struct {
        pub fn init(alloc: std.mem.Allocator, node: *xml.XMLNode, eventId: u32) !Event {
            var event = Event{
                .name = std.ArrayList(u8).init(alloc),
                .args = std.ArrayList(Arg).init(alloc),
                .eventId = eventId,
            };
            errdefer event.deinit();
            const name = node.getTag("name") orelse return error.MissingValue;
            try event.name.appendSlice(name);
            var argIter = node.nodesIter(&.{"arg"});
            while (argIter.next()) |argItem| {
                try Arg.init(alloc, argItem, &event.args);
            }
            return event;
        }
        pub fn deinit(self: Event) void {
            self.name.deinit();
            for (self.args.items) |ai| {
                ai.deinit();
            }
            self.args.deinit();
        }
        pub fn generate(self: Event, writer: anytype) !void {
            try std.fmt.format(writer,
                \\Event{{
                \\    .name = "{s}",
                \\    .args = &.{{
            , .{self.name.items});
            for (self.args.items) |arg| {
                try arg.generate(writer);
            }

            try std.fmt.format(writer, "}},\n}},", .{});
        }
        pub fn format(self: Event, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = fmt;
            _ = options;
            try std.fmt.format(writer, "Event: {s} => {{", .{self.name.items});
            for (self.args.items) |ai| {
                try std.fmt.format(writer, "{}", .{ai});
            }
            try std.fmt.format(writer, "}}", .{});
        }
        name: std.ArrayList(u8),
        args: std.ArrayList(Arg),
        eventId: u32,
    };
    pub const Interface = struct {
        pub fn init(alloc: std.mem.Allocator) Interface {
            return .{
                .alloc = alloc,
                .description = null,
                .name = std.ArrayList(u8).init(alloc),
                .version = 0,
                .requests = std.ArrayList(Request).init(alloc),
                .events = std.ArrayList(Event).init(alloc),
                .enums = std.ArrayList(WayEnum).init(alloc),
            };
        }
        pub fn deinit(self: Interface) void {
            if (self.description) |desc| {
                desc.deinit();
            }
            self.name.deinit();
            for (self.requests.items) |ri| {
                ri.deinit();
            }
            self.requests.deinit();
            for (self.events.items) |ei| {
                ei.deinit();
            }
            self.events.deinit();
            for (self.enums.items) |ei| {
                ei.deinit();
            }
            self.enums.deinit();
        }
        pub fn generate(self: Interface, writer: anytype, protos: Protocols) !void {
            _ = protos;
            try std.fmt.format(writer, "pub const {s} = struct {{\nid:u32,\n", .{
                self.name.items,
            });
            for (self.events.items) |event| {
                try std.fmt.format(writer, "\t{s}:?WLCallbackFn,\n", .{event.name.items});
            }
            for (self.requests.items) |request| {
                try std.fmt.format(writer, "\tpub fn {s} (\n", .{request.name.items});
                for (request.args.items) |arg| {
                    try std.fmt.format(writer, "\t\t{s}:{s},\n", .{ arg.name.items, arg.argType.toString() });
                }
                try std.fmt.format(writer, "\t) !void {{}}\n\n", .{});
            }

            try std.fmt.format(writer, "}};\n", .{});
        }

        alloc: std.mem.Allocator,
        description: ?Description,
        name: std.ArrayList(u8),
        version: usize,
        requests: std.ArrayList(Request),
        events: std.ArrayList(Event),
        enums: std.ArrayList(WayEnum),
    };
    pub fn init(alloc: std.mem.Allocator) Protocol {
        return .{
            .alloc = alloc,
            .name = std.ArrayList(u8).init(alloc),
            .interfaces = std.ArrayList(Interface).init(alloc),
        };
    }
    pub fn deinit(self: Protocol) void {
        self.name.deinit();
        for (self.interfaces.items) |ii| {
            ii.deinit();
        }
        self.interfaces.deinit();
    }
    pub fn addInterface(self: *Protocol, inter: Interface) !void {
        try self.interfaces.append(inter);
    }

    pub fn format(self: Protocol, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        for (self.interfaces.items) |ii| {
            try std.fmt.format(writer, "Interface:{}\n", .{ii});
        }
    }

    pub fn generateInfo(self: Protocol, info: *GenInfo, proto: *Protocols) !void {
        try info.name.appendSlice(self.name.items);
        var writer = info.code.writer();
        for (self.interfaces.items) |int| {
            try int.generate(writer, proto);
        }
    }

    alloc: std.mem.Allocator,
    name: std.ArrayList(u8),
    interfaces: std.ArrayList(Interface),
};

pub fn parseInterface(alloc: std.mem.Allocator, node: *xml.XMLNode, prots: *Protocols) !Protocol.Interface {
    var interface = Protocol.Interface.init(alloc);
    errdefer interface.deinit();
    if (node.getTag("name")) |val| {
        try interface.name.appendSlice(val);
    }
    if (node.getTag("version")) |val| {
        const version = try std.fmt.parseInt(usize, val, 10);
        interface.version = version;
    }

    if (node.getSingleNode("description")) |desc| {
        interface.description = try Protocol.Description.init(alloc, desc);
    }

    var reqIter = node.nodesIter(&.{"request"});
    var reqIdx: u32 = 0;
    while (reqIter.next()) |req| {
        defer reqIdx += 1;
        var request = try Protocol.Request.init(alloc, req, prots, reqIdx);
        errdefer request.deinit();
        try interface.requests.append(request);
    }

    var eventIter = node.nodesIter(&.{"event"});
    var evidx: u32 = 0;
    while (eventIter.next()) |ev| {
        defer evidx += 1;
        var event = try Protocol.Event.init(alloc, ev, evidx);
        errdefer event.deinit();
        try interface.events.append(event);
    }
    return interface;
}

pub fn GenerateProtocol(alloc: std.mem.Allocator, fileData: []const u8, prots: *Protocols) !Protocol {
    var protoXML = try xml.ParseXML(alloc, fileData);
    defer protoXML.deinit();
    var proto = Protocol.init(alloc);
    errdefer proto.deinit();
    {
        if (protoXML.getSingleNode("protocol")) |p| {
            if (p.getTag("name")) |name| {
                try proto.name.appendSlice(name);
            }
        }
        //interfaces
        var interfaceNodes = std.ArrayList(*xml.XMLNode).init(alloc);
        defer interfaceNodes.deinit();
        try protoXML.getNodes(&interfaceNodes, &.{ "protocol", "interface" });

        for (interfaceNodes.items) |item| {
            proto.addInterface(try parseInterface(alloc, item, prots)) catch |err| {
                std.log.err("failed to create protocol:{s}", .{fileData[0..256]});
                return err;
            };
        }
    }

    return proto;
}

pub const GenInfo = struct {
    pub fn init(alloc: std.mem.Allocator) GenInfo {
        return GenInfo{
            .name = std.ArrayList(u8).init(alloc),
            .code = std.ArrayList(u8).init(alloc),
        };
    }
    pub fn deinit(self: GenInfo) void {
        self.name.deinit();
        self.code.deinit();
    }
    name: std.ArrayList(u8),
    code: std.ArrayList(u8),
};

pub const DuplicatePrinter = struct {
    num: usize,
    string: []const u8,
    delimiter: []const u8,
    endDelim: bool,
    pub fn format(
        self: DuplicatePrinter,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        if (self.num == 0) {
            return;
        }
        var count: usize = 0;
        while (count < self.num) : (count += 1) {
            if (count > 0) {
                try std.fmt.format(writer, "{s}", .{self.delimiter});
            }
            try std.fmt.format(writer, "{s}", .{self.string});
        }
        if (self.endDelim) {
            try std.fmt.format(writer, "{s}", .{self.delimiter});
        }
    }
};

pub fn duplicatePrinter(num: usize, string: []const u8, delimiter: []const u8, endDelim: bool) DuplicatePrinter {
    return .{
        .num = num,
        .string = string,
        .delimiter = delimiter,
        .endDelim = endDelim,
    };
}

pub const Protocols = struct {
    protocols: std.ArrayList(Protocol),
    pub fn init(alloc: std.mem.Allocator) Protocols {
        return .{
            .protocols = std.ArrayList(Protocol).init(alloc),
        };
    }
    pub fn deinit(self: Protocols) void {
        for (self.protocols.items) |item| {
            item.deinit();
        }
        self.protocols.deinit();
    }
    pub fn addProtocol(self: *Protocols, p: Protocol) !void {
        try self.protocols.append(p);
    }

    pub fn findInterface(self: *Protocols, name: []const u8) ?Protocol.Interface {
        for (self.protocols.items) |prot| {
            for (prot.interfaces.items) |inter| {
                if (std.mem.eql(u8, name, inter.name.items)) {
                    return inter;
                }
            }
        }
        return null;
    }
    pub fn maxEvents(self: *Protocols) usize {
        var max: usize = 0;
        for (self.protocols.items) |prot| {
            for (prot.interfaces.items) |inter| {
                if (inter.events.items.len > max) {
                    max = inter.events.items.len;
                }
            }
        }
        return max;
    }
    pub fn generateStructs(self: *Protocols, writer: anytype) !void {
        for (self.protocols.items) |prot| {
            for (prot.interfaces.items) |inter| {
                try std.fmt.format(writer,
                    \\pub const {s} = struct {{
                    \\    ctx: ?*anyopaque,
                    \\    conn: *WLConnection,
                    \\    id: ?u32,
                , .{
                    inter.name.items,
                });
                //inter.events.items.len,
                //inter.events.items.len,
                //duplicatePrinter(inter.events.items.len, "null", ", ", false),

                for (inter.events.items) |event| {
                    try std.fmt.format(writer, "    {s}Fn:?WLCallbackFn = null,\n", .{event.name.items});
                }
                for (inter.events.items) |event| {
                    try std.fmt.format(writer, "    const {s}_name = \"{s}\";\n", .{ event.name.items, event.name.items });
                    try std.fmt.format(writer, "    const {s}_arg = &[_] Arg{{\n", .{event.name.items});
                    for (event.args.items) |arg| {
                        try std.fmt.format(writer, "        .{{.name = \"{s}\", .argType = .{s}}},\n", .{ arg.name.items, arg.argType.toString() });
                    }
                    try std.fmt.format(writer, "    }};", .{});
                }
                try std.fmt.format(writer,
                    \\    pub fn get_callback(self:{s},idx:u16) ?WLCallback {{
                    \\
                , .{inter.name.items});

                if (inter.events.items.len == 0) {
                    try std.fmt.format(writer, "_ = self;", .{});
                    try std.fmt.format(writer, "_ = idx;", .{});
                    try std.fmt.format(writer, "return null;", .{});
                } else {
                    try std.fmt.format(writer,
                        \\        return switch(idx) {{
                    , .{});
                    for (inter.events.items) |event, idx| {
                        try std.fmt.format(writer, "    {} => .{{ .name = {s}_name, .args = {s}_arg, .ctx = self.ctx, .func = self.{s}Fn}},\n", .{ idx, event.name.items, event.name.items, event.name.items });
                    }

                    try std.fmt.format(writer,
                        \\        else => null,
                        \\        }};
                    , .{});
                }
                try std.fmt.format(writer,
                    \\ }}
                , .{});

                for (inter.requests.items) |req| {
                    var buf: [512]u8 = undefined;
                    const returnType = try req.returnType(&buf);
                    try std.fmt.format(writer, "    pub fn {s}Fn(\n        self:*{s},{args})\n {s} {{{body}\n}}\n", .{
                        req.name.items,
                        inter.name.items,
                        req,
                        returnType,
                        req,
                    });
                }
                try std.fmt.format(writer, "\n}};\n\n", .{});
            }
        }
    }
    pub fn generateEnum(self: *Protocols, writer: anytype) !void {
        try std.fmt.format(writer, "pub const WLInterfaceType = enum{{", .{});
        for (self.protocols.items) |prot| {
            for (prot.interfaces.items) |inter| {
                try std.fmt.format(writer, "\n    {s},", .{inter.name.items});
            }
        }
        try std.fmt.format(writer, "\n}};\n", .{});

        _ = try writer.write(
            \\pub const InterfaceString = struct {
            \\    name:[]const u8,
            \\    interface:WLInterfaceType,
            \\};
            \\pub const interfaceStrings = [_]InterfaceString{
            \\
        );

        for (self.protocols.items) |prot| {
            for (prot.interfaces.items) |inter| {
                try std.fmt.format(writer, "\n    .{{.name = \"{s}\",.interface = .{s}}},", .{ inter.name.items, inter.name.items });
            }
        }
        try std.fmt.format(writer, "\n}};\n", .{});
    }

    pub fn generateUnion(self: *Protocols, writer: anytype) !void {
        for (self.protocols.items) |prot| {
            for (prot.interfaces.items) |inter| {
                try std.fmt.format(writer, "\n    {s}: {s},", .{
                    inter.name.items, inter.name.items,
                });
            }
        }
        try std.fmt.format(writer,
            \\ pub fn getcallback(self:WLInterface,idx:u16) ?WLCallback {{
            \\ return switch(self) {{
        , .{});
        for (self.protocols.items) |prot| {
            for (prot.interfaces.items) |inter| {
                try std.fmt.format(writer, "\n    .{s} => |val| val.get_callback(idx), ", .{
                    inter.name.items,
                });
            }
        }
        try std.fmt.format(writer,
            \\   }};
            \\}}
        , .{});
    }
};

pub fn generateProtocolFile(alloc: std.mem.Allocator) !std.ArrayList(u8) {
    var file = std.ArrayList(u8).init(alloc);
    errdefer file.deinit();
    var files = try getFiles(alloc);
    defer {
        for (files.items) |fi| {
            fi.deinit();
        }
        files.deinit();
    }

    var protocolsGen = std.ArrayList(GenInfo).init(alloc);

    defer {
        for (protocolsGen.items) |pi| {
            pi.deinit();
        }
        protocolsGen.deinit();
    }

    var protocols = Protocols.init(alloc);
    defer protocols.deinit();

    for (files.items) |fi| {
        var proto = try GenerateProtocol(alloc, fi.items, &protocols);
        errdefer proto.deinit();

        try protocols.addProtocol(proto);
    }

    var writer = file.writer();

    _ = try writer.write(@embedFile("waylandProtocolDefs.zig"));
    try protocols.generateEnum(writer);
    try std.fmt.format(writer, "pub const WLInterface = union(enum) {{", .{});
    try protocols.generateUnion(writer);
    try std.fmt.format(writer, "\n}};\n\n", .{});
    try protocols.generateStructs(writer);
    //for (protocolsGen.items) |fi| {
    //try std.fmt.format(writer, "name: {s}", .{fi.name.items});
    //try std.fmt.format(writer, "code: {s}", .{fi.code.items});
    //}

    return file;
}

test {
    var alloc = std.testing.allocator;
    var file = try generateProtocolFile(alloc);
    defer file.deinit();
    //var out = std.io.getStdOut();
    var fileOut = try std.fs.cwd().createFile("waylandOutput2.zig", .{});
    defer fileOut.close();
    var writer = fileOut.writer();

    _ = try writer.write(file.items);
}
