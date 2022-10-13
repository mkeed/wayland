pub const Wayland = struct {
    pub fn init(alloc: std.mem.Allocator) Wayland {}
    pub fn deinit(self: *Wayland) void {}
    pub fn createWindow(self: *Wayland) WaylandWindow {}
};

pub const WaylandWindow = struct {
    //
};
