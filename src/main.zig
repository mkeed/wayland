const std = @import("std");
const wayland = @import("wayland");

pub const Context = struct {
    conn: *wayland.WLConnection,
    xdg: ?*wayland.WLObject,
    pub fn deint(self: *Context) void {
        defer self.conn.deinit();
    }
};

pub fn pingFn(ctx: ?*anyopaque, conn: *wayland.WLConnection, args: []const wayland.Value) void {
    //
}

pub fn globalSync(ctx: ?*anyopaque, conn: *wayland.WLConnection, args: []const wayland.Value) void {
    std.log.info("Done", .{});
    const self = wayland.castTo(Context, ctx.?);
    self.conn.registry.bindFn(reg.getInterface(.wl_compositor) orelse return, .{ .wl_compositor = .{ .ctx = null, .conn = conn, .id = null } }) catch return;

    reg.bindFn(reg.getInterface(.xdg_wm_base) orelse return, .{ .xdg_wm_base = .{ .ctx = null, .conn = conn, .id = null, .pingFn = &pingFn } }) catch return;

    _ = args;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var ctx = try alloc.create(Context);
    defer ctx.deinit();

    ctx.* = Context{
        .conn = try wayland.WLConnection.init(alloc),
    };
    defer ctx.deinit();

    var wlObj_ = (conn.getObject(1) orelse unreachable);
    var wlObj = wlObj_.interface.wl_display;
    var reg = try wlObj.get_registryFn(
        wayland.Registry.global,
        wayland.Registry.global_remove,
        &conn.registry,
    );
    ctx.reg = reg;
    var sync = try wlObj.syncFn(globalSync, ctx);
    _ = sync;
    var pollfds = [1]std.os.pollfd{
        .{
            .fd = conn.stream.handle,
            .events = std.os.POLL.IN,
            .revents = 0,
        },
    };

    while (true) {
        const nfds = try std.os.poll(pollfds[0..], -1);
        if (nfds == 0) continue;
        if (pollfds[0].revents & std.os.POLL.IN != 0) {
            try conn.readMessage();
        }
    }
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
