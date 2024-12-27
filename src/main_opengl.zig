const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zwlr = wayland.client.zwlr;
const gl = @import("gl");

const egl = @cImport({
    @cDefine("WL_EGL_PLATFORM", "1");
    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
    @cUndef("WL_EGL_PLATFORM");
});

const Context = struct {
    shm: ?*wl.Shm,
    seat: ?*wl.Seat,
    compositor: ?*wl.Compositor,
    wm_base: ?*xdg.WmBase,
    layer_shell: ?*zwlr.LayerShellV1,
    keyboard: ?*wl.Keyboard,
    is_running: bool = true,

    // rendering stuff
    offset: f32 = 0,
    last_frame: u32 = 0,
    surface: ?*wl.Surface = null,
    buffer: ?*wl.Buffer = null,
    data: []u8 = undefined,
    width: u32 = 400,
    height: u32 = 400,
};

var table: gl.ProcTable = undefined;

fn getProcAddress(name: [*:0]const u8) ?gl.PROC {
    return egl.eglGetProcAddress(name);
}

pub fn main() !void {
    const display = try wl.Display.connect(null);
    var context = Context{
        .shm = null,
        .compositor = null,
        .wm_base = null,
        .layer_shell = null,
        .keyboard = null,
        .seat = null,
    };

    const registry = try display.getRegistry();

    registry.setListener(*Context, registryListener, &context);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    // const shm = context.shm orelse return error.NoWlShm;
    const compositor = context.compositor orelse return error.NoWlCompositor;
    // const wm_base = context.wm_base orelse return error.NoXdgWmBase;

    const surface = try compositor.createSurface();
    defer surface.destroy();
    context.surface = surface;

    const layer_surface = try zwlr.LayerShellV1.getLayerSurface(context.layer_shell.?, surface, null, .overlay, "");
    layer_surface.setSize(context.width, context.height);
    layer_surface.setAnchor(.{ .bottom = true, .left = true, .right = true, .top = true });
    layer_surface.setKeyboardInteractivity(.exclusive);

    layer_surface.setListener(*Context, layer_surface_listener, &context);
    // const callback = try surface.frame();
    // defer callback.destroy();
    // callback.setListener(*Context, frame_listener, &context);

    surface.commit();
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    // surface.attach(buffer, 0, 0);
    surface.commit();

    // {
    const egl_display = egl.eglGetPlatformDisplay(egl.EGL_PLATFORM_WAYLAND_KHR, display, null);

    var egl_major: egl.EGLint = 0;
    var egl_minor: egl.EGLint = 0;
    if (egl.eglInitialize(egl_display, &egl_major, &egl_minor) == egl.EGL_TRUE) {
        std.log.info("EGL version: {}.{}", .{ egl_major, egl_minor });
    } else switch (egl.eglGetError()) {
        egl.EGL_BAD_DISPLAY => return error.EglBadDisplay,
        else => return error.EglFailedToinitialize,
    }
    defer _ = egl.eglTerminate(egl_display);

    const egl_attributes: [12:egl.EGL_NONE]egl.EGLint = .{
        egl.EGL_SURFACE_TYPE,    egl.EGL_WINDOW_BIT,
        egl.EGL_RENDERABLE_TYPE, egl.EGL_OPENGL_BIT,
        egl.EGL_RED_SIZE,        8,
        egl.EGL_GREEN_SIZE,      8,
        egl.EGL_BLUE_SIZE,       8,
        egl.EGL_ALPHA_SIZE,      8,
    };

    const egl_config = config: {
        // Rather ask for a list of possible configs, we just get the first one and
        // hope it is a good choice.
        var config: egl.EGLConfig = null;
        var num_configs: egl.EGLint = 0;
        const result = egl.eglChooseConfig(
            egl_display,
            &egl_attributes,
            &config,
            1,
            &num_configs,
        );

        if (result != egl.EGL_TRUE) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_ATTRIBUTE => return error.InvalidEglConfigAttribute,
                else => return error.EglConfigError,
            }
        }
        break :config config.?;
    };

    if (egl.eglBindAPI(egl.EGL_OPENGL_API) != egl.EGL_TRUE) {
        switch (egl.eglGetError()) {
            egl.EGL_BAD_PARAMETER => return error.OpenGlUnsupported,
            else => return error.InvalidApi,
        }
    }

    const context_attributes: [4:egl.EGL_NONE]egl.EGLint = .{
        egl.EGL_CONTEXT_MAJOR_VERSION, 4,
        egl.EGL_CONTEXT_MINOR_VERSION, 5,
    };
    const egl_context = egl.eglCreateContext(
        egl_display,
        egl_config,
        egl.EGL_NO_CONTEXT,
        &context_attributes,
    ) orelse switch (egl.eglGetError()) {
        egl.EGL_BAD_ATTRIBUTE => return error.InvalidContextAttribute,
        egl.EGL_BAD_CONFIG => return error.CreateContextWithBadConfig,
        egl.EGL_BAD_MATCH => return error.UnsupportedConfig,
        else => return error.FailedToCreateContext,
    };
    defer _ = egl.eglDestroyContext(egl_display, egl_context);

    if (!gl.ProcTable.init(&table, getProcAddress)) {
        @panic("fail initialization of opengl");
    }
    gl.makeProcTableCurrent(&table);

    const egl_window = try wl.EglWindow.create(surface, @intCast(context.width), @intCast(context.height));
    const egl_surface = egl.eglCreatePlatformWindowSurface(
        egl_display,
        egl_config,
        @ptrCast(egl_window),
        null,
    ) orelse switch (egl.eglGetError()) {
        egl.EGL_BAD_MATCH => return error.MismatchedConfig,
        egl.EGL_BAD_CONFIG => return error.InvalidConfig,
        egl.EGL_BAD_NATIVE_WINDOW => return error.InvalidWindow,
        else => return error.FailedToCreateEglSurface,
    };

    const result = egl.eglMakeCurrent(
        egl_display,
        egl_surface,
        egl_surface,
        egl_context,
    );

    if (result == egl.EGL_FALSE) {
        switch (egl.eglGetError()) {
            egl.EGL_BAD_ACCESS => return error.EglThreadError,
            egl.EGL_BAD_MATCH => return error.MismatchedContextOrSurfaces,
            egl.EGL_BAD_NATIVE_WINDOW => return error.EglWindowInvalid,
            egl.EGL_BAD_CONTEXT => return error.InvalidEglContext,
            egl.EGL_BAD_ALLOC => return error.OutOfMemory,
            else => return error.FailedToMakeCurrent,
        }
    }

    var count: usize = 0;
    var timer = try std.time.Timer.start();
    while (context.is_running) {
        count += 1;
        gl.ClearColor(1.0, 1.0, 0.5, 1.0);
        gl.Clear(gl.COLOR_BUFFER_BIT);
        gl.Flush();
        if (egl.eglSwapBuffers(egl_display, egl_surface) != egl.EGL_TRUE) {
            switch (egl.eglGetError()) {
                egl.EGL_BAD_DISPLAY => return error.InvalidDisplay,
                egl.EGL_BAD_SURFACE => return error.PresentInvalidSurface,
                egl.EGL_CONTEXT_LOST => return error.EGLContextLost,
                else => return error.FailedToSwapBuffers,
            }
        }

        if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
    }
    std.debug.print("\nTIME WAS {d}\n", .{timer.read() / (count * 1000000)});
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, context: *Context) void {
    switch (event) {
        .global => |global| {
            if (std.mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                context.compositor = registry.bind(global.name, wl.Compositor, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wl.Shm.interface.name) == .eq) {
                context.shm = registry.bind(global.name, wl.Shm, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                context.wm_base = registry.bind(global.name, xdg.WmBase, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, zwlr.LayerShellV1.interface.name) == .eq) {
                context.layer_shell = registry.bind(global.name, zwlr.LayerShellV1, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                context.seat = registry.bind(global.name, wl.Seat, 1) catch return;
                context.seat.?.setListener(*Context, seat_listener, context);
            }
        },
        .global_remove => {},
    }
}

fn seat_listener(seat: *wl.Seat, event: wl.Seat.Event, context: *Context) void {
    switch (event) {
        .capabilities => |data| {
            std.debug.print("Seat capabilities\n  Pointer {}\n  Keyboard {}\n  Touch {}\n", .{
                data.capabilities.pointer,
                data.capabilities.keyboard,
                data.capabilities.touch,
            });
            if (data.capabilities.keyboard) {
                if (context.keyboard == null) {
                    context.keyboard = seat.getKeyboard() catch unreachable;
                    context.keyboard.?.setListener(*Context, keyboard_listener, context);
                }
            }
        },
        .name => |name| {
            std.debug.print("seat name: {s}\n", .{name.name});
        },
    }
}

fn keyboard_listener(_: *wl.Keyboard, event: wl.Keyboard.Event, context: *Context) void {
    switch (event) {
        .key => |e| {
            if (e.key == 1) context.is_running = false;
            std.debug.print("{d}-{}", .{ e.key, e.state });
        },
        else => {},
    }
}

fn layer_surface_listener(layer_surface: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, context: *Context) void {
    switch (event) {
        .configure => |configure| {
            layer_surface.ackConfigure(configure.serial);
            std.log.info("w: {} h: {}", .{ configure.width, configure.height });
        },
        .closed => {
            context.is_running = false;
        },
    }
}

pub fn frame_listener(_: *wl.Callback, event: wl.Callback.Event, context: *Context) void {
    switch (event) {
        .done => |done| {
            // the callback_data is the time in milliseconds
            const time = done.callback_data;
            defer context.last_frame = time;

            const frame_cb = context.surface.?.frame() catch unreachable;
            frame_cb.setListener(*Context, frame_listener, context);

            if (context.last_frame != 0) {
                const elapsed: f32 = @floatFromInt(time - context.last_frame);
                context.offset += elapsed / 1000.0 * 24;
            }

            draw(context, context.data);

            context.surface.?.attach(context.buffer, 0, 0);
            context.surface.?.damage(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
            context.surface.?.commit();
        },
    }
}

const palette = [_]u32{ 0xff1a1c2c, 0xff5d275d, 0xffb13e53, 0xffef7d57, 0xffffcd75, 0xffa7f070, 0xff38b764, 0xff257179, 0xff29366f, 0xff3b5dc9, 0xff41a6f6, 0xff73eff7, 0xfff4f4f4, 0xff94b0c2, 0xff566c86, 0xff333c57 };
fn draw(context: *const Context, buf: []u8) void {
    const data_u32: []u32 = std.mem.bytesAsSlice(u32, @as([]align(32) u8, @alignCast(buf)));

    const sin = std.math.sin;
    for (0..context.height) |y| {
        for (0..context.width) |x| {
            const x_f: f32, const y_f: f32 = .{ @floatFromInt(x), @floatFromInt(y) };
            const c = sin(x_f / 80) + sin(y_f / 80) + sin(context.offset / 80);
            const index: i64 = @intFromFloat(c * 4);
            data_u32[y * context.width + x] = palette[@abs(index) % 16];
        }
    }
}
