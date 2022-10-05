const std = @import("std");
const wp = @import("src/waylandProtocols.zig");

pub const GenerateWaylandFile = struct {
    step: std.build.Step,
    builder: *std.build.Builder,
    package: std.build.Pkg,
    output_file: std.build.GeneratedFile,

    pub fn init(builder: *std.build.Builder) *GenerateWaylandFile {
        const self = builder.allocator.create(GenerateWaylandFile) catch unreachable;
        const full_out_path = std.fs.path.join(builder.allocator, &[_][]const u8{
            builder.build_root,
            builder.cache_root,
            "waylandOutput.zig",
        }) catch unreachable;

        self.* = .{
            .step = std.build.Step.init(.custom, "wayland", builder.allocator, make),
            .builder = builder,
            .package = .{
                .name = "wayland",
                .source = .{ .generated = &self.output_file },
                .dependencies = null,
            },
            .output_file = .{
                .step = &self.step,
                .path = full_out_path,
            },
        };
        return self;
    }

    fn make(step: *std.build.Step) !void {
        const self = @fieldParentPtr(GenerateWaylandFile, "step", step);
        const cwd = std.fs.cwd();

        var file_contents = try wp.generateProtocolFile(self.builder.allocator);
        defer file_contents.deinit();

        try cwd.writeFile(self.output_file.path.?, file_contents.items);
    }
};

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("mkway", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.addPackagePath("xml", "../xml/src/xml.zig");

    var gen = GenerateWaylandFile.init(b);
    exe.addPackage(gen.package);

    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest("src/main.zig");
    exe_tests.setTarget(target);
    exe_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
