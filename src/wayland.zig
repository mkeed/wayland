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
