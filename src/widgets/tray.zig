const std = @import("std");
const cfg = @import("../config.zig");
const common = @import("common.zig");
const x11 = @import("../x11.zig");
const c = x11.c;

const tray_inset_y = 4;
const xembed_embedded_notify: c_long = 0;
const system_tray_request_dock: c_long = 0;
var tray_bad_window_seen = false;

const TrayIcon = struct {
    window: c.Window,
};

pub const Tray = struct {
    config: cfg.Tray,
    style: cfg.Style,
    allocator: std.mem.Allocator,
    icons: std.ArrayList(TrayIcon),
    owner_window: c.Window,
    selection_atom: c.Atom,
    opcode_atom: c.Atom,
    xembed_atom: c.Atom,
    xembed_info_atom: c.Atom,
    manager_atom: c.Atom,
    started: bool,

    pub fn init(ctx: *const common.Context, base_style: cfg.Style, config: cfg.Tray) Tray {
        return .{
            .config = config,
            .style = common.resolveStyle(base_style, config.style),
            .allocator = ctx.allocator,
            .icons = .empty,
            .owner_window = ctx.gfx.window,
            .selection_atom = ctx.gfx.atoms.net_system_tray_s0,
            .opcode_atom = ctx.gfx.atoms.net_system_tray_opcode,
            .xembed_atom = ctx.gfx.atoms.xembed,
            .xembed_info_atom = ctx.gfx.atoms.xembed_info,
            .manager_atom = ctx.gfx.atoms.manager,
            .started = false,
        };
    }

    pub fn deinit(self: *Tray, ctx: *const common.Context) void {
        _ = ctx;
        self.icons.deinit(self.allocator);
    }

    pub fn update(self: *Tray, ctx: *const common.Context) !common.Status {
        if (self.started) return .{};
        _ = c.XSetSelectionOwner(ctx.gfx.display, self.selection_atom, self.owner_window, c.CurrentTime);
        if (c.XGetSelectionOwner(ctx.gfx.display, self.selection_atom) != self.owner_window) {
            return error.TraySelectionUnavailable;
        }

        x11.sendClientMessage(
            ctx.gfx.display,
            ctx.gfx.root,
            ctx.gfx.root,
            self.manager_atom,
            c.StructureNotifyMask,
            .{ c.CurrentTime, @intCast(self.selection_atom), @intCast(self.owner_window), 0, 0 },
        );
        _ = c.XFlush(ctx.gfx.display);
        self.started = true;
        return .{};
    }

    pub fn measure(self: *const Tray, ctx: *const common.Context) i32 {
        return self.widthFor(iconSize(self, ctx), self.config.item_gap);
    }

    pub fn draw(self: *Tray, ctx: *const common.Context, rect: common.Rect) void {
        self.relayout(ctx.gfx.display, rect.x, trayY(), iconSize(self, ctx), self.config.item_gap);
    }

    pub fn handleEvent(self: *Tray, ctx: *const common.Context, rect: common.Rect, event: *const c.XEvent) !common.Status {
        switch (event.type) {
            c.ClientMessage => {
                if (!self.isDockRequest(&event.xclient)) return .{};
                const icon_window = self.dockRequestWindow(&event.xclient);
                if (try self.dock(ctx, rect, icon_window)) {
                    return .{ .redraw = true, .relayout = true };
                }
                return .{};
            },
            c.DestroyNotify => {
                if (self.removeIcon(event.xdestroywindow.window)) {
                    return .{ .redraw = true, .relayout = true };
                }
                return .{};
            },
            else => return .{},
        }
    }

    fn widthFor(self: *const Tray, icon_size: i32, item_gap: i32) i32 {
        if (self.icons.items.len == 0) return 0;
        const count: i32 = @intCast(self.icons.items.len);
        return count * icon_size + (count - 1) * item_gap;
    }

    fn isDockRequest(self: *const Tray, event: *const c.XClientMessageEvent) bool {
        return event.message_type == self.opcode_atom and
            event.format == 32 and
            event.data.l[1] == system_tray_request_dock;
    }

    fn dockRequestWindow(self: *const Tray, event: *const c.XClientMessageEvent) c.Window {
        _ = self;
        return @intCast(event.data.l[2]);
    }

    fn dock(self: *Tray, ctx: *const common.Context, rect: common.Rect, icon_window: c.Window) !bool {
        const icon_size = iconSize(self, ctx);
        const icon_x = rect.x + self.widthFor(icon_size, self.config.item_gap);
        const added = try self.addIcon(ctx.gfx.display, ctx.gfx.window, icon_window, icon_x, trayY(), icon_size);
        if (added) self.relayout(ctx.gfx.display, rect.x, trayY(), icon_size, self.config.item_gap);
        return added;
    }

    fn addIcon(
        self: *Tray,
        display: *c.Display,
        panel_window: c.Window,
        icon_window: c.Window,
        panel_x: i32,
        panel_y: i32,
        icon_size: i32,
    ) !bool {
        if (self.contains(icon_window)) return false;
        if (!embedIconWindow(display, panel_window, icon_window, panel_x, panel_y, icon_size)) return false;
        try self.icons.append(self.allocator, .{ .window = icon_window });
        self.sendXEmbedEmbeddedNotify(display, icon_window);
        _ = c.XFlush(display);
        return true;
    }

    fn removeIcon(self: *Tray, icon_window: c.Window) bool {
        for (self.icons.items, 0..) |icon, idx| {
            if (icon.window != icon_window) continue;
            _ = self.icons.orderedRemove(idx);
            return true;
        }
        return false;
    }

    fn relayout(self: *Tray, display: *c.Display, start_x: i32, start_y: i32, icon_size: i32, item_gap: i32) void {
        var x = start_x;
        var idx: usize = 0;
        while (idx < self.icons.items.len) {
            const icon = self.icons.items[idx];
            if (!moveResizeMapIcon(display, icon.window, x, start_y, icon_size)) {
                _ = self.icons.orderedRemove(idx);
                continue;
            }
            x += icon_size + item_gap;
            idx += 1;
        }
        _ = c.XFlush(display);
    }

    fn contains(self: *const Tray, icon_window: c.Window) bool {
        for (self.icons.items) |icon| {
            if (icon.window == icon_window) return true;
        }
        return false;
    }

    fn sendXEmbedEmbeddedNotify(self: *Tray, display: *c.Display, icon_window: c.Window) void {
        x11.sendClientMessage(
            display,
            icon_window,
            icon_window,
            self.xembed_atom,
            c.NoEventMask,
            .{ c.CurrentTime, xembed_embedded_notify, 0, @intCast(self.owner_window), 0 },
        );
    }
};

fn trayY() i32 {
    return tray_inset_y;
}

fn iconSize(self: *const Tray, ctx: *const common.Context) i32 {
    return self.config.icon_size orelse (ctx.config.height - tray_inset_y * 2);
}

fn moveResizeMapIcon(display: *c.Display, icon_window: c.Window, x: i32, y: i32, size: i32) bool {
    return withBadWindowTolerance(display, moveResizeMapIconUnchecked, .{ icon_window, x, y, size });
}

fn embedIconWindow(
    display: *c.Display,
    panel_window: c.Window,
    icon_window: c.Window,
    panel_x: i32,
    panel_y: i32,
    icon_size: i32,
) bool {
    return withBadWindowTolerance(display, embedIconWindowUnchecked, .{
        panel_window,
        icon_window,
        panel_x,
        panel_y,
        icon_size,
    });
}

fn withBadWindowTolerance(display: *c.Display, comptime Action: fn (*c.Display, anytype) void, args: anytype) bool {
    const previous = c.XSetErrorHandler(trayXErrorHandler);
    defer _ = c.XSetErrorHandler(previous);
    tray_bad_window_seen = false;
    Action(display, args);
    _ = c.XSync(display, c.False);
    return !tray_bad_window_seen;
}

fn embedIconWindowUnchecked(display: *c.Display, args: anytype) void {
    _ = c.XSelectInput(display, args[1], c.StructureNotifyMask | c.PropertyChangeMask);
    _ = c.XReparentWindow(display, args[1], args[0], args[2], args[3]);
    _ = c.XMoveResizeWindow(display, args[1], args[2], args[3], @intCast(args[4]), @intCast(args[4]));
    _ = c.XMapWindow(display, args[1]);
}

fn moveResizeMapIconUnchecked(display: *c.Display, args: anytype) void {
    _ = c.XMoveResizeWindow(display, args[0], args[1], args[2], @intCast(args[3]), @intCast(args[3]));
    _ = c.XMapWindow(display, args[0]);
}

fn trayXErrorHandler(_: ?*c.Display, event: [*c]c.XErrorEvent) callconv(.c) c_int {
    if (event != null and event.*.error_code == c.BadWindow) {
        tray_bad_window_seen = true;
    }
    return 0;
}
