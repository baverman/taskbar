const std = @import("std");
const cairo_mod = @import("cairo.zig");
const cfg = @import("config.zig");
const layout = @import("layout.zig");
const x11 = @import("x11.zig");
const common = @import("widgets/common.zig");
const widget_mod = @import("widgets/widget.zig");
const c = x11.c;
const x = x11.x;
const z = x11.z;
const PT = z.PropertyType;

const WidgetItem = struct {
    widget: widget_mod.Widget,
    config: cfg.Widget,
    rect: common.Rect,
    dirty: bool = true,
    needs_update: bool = true,
    next_update_at_ms: ?i64 = null,
};

pub const App = struct {
    ctx: common.Context,
    widgets: std.ArrayList(WidgetItem),
    layout_dirty: bool,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, conn: *z.Connection, config: *const cfg.Config) !App {
        const root = conn.root_window;
        const root_geometry = try conn.request(x.GetGeometry, .{ .drawable = .{ .window = root } });
        const root_attrs = try conn.request(x.GetWindowAttributes, .{ .window = root });

        var app = App{
            .ctx = undefined,
            .widgets = .empty,
            .layout_dirty = true,
        };

        app.ctx = .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .current_time_ms = currentTimeMs(io),
            .gfx = .{
                .conn = conn,
                .root = root,
                .window = x.Window.None,
                .root_width = root_geometry.width,
                .root_depth = root_geometry.depth,
                .root_visual = root_attrs.visual,
                .cairo_surface = undefined,
                .cairo = undefined,
                .pango_layout = undefined,
                .atoms = try z.AtomEnum(x11.Atoms).init(conn),
            },
        };

        try app.createWindow();
        try app.createGraphics();
        try app.initLayout();

        try app.setDockProperties();
        try app.subscribeRootChanges();
        try app.mapWindow();

        return app;
    }

    pub fn deinit(app: *App) void {
        for (app.widgets.items) |*item| item.widget.deinit(&app.ctx);
        app.widgets.deinit(app.ctx.allocator);
        c.g_object_unref(app.ctx.gfx.pango_layout);
        c.cairo_destroy(app.ctx.gfx.cairo);
        app.ctx.gfx.cairo_surface.deinit(app.ctx.gfx.conn);
        if (app.ctx.gfx.window != x.Window.None) {
            _ = app.ctx.gfx.conn.request(x.DestroyWindow, .{ .window = app.ctx.gfx.window }) catch {};
        }
    }

    pub fn run(app: *App) !void {
        while (true) {
            app.ctx.current_time_ms = currentTimeMs(app.ctx.io);
            try app.processPendingEvents();
            app.collectScheduledUpdates();
            try app.processUpdates();
            app.redraw();

            if (!app.ctx.gfx.conn.hasPendingEvents()) {
                _ = try app.ctx.gfx.conn.waitForEvents(app.nextPollTimeoutMs());
            }
        }
    }

    fn createWindow(app: *App) !void {
        const window = try app.ctx.gfx.conn.allocId(x.Window);
        try app.ctx.gfx.conn.request(x.CreateWindow, .{
            .depth = app.ctx.gfx.root_depth,
            .wid = window,
            .parent = app.ctx.gfx.root,
            .x = 0,
            .y = 0,
            .width = app.ctx.gfx.root_width,
            .height = @intCast(app.ctx.config.height),
            .border_width = 0,
            .class = .CopyFromParent,
            .visual = 0,
            .value_list = .{
                .background_pixel = app.ctx.config.style.bg,
                .border_pixel = app.ctx.config.style.bg,
                .event_mask = x.EventMask.of(&.{ .Exposure, .ButtonPress, .StructureNotify, .SubstructureNotify }),
            },
        });
        app.ctx.gfx.window = window;
    }

    fn createGraphics(app: *App) !void {
        app.ctx.gfx.cairo_surface = try cairo_mod.Surface.init(
            app.ctx.gfx.conn,
            app.ctx.gfx.window,
            app.ctx.gfx.root_depth,
            app.ctx.gfx.root_width,
            @intCast(app.ctx.config.height),
        );
        app.ctx.gfx.cairo = c.cairo_create(app.ctx.gfx.cairo_surface.surface()) orelse return error.CairoCreateFailed;
        app.ctx.gfx.pango_layout = c.pango_cairo_create_layout(app.ctx.gfx.cairo) orelse return error.PangoLayoutCreateFailed;
    }

    fn initLayout(app: *App) !void {
        for (app.ctx.config.widgets) |widget_cfg| {
            try app.widgets.append(app.ctx.allocator, .{
                .widget = try widget_mod.Widget.initFromConfig(&app.ctx, app.ctx.config.style, widget_cfg),
                .config = widget_cfg,
                .rect = .{ .x = 0, .y = 0, .width = 0, .height = app.ctx.config.height },
                .dirty = true,
                .needs_update = true,
                .next_update_at_ms = null,
            });
        }
    }

    fn mapWindow(app: *App) !void {
        try app.ctx.gfx.conn.request(x.MapWindow, .{ .window = app.ctx.gfx.window });
        app.ctx.gfx.cairo_surface.present(app.ctx.gfx.conn);
    }

    fn subscribeRootChanges(app: *App) !void {
        try app.ctx.gfx.conn.request(x.ChangeWindowAttributes, .{
            .window = app.ctx.gfx.root,
            .value_list = .{
                .event_mask = x.EventMask.of(&.{.PropertyChange}),
            },
        });
    }

    fn setDockProperties(app: *App) !void {
        const atoms = &app.ctx.gfx.atoms;
        const w = app.ctx.gfx.window;
        const cn = app.ctx.gfx.conn;

        const screen_width: u32 = app.ctx.gfx.root_width;
        const height: u32 = @intCast(app.ctx.config.height);
        const size_hints = z.ewmh.SizeHints.encode(&.{
            .{ .PPosition = .{ 0, 0 } },
            .{ .PMinSize = .{ screen_width, height } },
            .{ .PMaxSize = .{ screen_width, height } },
        });
        try z.setProperty(cn, w, atoms.WM_NORMAL_HINTS, PT.cardinal.as(atoms.WM_SIZE_HINTS), &size_hints);

        try z.setProperty(cn, w, atoms._NET_WM_WINDOW_TYPE, PT.atom, &.{atoms._NET_WM_WINDOW_TYPE_DOCK});
        try z.setProperty(cn, w, atoms._NET_WM_DESKTOP, PT.cardinal, &.{0xFFFFFFFF});

        const strut = [_]u32{ 0, 0, height, 0 };
        try z.setProperty(cn, w, atoms._NET_WM_STRUT, PT.cardinal, &strut);

        const strut_partial = [_]u32{
            0, 0,                height, 0,
            0, 0,                0,      0,
            0, screen_width - 1, 0,      0,
        };
        try z.setProperty(cn, w, atoms._NET_WM_STRUT_PARTIAL, PT.cardinal, &strut_partial);

        const title = "taskbar";
        try z.setProperty(cn, w, atoms._NET_WM_NAME, PT.string.as(atoms.UTF8_STRING), title);

        const wm_class = "taskbar\x00taskbar\x00";
        try z.setProperty(cn, w, atoms.WM_CLASS, PT.string, wm_class);
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

        for (app.widgets.items) |*item| {
            if (!item.dirty or item.rect.width <= 0) continue;
            app.ctx.fillRect(app.ctx.config.style.bg, item.rect);
            switch (item.widget) {
                inline else => |*w| w.draw(&app.ctx, item.rect),
            }
            item.dirty = false;
        }
        app.ctx.gfx.cairo_surface.present(app.ctx.gfx.conn);
    }

    fn processPendingEvents(app: *App) !void {
        while (try app.ctx.gfx.conn.pollEvent()) |event| {
            switch (event) {
                .Expose => {
                    for (app.widgets.items) |*item| item.dirty = true;
                },
                else => try app.handleEvent(&event),
            }
        }
    }

    fn handleEvent(app: *App, event: *const x.Event) !void {
        for (app.widgets.items) |*item| {
            if (event.* == .ButtonPress and
                (event.ButtonPress.event_x < item.rect.x or event.ButtonPress.event_x > item.rect.x + item.rect.width))
            {
                continue;
            }
            const status = switch (item.widget) {
                inline else => |*w| try w.handleEvent(&app.ctx, item.rect, event),
            };
            app.applyEventStatus(item, status);
            if (event.* == .ButtonPress) return;
        }
    }

    fn relayout(app: *App) void {
        layout.relayout(&app.ctx, app.ctx.panelWidth(), app.widgets.items);
        for (app.widgets.items) |*item| item.dirty = true;
        app.layout_dirty = false;
    }

    fn collectScheduledUpdates(app: *App) void {
        for (app.widgets.items) |*item| {
            const next_update_at_ms = item.next_update_at_ms orelse continue;
            if (next_update_at_ms > app.ctx.current_time_ms) continue;
            item.needs_update = true;
            item.next_update_at_ms = null;
        }
    }

    fn processUpdates(app: *App) !void {
        for (app.widgets.items) |*item| {
            if (!item.needs_update) continue;
            item.needs_update = false;
            const status = switch (item.widget) {
                inline else => |*w| try w.update(&app.ctx),
            };
            app.applyUpdateStatus(item, status);
        }
    }

    fn applyEventStatus(app: *App, item: *WidgetItem, status: common.Status) void {
        if (status.redraw) item.dirty = true;
        if (status.relayout) app.layout_dirty = true;
        if (status.update) item.needs_update = true;
    }

    fn applyUpdateStatus(app: *App, item: *WidgetItem, status: common.Status) void {
        app.applyEventStatus(item, status);
        if (status.next_update_in_ms) |next_update_in_ms| {
            const next_update = app.ctx.current_time_ms + next_update_in_ms;
            item.next_update_at_ms = @min(next_update, item.next_update_at_ms orelse next_update);
        }
    }

    fn nextPollTimeoutMs(app: *const App) c_int {
        var min_timeout_ms: ?i64 = null;
        for (app.widgets.items) |*item| {
            const next_update_at_ms = item.next_update_at_ms orelse continue;
            const timeout_ms = @max(0, next_update_at_ms - app.ctx.current_time_ms);
            min_timeout_ms = if (min_timeout_ms) |current| @min(current, timeout_ms) else timeout_ms;
        }
        return if (min_timeout_ms) |timeout_ms|
            @intCast(@min(timeout_ms, std.math.maxInt(c_int)))
        else
            -1;
    }
};

fn currentTimeMs(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toMilliseconds();
}
