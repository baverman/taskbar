const std = @import("std");
const cfg = @import("config.zig");
const tray_mod = @import("tray.zig");
const x11 = @import("x11.zig");
const c = x11.c;

const panel_config = cfg.config;
const widget_count = panel_config.widgets.len;
const tray_inset_y = 4;
const fallback_font_name = "DejaVu Sans";

const Desktop = struct {
    index: u32,
    name: []u8,
};

const WindowEntry = struct {
    window: c.Window,
    desktop: u32,
    title: []u8,
};

const ResolvedStyle = struct {
    font: cfg.Font,
    bg: u32,
    text: u32,
    active_bg: u32,
    active_text: u32,
    padding: i32,
    text_offset: i32,
};

const WidgetKind = enum {
    pager,
    taskbar,
    tray,
    clock,
};

const WidgetLayout = struct {
    index: usize,
    kind: WidgetKind,
    x: i32,
    width: i32,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    display: *c.Display,
    screen_num: c_int,
    root: c.Window,
    window: c.Window,
    gc: c.GC,
    visual: ?*c.Visual,
    colormap: c.Colormap,
    xft_draw: *c.XftDraw,
    atoms: x11.Atoms,
    tray: tray_mod.Tray,
    widget_fonts: [widget_count]*c.XftFont,
    fallback_fonts: [widget_count]*c.XftFont,
    desktops: std.ArrayList(Desktop),
    windows: std.ArrayList(WindowEntry),
    current_desktop: u32,
    active_window: c.Window,
    clock_text: [32]u8,
    clock_len: usize,
    last_clock_minute: i64,

    pub fn init(allocator: std.mem.Allocator) !App {
        const display = c.XOpenDisplay(null) orelse return error.XOpenDisplayFailed;
        errdefer _ = c.XCloseDisplay(display);

        const screen_num = c.XDefaultScreen(display);
        const root = c.XRootWindow(display, screen_num);
        const atoms = x11.internAtoms(display);

        var app = App{
            .allocator = allocator,
            .display = display,
            .screen_num = screen_num,
            .root = root,
            .window = 0,
            .gc = undefined,
            .visual = null,
            .colormap = 0,
            .xft_draw = undefined,
            .atoms = atoms,
            .tray = undefined,
            .widget_fonts = undefined,
            .fallback_fonts = undefined,
            .desktops = .{},
            .windows = .{},
            .current_desktop = 0,
            .active_window = 0,
            .clock_text = [_]u8{0} ** 32,
            .clock_len = 0,
            .last_clock_minute = -1,
        };

        try app.createWindow();
        app.tray = tray_mod.Tray.init(allocator, app.window, atoms);
        try app.createGraphics();
        try app.loadWidgetFonts();
        try app.refreshDesktopState();
        try app.refreshWindowState();
        _ = app.updateClock();
        app.setDockProperties();
        app.subscribeRootChanges();
        try app.tray.claimSelection(app.display, app.root);
        app.mapWindow();
        app.redraw();
        return app;
    }

    pub fn deinit(app: *App) void {
        app.tray.deinit();
        for (&app.widget_fonts) |font| c.XftFontClose(app.display, font);
        for (&app.fallback_fonts) |font| c.XftFontClose(app.display, font);
        for (app.desktops.items) |desktop| app.allocator.free(desktop.name);
        app.desktops.deinit(app.allocator);
        for (app.windows.items) |window| app.allocator.free(window.title);
        app.windows.deinit(app.allocator);
        c.XftDrawDestroy(app.xft_draw);
        _ = c.XFreeGC(app.display, app.gc);
        if (app.window != 0) _ = c.XDestroyWindow(app.display, app.window);
        _ = c.XCloseDisplay(app.display);
    }

    pub fn run(app: *App) !void {
        const xfd = c.ConnectionNumber(app.display);
        while (true) {
            var needs_redraw = try app.processPendingEvents();
            if (app.updateClock()) needs_redraw = true;
            if (needs_redraw) app.redraw();

            var pollfd = c.struct_pollfd{
                .fd = xfd,
                .events = c.POLLIN,
                .revents = 0,
            };
            const timeout_ms = nextClockTimeoutMs();
            while (true) {
                const rc = c.poll(&pollfd, 1, timeout_ms);
                if (rc >= 0) break;
                if (std.posix.errno(rc) == .INTR) continue;
                return error.PollFailed;
            }
        }
    }

    fn createWindow(app: *App) !void {
        const width: c_uint = @intCast(c.XDisplayWidth(app.display, app.screen_num));
        app.window = c.XCreateSimpleWindow(
            app.display,
            app.root,
            0,
            0,
            width,
            @intCast(panel_config.height),
            0,
            c.XBlackPixel(app.display, app.screen_num),
            c.XBlackPixel(app.display, app.screen_num),
        );
        _ = c.XSelectInput(
            app.display,
            app.window,
            c.ExposureMask | c.ButtonPressMask | c.StructureNotifyMask | c.SubstructureNotifyMask,
        );
    }

    fn createGraphics(app: *App) !void {
        app.gc = c.XCreateGC(app.display, app.window, 0, null);
        app.visual = c.XDefaultVisual(app.display, app.screen_num);
        app.colormap = c.XDefaultColormap(app.display, app.screen_num);
        app.xft_draw = c.XftDrawCreate(app.display, app.window, app.visual, app.colormap) orelse
            return error.XftDrawCreateFailed;
    }

    fn loadWidgetFonts(app: *App) !void {
        for (panel_config.widgets, 0..) |widget, idx| {
            const style = app.widgetStyle(widget);
            app.widget_fonts[idx] = try app.openFont(style.font);
            app.fallback_fonts[idx] = try app.openFont(.{
                .name = fallback_font_name,
                .size = style.font.size,
            });
        }
    }

    fn openFont(app: *App, font: cfg.Font) !*c.XftFont {
        var buffer: [256]u8 = undefined;
        const name = try std.fmt.bufPrint(&buffer, "{s}-{d}", .{ font.name, font.size });
        return c.XftFontOpenName(app.display, app.screen_num, name.ptr) orelse return error.XftFontOpenFailed;
    }

    fn mapWindow(app: *App) void {
        _ = c.XMapWindow(app.display, app.window);
        _ = c.XFlush(app.display);
    }

    fn subscribeRootChanges(app: *App) void {
        _ = c.XSelectInput(app.display, app.root, c.PropertyChangeMask);
        _ = c.XFlush(app.display);
    }

    fn setDockProperties(app: *App) void {
        const screen_width: c_ulong = @intCast(c.XDisplayWidth(app.display, app.screen_num));
        var size_hints = std.mem.zeroes(c.XSizeHints);
        size_hints.flags = c.PPosition | c.PMinSize | c.PMaxSize;
        size_hints.x = 0;
        size_hints.y = 0;
        size_hints.min_width = @intCast(screen_width);
        size_hints.min_height = @intCast(panel_config.height);
        size_hints.max_width = @intCast(screen_width);
        size_hints.max_height = @intCast(panel_config.height);
        _ = c.XSetWMNormalHints(app.display, app.window, &size_hints);

        const win_type = [_]c.Atom{app.atoms.net_wm_window_type_dock};
        _ = c.XChangeProperty(app.display, app.window, app.atoms.net_wm_window_type, c.XA_ATOM, 32, c.PropModeReplace, @ptrCast(&win_type), win_type.len);

        const desktop = [_]c_ulong{0xFFFFFFFF};
        _ = c.XChangeProperty(app.display, app.window, app.atoms.net_wm_desktop, c.XA_CARDINAL, 32, c.PropModeReplace, @ptrCast(&desktop), desktop.len);

        const strut = [_]c_ulong{ 0, 0, @intCast(panel_config.height), 0 };
        _ = c.XChangeProperty(app.display, app.window, app.atoms.net_wm_strut, c.XA_CARDINAL, 32, c.PropModeReplace, @ptrCast(&strut), strut.len);

        const strut_partial = [_]c_ulong{
            0, 0, @intCast(panel_config.height), 0,
            0, 0, 0, 0,
            0, screen_width - 1, 0, 0,
        };

        const title = "taskbar";
        _ = c.XChangeProperty(app.display, app.window, app.atoms.net_wm_name, app.atoms.utf8_string, 8, c.PropModeReplace, title.ptr, title.len);

        const wm_class = "taskbar\x00taskbar\x00";
        _ = c.XChangeProperty(app.display, app.window, app.atoms.wm_class, c.XA_STRING, 8, c.PropModeReplace, wm_class.ptr, wm_class.len);
        _ = c.XChangeProperty(app.display, app.window, app.atoms.net_wm_strut_partial, c.XA_CARDINAL, 32, c.PropModeReplace, @ptrCast(&strut_partial), strut_partial.len);
        _ = c.XFlush(app.display);
    }

    fn refreshDesktopState(app: *App) !void {
        for (app.desktops.items) |desktop| app.allocator.free(desktop.name);
        app.desktops.clearRetainingCapacity();

        const desktop_count = try app.readCardinalProperty(app.root, app.atoms.net_number_of_desktops) orelse 1;
        app.current_desktop = try app.readCardinalProperty(app.root, app.atoms.net_current_desktop) orelse 0;

        const names_data = try app.readPropertyBytes(app.root, app.atoms.net_desktop_names, app.atoms.utf8_string);
        defer if (names_data) |data| app.allocator.free(data);

        var name_iter = x11.DesktopNameIter.init(names_data orelse &.{});
        var i: u32 = 0;
        while (i < desktop_count) : (i += 1) {
            const fallback = try std.fmt.allocPrint(app.allocator, "{d}", .{i + 1});
            errdefer app.allocator.free(fallback);
            const desktop_name = if (name_iter.next()) |name| try app.allocator.dupe(u8, name) else fallback;
            if (desktop_name.ptr != fallback.ptr) app.allocator.free(fallback);
            try app.desktops.append(app.allocator, .{ .index = i, .name = desktop_name });
        }
    }

    fn redraw(app: *App) void {
        const panel_style = panel_config.style;
        _ = c.XSetForeground(app.display, app.gc, panel_style.bg);
        _ = c.XFillRectangle(app.display, app.window, app.gc, 0, 0, @intCast(c.XDisplayWidth(app.display, app.screen_num)), @intCast(panel_config.height));

        const layouts = app.computeLayouts();
        for (layouts) |layout| {
            const widget = panel_config.widgets[layout.index];
            switch (widget) {
                .pager => |pager_cfg| app.drawPager(layout, pager_cfg),
                .taskbar => |taskbar_cfg| app.drawTaskbar(layout, taskbar_cfg),
                .tray => |tray_cfg| app.drawTray(layout, tray_cfg),
                .clock => |clock_cfg| app.drawClock(layout, clock_cfg),
            }
        }
        _ = c.XFlush(app.display);
    }

    fn drawPager(app: *App, layout: WidgetLayout, pager_cfg: cfg.Pager) void {
        const style = app.widgetStyle(.{ .pager = pager_cfg });
        const font = app.widget_fonts[layout.index];
        var x = layout.x;
        for (app.desktops.items) |desktop| {
            const text = desktop.name;
            const item_width = app.textItemWidth(font, text, style.padding);
            if (desktop.index == app.current_desktop) {
                _ = c.XSetForeground(app.display, app.gc, style.active_bg);
                _ = c.XFillRectangle(app.display, app.window, app.gc, @intCast(x), 0, @intCast(item_width), @intCast(panel_config.height));
            }
            app.drawText(layout.index, font, if (desktop.index == app.current_desktop) style.active_text else style.text, x + style.padding, app.textBaseline(font) + style.text_offset, text);
            x += item_width;
        }
    }

    fn drawTaskbar(app: *App, layout: WidgetLayout, taskbar_cfg: cfg.Taskbar) void {
        const style = app.widgetStyle(.{ .taskbar = taskbar_cfg });
        const font = app.widget_fonts[layout.index];
        const item_width = app.taskbarItemWidth(layout.width, taskbar_cfg);
        var x = layout.x;
        for (app.windows.items) |window| {
            const draw_width = item_width;
            if (draw_width <= 0) break;
            if (window.window == app.active_window) {
                _ = c.XSetForeground(app.display, app.gc, style.active_bg);
                _ = c.XFillRectangle(app.display, app.window, app.gc, @intCast(x), 0, @intCast(draw_width), @intCast(panel_config.height));
            }
            const text_width = @max(0, draw_width - style.padding * 2);
            const clipped = app.fitText(font, window.title, text_width);
            app.drawText(layout.index, font, if (window.window == app.active_window) style.active_text else style.text, x + style.padding, app.textBaseline(font) + style.text_offset, clipped);
            x += draw_width;
        }
    }

    fn drawTray(app: *App, layout: WidgetLayout, tray_cfg: cfg.Tray) void {
        _ = app.widgetStyle(.{ .tray = tray_cfg });
        app.layoutTrayIcons(layout.x, trayY(), trayIconSize(), tray_cfg.item_gap);
    }

    fn drawClock(app: *App, layout: WidgetLayout, clock_cfg: cfg.Clock) void {
        const style = app.widgetStyle(.{ .clock = clock_cfg });
        const font = app.widget_fonts[layout.index];
        const text = app.clock_text[0..app.clock_len];
        const text_width = app.measureText(font, text);
        const available = @max(0, layout.width - style.padding * 2);
        const aligned_x = switch (clock_cfg.text_align) {
            .left => layout.x + style.padding,
            .center => layout.x + style.padding + @divFloor(@max(0, available - text_width), 2),
            .right => layout.x + layout.width - style.padding - text_width,
        };
        app.drawText(layout.index, font, style.text, aligned_x, app.textBaseline(font) + style.text_offset, text);
    }

    fn processPendingEvents(app: *App) !bool {
        var needs_redraw = false;
        while (c.XPending(app.display) > 0) {
            var event: c.XEvent = undefined;
            _ = c.XNextEvent(app.display, &event);
            switch (event.type) {
                c.Expose => needs_redraw = true,
                c.ButtonPress => try app.handleClick(@intCast(event.xbutton.x), @intCast(event.xbutton.y)),
                c.ClientMessage => {
                    if (app.tray.isDockRequest(&event.xclient)) {
                        if (try app.dockTrayIcon(app.tray.dockRequestWindow(&event.xclient))) needs_redraw = true;
                    }
                },
                c.PropertyNotify => {
                    if (app.isRootStateProperty(event.xproperty.window, event.xproperty.atom)) {
                        try app.refreshDesktopState();
                        try app.refreshWindowState();
                        needs_redraw = true;
                    } else if (app.isTrackedClientProperty(event.xproperty.window, event.xproperty.atom)) {
                        try app.refreshDesktopState();
                        try app.refreshWindowState();
                        needs_redraw = true;
                    }
                },
                c.DestroyNotify => {
                    if (app.tray.removeIcon(event.xdestroywindow.window)) needs_redraw = true;
                },
                else => {},
            }
        }
        return needs_redraw;
    }

    fn updateClock(app: *App) bool {
        const now: c.time_t = c.time(null);
        const now_i64: i64 = @intCast(now);
        const now_minute = @divFloor(now_i64, 60);
        if (now_minute == app.last_clock_minute) return false;

        var local: c.struct_tm = undefined;
        if (c.localtime_r(&now, &local) == null) return false;
        const format = app.clockFormat();
        const written = c.strftime(&app.clock_text, app.clock_text.len, format.ptr, &local);
        if (written == 0) return false;
        app.clock_len = written;
        app.last_clock_minute = now_minute;
        return true;
    }

    fn handleClick(app: *App, x: i32, y: i32) !void {
        if (y < 0 or y > panel_config.height) return;

        const layouts = app.computeLayouts();
        for (layouts) |layout| {
            if (x < layout.x or x > layout.x + layout.width) continue;
            const widget = panel_config.widgets[layout.index];
            switch (widget) {
                .pager => |pager_cfg| return try app.handlePagerClick(layout, pager_cfg, x),
                .taskbar => |taskbar_cfg| return try app.handleTaskbarClick(layout, taskbar_cfg, x),
                else => return,
            }
        }
    }

    fn handlePagerClick(app: *App, layout: WidgetLayout, pager_cfg: cfg.Pager, x: i32) !void {
        const style = app.widgetStyle(.{ .pager = pager_cfg });
        const font = app.widget_fonts[layout.index];
        var left = layout.x;
        for (app.desktops.items) |desktop| {
            const width = app.textItemWidth(font, desktop.name, style.padding);
            if (x >= left and x <= left + width) {
                try app.setCurrentDesktop(desktop.index);
                return;
            }
            left += width;
        }
    }

    fn handleTaskbarClick(app: *App, layout: WidgetLayout, taskbar_cfg: cfg.Taskbar, x: i32) !void {
        const width = app.taskbarItemWidth(layout.width, taskbar_cfg);
        var left = layout.x;
        for (app.windows.items) |window| {
            const draw_width = width;
            if (x >= left and x <= left + draw_width) {
                try app.activateWindow(window.window);
                return;
            }
            left += draw_width;
        }
    }

    fn setCurrentDesktop(app: *App, index: u32) !void {
        var event = std.mem.zeroes(c.XEvent);
        event.xclient.type = c.ClientMessage;
        event.xclient.window = app.root;
        event.xclient.message_type = app.atoms.net_current_desktop;
        event.xclient.format = 32;
        event.xclient.data.l[0] = index;
        event.xclient.data.l[1] = c.CurrentTime;
        _ = c.XSendEvent(app.display, app.root, c.False, c.SubstructureRedirectMask | c.SubstructureNotifyMask, &event);
        _ = c.XFlush(app.display);
    }

    fn activateWindow(app: *App, window: c.Window) !void {
        var event = std.mem.zeroes(c.XEvent);
        event.xclient.type = c.ClientMessage;
        event.xclient.window = window;
        event.xclient.message_type = app.atoms.net_active_window;
        event.xclient.format = 32;
        event.xclient.data.l[0] = 1;
        event.xclient.data.l[1] = c.CurrentTime;
        event.xclient.data.l[2] = 0;
        _ = c.XSendEvent(app.display, app.root, c.False, c.SubstructureRedirectMask | c.SubstructureNotifyMask, &event);
        _ = c.XFlush(app.display);
    }

    fn refreshWindowState(app: *App) !void {
        for (app.windows.items) |window| app.allocator.free(window.title);
        app.windows.clearRetainingCapacity();

        const reported_active_window = try app.readWindowProperty(app.root, app.atoms.net_active_window) orelse 0;
        app.active_window = 0;

        const windows = try app.readWindowListProperty(app.root, app.atoms.net_client_list) orelse
            try app.readWindowListProperty(app.root, app.atoms.net_client_list_stacking) orelse
            &.{};
        defer if (windows.len != 0) app.allocator.free(windows);

        for (windows) |window| {
            if (window == app.window) continue;
            app.subscribeClientWindow(window);
            const desktop = try app.readCardinalProperty(window, app.atoms.net_wm_desktop) orelse continue;
            if (desktop != app.current_desktop and desktop != 0xFFFFFFFF) continue;
            if (try app.hasAtomProperty(window, app.atoms.net_wm_window_type, app.atoms.net_wm_window_type_dock)) continue;
            if (try app.hasAtomProperty(window, app.atoms.net_wm_state, app.atoms.net_wm_state_skip_taskbar)) continue;
            if (try app.hasAtomProperty(window, app.atoms.orcsome_state, app.atoms.orcsome_skip_taskbar)) continue;

            const title = try app.readWindowTitle(window) orelse continue;
            errdefer app.allocator.free(title);
            try app.windows.append(app.allocator, .{ .window = window, .desktop = desktop, .title = title });
            if (window == reported_active_window) app.active_window = window;
        }
    }

    fn subscribeClientWindow(app: *App, window: c.Window) void {
        _ = c.XSelectInput(app.display, window, c.PropertyChangeMask | c.StructureNotifyMask);
    }

    fn isRootStateProperty(app: *App, window: c.Window, atom: c.Atom) bool {
        return window == app.root and
            (atom == app.atoms.net_current_desktop or
                atom == app.atoms.net_number_of_desktops or
                atom == app.atoms.net_desktop_names or
                atom == app.atoms.net_client_list or
                atom == app.atoms.net_client_list_stacking or
                atom == app.atoms.net_active_window);
    }

    fn isTrackedClientProperty(app: *App, window: c.Window, atom: c.Atom) bool {
        if (atom != app.atoms.net_wm_name and
            atom != app.atoms.wm_name and
            atom != app.atoms.net_wm_desktop and
            atom != app.atoms.net_wm_state and
            atom != app.atoms.orcsome_state) return false;
        return window != app.root and window != app.window;
    }

    fn dockTrayIcon(app: *App, icon_window: c.Window) !bool {
        const tray_layout = app.findWidgetLayout(.tray) orelse return false;
        const tray_cfg = panel_config.widgets[tray_layout.index].tray;
        const icon_x = tray_layout.x + @as(i32, @intCast(app.tray.icons.items.len)) * (trayIconSize() + tray_cfg.item_gap);
        const added = try app.tray.addIcon(app.display, app.window, icon_window, icon_x, trayY());
        if (added) app.layoutTrayIcons(tray_layout.x, trayY(), trayIconSize(), tray_cfg.item_gap);
        return added;
    }

    fn layoutTrayIcons(app: *App, tray_x: i32, tray_y: i32, icon_size: i32, item_gap: i32) void {
        app.tray.relayout(app.display, tray_x, tray_y, icon_size, item_gap);
    }

    fn clockFormat(app: *App) []const u8 {
        _ = app;
        for (panel_config.widgets) |widget| {
            switch (widget) {
                .clock => |clock_cfg| return clock_cfg.format,
                else => {},
            }
        }
        return "%H:%M";
    }

    fn findWidgetLayout(app: *App, kind: WidgetKind) ?WidgetLayout {
        const layouts = app.computeLayouts();
        for (layouts) |layout| if (layout.kind == kind) return layout;
        return null;
    }

    fn computeLayouts(app: *App) [widget_count]WidgetLayout {
        var layouts: [widget_count]WidgetLayout = undefined;
        var fixed_width_total: i32 = 0;
        var flex_index: ?usize = null;

        for (panel_config.widgets, 0..) |widget, idx| {
            const kind = widgetKind(widget);
            const width = switch (widget) {
                .pager => |pager_cfg| switch (pager_cfg.width) {
                    .min_content => app.measurePagerWidth(idx, pager_cfg),
                    .fixed => |w| w,
                    .flex => blk: {
                        flex_index = idx;
                        break :blk 0;
                    },
                },
                .taskbar => |taskbar_cfg| switch (taskbar_cfg.width) {
                    .min_content => app.measureTaskbarMinWidth(),
                    .fixed => |w| w,
                    .flex => blk: {
                        flex_index = idx;
                        break :blk 0;
                    },
                },
                .tray => |tray_cfg| switch (tray_cfg.width) {
                    .min_content => app.measureTrayWidth(tray_cfg),
                    .fixed => |w| w,
                    .flex => blk: {
                        flex_index = idx;
                        break :blk 0;
                    },
                },
                .clock => |clock_cfg| switch (clock_cfg.width) {
                    .min_content => app.measureClockWidth(idx, clock_cfg),
                    .fixed => |w| w,
                    .flex => blk: {
                        flex_index = idx;
                        break :blk 0;
                    },
                },
            };
            layouts[idx] = .{ .index = idx, .kind = kind, .x = 0, .width = width };
            if (flex_index != idx) fixed_width_total += width;
        }

        const total_gaps: i32 = if (widget_count > 1) @as(i32, widget_count - 1) * panel_config.gap else 0;
        const panel_width: i32 = c.XDisplayWidth(app.display, app.screen_num);
        const remaining = @max(0, panel_width - fixed_width_total - total_gaps);
        if (flex_index) |idx| layouts[idx].width = remaining;

        var x: i32 = 0;
        for (&layouts, 0..) |*layout, idx| {
            layout.x = x;
            x += layout.width;
            if (idx + 1 < widget_count) x += panel_config.gap;
        }
        return layouts;
    }

    fn widgetStyle(app: *App, widget: cfg.Widget) ResolvedStyle {
        _ = app;
        const base = panel_config.style;
        const override = switch (widget) {
            .pager => |v| v.style,
            .taskbar => |v| v.style,
            .tray => |v| v.style,
            .clock => |v| v.style,
        };
        return .{
            .font = override.font orelse base.font,
            .bg = override.bg orelse base.bg,
            .text = override.text orelse base.text,
            .active_bg = override.active_bg orelse base.active_bg,
            .active_text = override.active_text orelse base.active_text,
            .padding = override.padding orelse base.padding,
            .text_offset = override.text_offset orelse base.text_offset,
        };
    }

    fn measurePagerWidth(app: *App, widget_index: usize, pager_cfg: cfg.Pager) i32 {
        const style = app.widgetStyle(.{ .pager = pager_cfg });
        const font = app.widget_fonts[widget_index];
        var width: i32 = 0;
        for (app.desktops.items) |desktop| width += app.textItemWidth(font, desktop.name, style.padding);
        return width;
    }

    fn measureTaskbarMinWidth(app: *App) i32 {
        _ = app;
        return 0;
    }

    fn measureTrayWidth(app: *App, tray_cfg: cfg.Tray) i32 {
        return app.tray.widthFor(trayIconSize(), tray_cfg.item_gap);
    }

    fn measureClockWidth(app: *App, widget_index: usize, clock_cfg: cfg.Clock) i32 {
        const font = app.widget_fonts[widget_index];
        const style = app.widgetStyle(.{ .clock = clock_cfg });
        const text_width = app.measureText(font, app.clock_text[0..app.clock_len]);
        return text_width + style.padding * 2;
    }

    fn textItemWidth(app: *App, font: *c.XftFont, text: []const u8, padding: i32) i32 {
        return app.measureText(font, text) + padding * 2;
    }

    fn taskbarItemWidth(app: *App, total_width: i32, taskbar_cfg: cfg.Taskbar) i32 {
        if (app.windows.items.len == 0) return 0;
        const natural = @divFloor(total_width, @as(i32, @intCast(app.windows.items.len)));
        if (taskbar_cfg.max_item_width) |max_width| {
            return @min(natural, max_width);
        }
        return natural;
    }

    fn textBaseline(app: *App, font: *c.XftFont) i32 {
        _ = app;
        const text_height = font.ascent + font.descent;
        return @divFloor(panel_config.height - text_height, 2) + font.ascent;
    }

    fn measureText(app: *App, font: *c.XftFont, text: []const u8) i32 {
        if (text.len == 0) return 0;
        var extents: c.XGlyphInfo = undefined;
        c.XftTextExtentsUtf8(app.display, font, text.ptr, @intCast(text.len), &extents);
        return extents.xOff;
    }

    fn fitText(app: *App, font: *c.XftFont, text: []const u8, max_width: i32) []const u8 {
        if (app.measureText(font, text) <= max_width) return text;
        var end = text.len;
        while (end > 0) : (end -= 1) {
            const candidate = text[0..end];
            if (app.measureText(font, candidate) <= max_width) return candidate;
        }
        return "";
    }

    fn drawText(app: *App, widget_index: usize, font: *c.XftFont, color_rgb: u32, x: i32, baseline_y: i32, text: []const u8) void {
        if (text.len == 0) return;
        var color: c.XftColor = undefined;
        defer c.XftColorFree(app.display, app.visual, app.colormap, &color);
        var value = c.XRenderColor{
            .red = @intCast(((color_rgb >> 16) & 0xff) * 257),
            .green = @intCast(((color_rgb >> 8) & 0xff) * 257),
            .blue = @intCast((color_rgb & 0xff) * 257),
            .alpha = 0xffff,
        };
        if (c.XftColorAllocValue(app.display, app.visual, app.colormap, &value, &color) == 0) return;

        var draw_x = x;
        var utf8 = std.unicode.Utf8View.init(text) catch return;
        var iter = utf8.iterator();
        const fallback = app.fallback_fonts[widget_index];
        while (iter.nextCodepointSlice()) |slice| {
            const draw_font = if (c.XftCharExists(app.display, font, tryDecodeCodepoint(slice)) != 0) font else fallback;
            c.XftDrawStringUtf8(app.xft_draw, &color, draw_font, draw_x, baseline_y, slice.ptr, @intCast(slice.len));
            draw_x += app.measureText(draw_font, slice);
        }
    }

    fn readWindowTitle(app: *App, window: c.Window) !?[]u8 {
        if (try app.readPropertyBytes(window, app.atoms.net_wm_name, app.atoms.utf8_string)) |title| return title;
        return try app.readPropertyBytesAny(window, app.atoms.wm_name);
    }

    fn readCardinalProperty(app: *App, window: c.Window, atom: c.Atom) !?u32 {
        var actual_type: c.Atom = 0;
        var actual_format: c_int = 0;
        var nitems: c_ulong = 0;
        var bytes_after: c_ulong = 0;
        var prop: [*c]u8 = null;
        if (c.XGetWindowProperty(app.display, window, atom, 0, 1, c.False, c.XA_CARDINAL, &actual_type, &actual_format, &nitems, &bytes_after, &prop) != c.Success) return null;
        defer {
            if (prop != null) _ = c.XFree(prop);
        }
        if (nitems == 0 or actual_format != 32 or prop == null) return null;
        const values: [*]c_ulong = @ptrCast(@alignCast(prop));
        return @truncate(values[0]);
    }

    fn readPropertyBytes(app: *App, window: c.Window, atom: c.Atom, expected_type: c.Atom) !?[]u8 {
        var actual_type: c.Atom = 0;
        var actual_format: c_int = 0;
        var nitems: c_ulong = 0;
        var bytes_after: c_ulong = 0;
        var prop: [*c]u8 = null;
        if (c.XGetWindowProperty(app.display, window, atom, 0, 4096, c.False, expected_type, &actual_type, &actual_format, &nitems, &bytes_after, &prop) != c.Success) return null;
        defer {
            if (prop != null) _ = c.XFree(prop);
        }
        if (nitems == 0 or actual_format != 8 or prop == null) return null;
        const raw: [*]const u8 = @ptrCast(prop);
        return try app.allocator.dupe(u8, raw[0..@intCast(nitems)]);
    }

    fn readPropertyBytesAny(app: *App, window: c.Window, atom: c.Atom) !?[]u8 {
        var actual_type: c.Atom = 0;
        var actual_format: c_int = 0;
        var nitems: c_ulong = 0;
        var bytes_after: c_ulong = 0;
        var prop: [*c]u8 = null;
        if (c.XGetWindowProperty(app.display, window, atom, 0, 4096, c.False, c.AnyPropertyType, &actual_type, &actual_format, &nitems, &bytes_after, &prop) != c.Success) return null;
        defer {
            if (prop != null) _ = c.XFree(prop);
        }
        if (nitems == 0 or actual_format != 8 or prop == null) return null;
        const raw: [*]const u8 = @ptrCast(prop);
        return try app.allocator.dupe(u8, raw[0..@intCast(nitems)]);
    }

    fn readWindowProperty(app: *App, window: c.Window, atom: c.Atom) !?c.Window {
        var actual_type: c.Atom = 0;
        var actual_format: c_int = 0;
        var nitems: c_ulong = 0;
        var bytes_after: c_ulong = 0;
        var prop: [*c]u8 = null;
        if (c.XGetWindowProperty(app.display, window, atom, 0, 1, c.False, c.XA_WINDOW, &actual_type, &actual_format, &nitems, &bytes_after, &prop) != c.Success) return null;
        defer {
            if (prop != null) _ = c.XFree(prop);
        }
        if (nitems == 0 or actual_format != 32 or prop == null) return null;
        const values: [*]c_ulong = @ptrCast(@alignCast(prop));
        return @intCast(@as(u32, @truncate(values[0])));
    }

    fn readWindowListProperty(app: *App, window: c.Window, atom: c.Atom) !?[]c.Window {
        var actual_type: c.Atom = 0;
        var actual_format: c_int = 0;
        var nitems: c_ulong = 0;
        var bytes_after: c_ulong = 0;
        var prop: [*c]u8 = null;
        if (c.XGetWindowProperty(app.display, window, atom, 0, 4096, c.False, c.XA_WINDOW, &actual_type, &actual_format, &nitems, &bytes_after, &prop) != c.Success) return null;
        defer {
            if (prop != null) _ = c.XFree(prop);
        }
        if (nitems == 0 or actual_format != 32 or prop == null) return null;
        const values: [*]c_ulong = @ptrCast(@alignCast(prop));
        const owned = try app.allocator.alloc(c.Window, @intCast(nitems));
        for (owned, 0..) |*dst, idx| dst.* = @intCast(@as(u32, @truncate(values[idx])));
        return owned;
    }

    fn hasAtomProperty(app: *App, window: c.Window, property_atom: c.Atom, expected_atom: c.Atom) !bool {
        var actual_type: c.Atom = 0;
        var actual_format: c_int = 0;
        var nitems: c_ulong = 0;
        var bytes_after: c_ulong = 0;
        var prop: [*c]u8 = null;
        if (c.XGetWindowProperty(app.display, window, property_atom, 0, 32, c.False, c.XA_ATOM, &actual_type, &actual_format, &nitems, &bytes_after, &prop) != c.Success) return false;
        defer {
            if (prop != null) _ = c.XFree(prop);
        }
        if (nitems == 0 or actual_format != 32 or prop == null) return false;
        const values: [*]c_ulong = @ptrCast(@alignCast(prop));
        for (0..@intCast(nitems)) |idx| {
            if (@as(c.Atom, @intCast(@as(u32, @truncate(values[idx])))) == expected_atom) return true;
        }
        return false;
    }
};

fn widgetKind(widget: cfg.Widget) WidgetKind {
    return switch (widget) {
        .pager => .pager,
        .taskbar => .taskbar,
        .tray => .tray,
        .clock => .clock,
    };
}

fn itemHeight() i32 {
    return panel_config.height;
}

fn trayY() i32 {
    return tray_inset_y;
}

fn trayIconSize() i32 {
    return panel_config.height - tray_inset_y * 2;
}

fn nextClockTimeoutMs() c_int {
    const now: i64 = @intCast(c.time(null));
    const next_minute = ((@divFloor(now, 60) + 1) * 60);
    return @intCast(@max(0, next_minute - now) * 1000);
}

fn tryDecodeCodepoint(slice: []const u8) c.FcChar32 {
    return @intCast(std.unicode.utf8Decode(slice) catch 0xfffd);
}
