const std = @import("std");

const Scanner = @import("zig-wayland").Scanner;
const ziggen = @import("zigglgen");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gl_bindings = ziggen.generateBindingsModule(b, .{
        .api = .gl,
        .version = .@"4.5",
        .profile = .core,
        .extensions = &.{ .ARB_clip_control, .NV_scissor_exclusive },
    });

    const scanner = Scanner.create(b, .{});

    const wayland = b.createModule(.{ .root_source_file = scanner.result });

    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("stable/linux-dmabuf/linux-dmabuf-v1.xml");
    scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");
    scanner.addCustomProtocol(b.path("custom-protocols/wlr-layer-shell-unstable-v1.xml"));

    // Pass the maximum version implemented by your wayland server or client.
    // Requests, events, enums, etc. from newer versions will not be generated,
    // ensuring forwards compatibility with newer protocol xml.
    // This will also generate code for interfaces created using the provided
    // global interface, in this example wl_keyboard, wl_pointer, xdg_surface,
    // xdg_toplevel, etc. would be generated as well.
    scanner.generate("wl_seat", 2);
    scanner.generate("wl_compositor", 2);
    scanner.generate("xdg_wm_base", 2);
    scanner.generate("wl_shm", 2);
    scanner.generate("wl_output", 2);
    scanner.generate("zwlr_layer_shell_v1", 4);

    const exe = b.addExecutable(.{
        .name = "waive2",
        .root_source_file = b.path("src/main_opengl.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.linkSystemLibrary("wayland-egl");
    exe.linkSystemLibrary("EGL");

    exe.root_module.addImport("gl", gl_bindings);
    exe.root_module.addImport("wayland", wayland);
    exe.linkLibC();
    exe.linkSystemLibrary("wayland-client");

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
