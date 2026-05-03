const std = @import("std");
const cfg = @import("config.zig");
const layout = @import("layout.zig");
const x11 = @import("x11.zig");
const common = @import("widgets/common.zig");
const widget_mod = @import("widgets/widget.zig");
const c = x11.c;

pub const App = struct {
    ctx: common.Context,
    layout: std.ArrayList(layout.LayoutItem),
    layout_dirty: bool,

    pub fn init(allocator: std.mem.Allocator, config: *const cfg.Config) !App {
        const display = c.XOpenDisplay(null) orelse return error.XOpenDisplayFailed;
        errdefer _ = c.XCloseDisplay(display);

        const screen_num = c.XDefaultScreen(display);
        const root = c.XRootWindow(display, screen_num);
        const atoms = x11.internAtoms(display);

        var app = App{
            .ctx = undefined,
            .layout = .{},
            .layout_dirty = true,
        };
        app.ctx = .{
            .allocator = allocator,
            .config = config,
            .gfx = .{
                .display = display,
                .screen_num = screen_num,
                .root = root,
                .window = 0,
                .visual = null,
                .cairo_surface = undefined,
                .cairo = undefined,
                .atoms = atoms,
            },
        };

        try app.createWindow();
        try app.createGraphics();
        try app.initLayout();
        try app.refreshLayoutWidgets();
        app.setDockProperties();
        app.subscribeRootChanges();
        try app.startWidgets();
        app.mapWindow();
        app.redraw();
        return app;
    }

    pub fn deinit(app: *App) void {
        for (app.layout.items) |*item| item.widget.deinit(&app.ctx);
        app.layout.deinit(app.ctx.allocator);
        c.cairo_destroy(app.ctx.gfx.cairo);
        c.cairo_surface_destroy(app.ctx.gfx.cairo_surface);
        if (app.ctx.gfx.window != 0) _ = c.XDestroyWindow(app.ctx.gfx.display, app.ctx.gfx.window);
        _ = c.XCloseDisplay(app.ctx.gfx.display);
    }

    pub fn run(app: *App) !void {
        const xfd = c.ConnectionNumber(app.ctx.gfx.display);
        var pollfd = [1]std.posix.pollfd{.{
            .fd = xfd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};

        while (true) {
            try app.processPendingEvents();
            for (app.layout.items) |*item| {
                const update = switch (item.widget) {
                    inline else => |*w| w.tick(&app.ctx),
                };
                if (update.redraw) item.dirty = true;
                if (update.relayout) app.layout_dirty = true;
            }

            app.redraw();

            const timeout_ms = nextClockTimeoutMs();
            _ = try std.posix.poll(&pollfd, timeout_ms);
        }
    }

    fn createWindow(app: *App) !void {
        const width: c_uint = @intCast(c.XDisplayWidth(app.ctx.gfx.display, app.ctx.gfx.screen_num));
        app.ctx.gfx.window = c.XCreateSimpleWindow(
            app.ctx.gfx.display,
            app.ctx.gfx.root,
            0,
            0,
            width,
            @intCast(app.ctx.config.height),
            0,
            app.ctx.config.style.bg,
            app.ctx.config.style.bg,
        );
        _ = c.XSelectInput(app.ctx.gfx.display, app.ctx.gfx.window, c.ExposureMask | c.ButtonPressMask | c.StructureNotifyMask | c.SubstructureNotifyMask);
    }

    fn createGraphics(app: *App) !void {
        app.ctx.gfx.visual = c.XDefaultVisual(app.ctx.gfx.display, app.ctx.gfx.screen_num);
        app.ctx.gfx.cairo_surface = c.cairo_xlib_surface_create(
            app.ctx.gfx.display,
            app.ctx.gfx.window,
            app.ctx.gfx.visual,
            c.XDisplayWidth(app.ctx.gfx.display, app.ctx.gfx.screen_num),
            app.ctx.config.height,
        ) orelse return error.CairoSurfaceCreateFailed;
        app.ctx.gfx.cairo = c.cairo_create(app.ctx.gfx.cairo_surface) orelse return error.CairoCreateFailed;
    }

    fn initLayout(app: *App) !void {
        for (app.ctx.config.widgets) |widget_cfg| {
            try app.layout.append(app.ctx.allocator, .{
                .widget = try widget_mod.Widget.initFromConfig(&app.ctx, app.ctx.config.style, widget_cfg),
                .config = widget_cfg,
                .rect = .{ .x = 0, .y = 0, .width = 0, .height = app.ctx.config.height },
                .dirty = true,
            });
        }
    }

    fn refreshLayoutWidgets(app: *App) !void {
        for (app.layout.items) |*item| switch (item.widget) {
            inline else => |*w| try w.refresh(&app.ctx),
        };
    }

    fn startWidgets(app: *App) !void {
        for (app.layout.items) |*item| switch (item.widget) {
            inline else => |*w| try w.start(&app.ctx),
        };
    }

    fn mapWindow(app: *App) void {
        _ = c.XMapWindow(app.ctx.gfx.display, app.ctx.gfx.window);
        _ = c.XFlush(app.ctx.gfx.display);
    }

    fn subscribeRootChanges(app: *App) void {
        _ = c.XSelectInput(app.ctx.gfx.display, app.ctx.gfx.root, c.PropertyChangeMask);
        _ = c.XFlush(app.ctx.gfx.display);
    }

    fn setDockProperties(app: *App) void {
        const screen_width: c_ulong = @intCast(c.XDisplayWidth(app.ctx.gfx.display, app.ctx.gfx.screen_num));
        var size_hints = std.mem.zeroes(c.XSizeHints);
        size_hints.flags = c.PPosition | c.PMinSize | c.PMaxSize;
        size_hints.x = 0;
        size_hints.y = 0;
        size_hints.min_width = @intCast(screen_width);
        size_hints.min_height = @intCast(app.ctx.config.height);
        size_hints.max_width = @intCast(screen_width);
        size_hints.max_height = @intCast(app.ctx.config.height);
        _ = c.XSetWMNormalHints(app.ctx.gfx.display, app.ctx.gfx.window, &size_hints);

        const win_type = [_]c.Atom{app.ctx.gfx.atoms.net_wm_window_type_dock};
        _ = c.XChangeProperty(app.ctx.gfx.display, app.ctx.gfx.window, app.ctx.gfx.atoms.net_wm_window_type, c.XA_ATOM, 32, c.PropModeReplace, @ptrCast(&win_type), win_type.len);

        const desktop = [_]c_ulong{0xFFFFFFFF};
        _ = c.XChangeProperty(app.ctx.gfx.display, app.ctx.gfx.window, app.ctx.gfx.atoms.net_wm_desktop, c.XA_CARDINAL, 32, c.PropModeReplace, @ptrCast(&desktop), desktop.len);

        const strut = [_]c_ulong{ 0, 0, @intCast(app.ctx.config.height), 0 };
        _ = c.XChangeProperty(app.ctx.gfx.display, app.ctx.gfx.window, app.ctx.gfx.atoms.net_wm_strut, c.XA_CARDINAL, 32, c.PropModeReplace, @ptrCast(&strut), strut.len);

        const strut_partial = [_]c_ulong{
            0, 0,                @intCast(app.ctx.config.height), 0,
            0, 0,                0,                               0,
            0, screen_width - 1, 0,                               0,
        };
        _ = c.XChangeProperty(app.ctx.gfx.display, app.ctx.gfx.window, app.ctx.gfx.atoms.net_wm_strut_partial, c.XA_CARDINAL, 32, c.PropModeReplace, @ptrCast(&strut_partial), strut_partial.len);

        const title = "taskbar";
        _ = c.XChangeProperty(app.ctx.gfx.display, app.ctx.gfx.window, app.ctx.gfx.atoms.net_wm_name, app.ctx.gfx.atoms.utf8_string, 8, c.PropModeReplace, title.ptr, title.len);

        const wm_class = "taskbar\x00taskbar\x00";
        _ = c.XChangeProperty(app.ctx.gfx.display, app.ctx.gfx.window, app.ctx.gfx.atoms.wm_class, c.XA_STRING, 8, c.PropModeReplace, wm_class.ptr, wm_class.len);
        _ = c.XFlush(app.ctx.gfx.display);
    }

    fn redraw(app: *App) void {
        const needs_full_repaint = app.layout_dirty;
        if (needs_full_repaint) {
            app.relayout();
            app.ctx.fillRect(app.ctx.config.style.bg, .{
                .x = 0,
                .y = 0,
                .width = app.ctx.panelWidth(),
                .height = app.ctx.config.height,
            });
        }

        for (app.layout.items) |*item| {
            if (!item.dirty or item.rect.width <= 0) continue;
            app.ctx.fillRect(app.ctx.config.style.bg, item.rect);
            switch (item.widget) {
                inline else => |*w| w.draw(&app.ctx, item.rect),
            }
            item.dirty = false;
        }
        _ = c.XFlush(app.ctx.gfx.display);
    }

    fn processPendingEvents(app: *App) !void {
        while (c.XPending(app.ctx.gfx.display) > 0) {
            var event: c.XEvent = undefined;
            _ = c.XNextEvent(app.ctx.gfx.display, &event);
            switch (event.type) {
                c.Expose => {
                    for (app.layout.items) |*item| item.dirty = true;
                },
                c.ButtonPress => try app.handleClick(@intCast(event.xbutton.x), @intCast(event.xbutton.y)),
                else => try app.handleEvent(&event),
            }
        }
    }

    fn handleClick(app: *App, x: i32, y: i32) !void {
        if (y < 0 or y > app.ctx.config.height) return;
        for (app.layout.items) |*item| {
            if (x < item.rect.x or x > item.rect.x + item.rect.width) continue;
            const update = switch (item.widget) {
                inline else => |*w| w.click(&app.ctx, item.rect, x, y),
            };
            if (update.redraw) item.dirty = true;
            if (update.relayout) app.layout_dirty = true;
            return;
        }
    }

    fn handleEvent(app: *App, event: *const c.XEvent) !void {
        for (app.layout.items) |*item| {
            const update = switch (item.widget) {
                inline else => |*w| try w.handleEvent(&app.ctx, item.rect, event),
            };
            if (update.redraw) item.dirty = true;
            if (update.relayout) app.layout_dirty = true;
        }
    }

    fn relayout(app: *App) void {
        layout.relayout(&app.ctx, app.ctx.panelWidth(), app.layout.items);
        app.layout_dirty = false;
    }
};

fn nextClockTimeoutMs() c_int {
    const now: i64 = @intCast(c.time(null));
    const next_minute = ((@divFloor(now, 60) + 1) * 60);
    return @intCast(@max(0, next_minute - now) * 1000);
}
