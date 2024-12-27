const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zwlr = wayland.client.zwlr;

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

    const shm = context.shm orelse return error.NoWlShm;
    const compositor = context.compositor orelse return error.NoWlCompositor;
    // const wm_base = context.wm_base orelse return error.NoXdgWmBase;

    const buffer = blk: {
        const width: i32 = @intCast(context.width);
        const height: i32 = @intCast(context.height);
        const stride = width * 4;
        const size: u64 = @intCast(stride * height);

        const fd = try std.posix.memfd_create("hello-zig-wayland", 0);
        try std.posix.ftruncate(fd, size);
        const data = try std.posix.mmap(
            null,
            size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        context.data = data;

        const pool = try shm.createPool(fd, @intCast(size));
        defer pool.destroy();

        break :blk try pool.createBuffer(0, width, height, stride, wl.Shm.Format.argb8888);
    };
    defer buffer.destroy();

    const surface = try compositor.createSurface();
    defer surface.destroy();
    context.surface = surface;
    context.buffer = buffer;

    const callback = try surface.frame();
    defer callback.destroy();
    callback.setListener(*Context, frame_listener, &context);

    const layer_surface = try zwlr.LayerShellV1.getLayerSurface(context.layer_shell.?, surface, null, .overlay, "");
    layer_surface.setSize(context.width, context.height);
    layer_surface.setAnchor(.{ .bottom = true, .left = true, .right = true, .top = true });
    layer_surface.setKeyboardInteractivity(.exclusive);

    layer_surface.setListener(*Context, layer_surface_listener, &context);

    surface.commit();
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    surface.attach(buffer, 0, 0);
    surface.commit();

    while (context.is_running) {
        if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
    }
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
