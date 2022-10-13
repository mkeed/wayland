const std = @import("std");

const wl_display = struct {
    ctx: ?*anyopaque,
    conn: *WLConnection,
    funcs: [2]?WLCallback = [2]?WLCallback{ null, null },
    pub fn sync(
        self: *wl_display,
        doneFn: ?WLCallback,
        ctx: ?*anyopaqe,
    ) !*wl_callback {
        var wl_callback = try conn.alloc.create(wl_display);
        errdefer conn.alloc.destroy(wl_callback);
        wl_callback.* = wl_callback{
            .ctx = ctx,
            .conn = conn,
            .funcs = [1]?WLCallback{doneFn},
        };
        const id = try conn.registerObject(.{ .wl_callbackV = wl_callback });
        try conn.sendMessage(
            self.id,
            0, //sync
            &.{
                .{ .NewId = id },
            },
        );
    }
    pub fn get_registry(
        self: *wl_display,
    ) void {}
};
