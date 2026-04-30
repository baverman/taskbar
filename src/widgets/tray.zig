const std = @import("std");
const cfg = @import("../config.zig");
const common = @import("common.zig");
const x11 = @import("../x11.zig");
const c = x11.c;

const tray_inset_y = 4;
const xembed_embedded_notify: c_long = 0;
const system_tray_request_dock: c_long = 0;

const TrayIcon = struct {
    window: c.Window,
};

pub const Tray = struct {
    config: cfg.Tray,
    style: common.ResolvedStyle,
    allocator: std.mem.Allocator,
    icons: std.ArrayList(TrayIcon),
    owner_window: c.Window,
    selection_atom: c.Atom,
    opcode_atom: c.Atom,
    xembed_atom: c.Atom,
    xembed_info_atom: c.Atom,
    manager_atom: c.Atom,

    pub fn init(ctx: *const common.Context, base_style: cfg.Style, config: cfg.Tray) Tray {
        return .{
            .config = config,
            .style = common.resolveStyle(base_style, config.style),
            .allocator = ctx.allocator,
            .icons = .{},
            .owner_window = ctx.gfx.window,
            .selection_atom = ctx.gfx.atoms.net_system_tray_s0,
            .opcode_atom = ctx.gfx.atoms.net_system_tray_opcode,
            .xembed_atom = ctx.gfx.atoms.xembed,
            .xembed_info_atom = ctx.gfx.atoms.xembed_info,
            .manager_atom = ctx.gfx.atoms.manager,
        };
    }

    pub fn deinit(self: *Tray) void {
        self.icons.deinit(self.allocator);
    }

    pub fn refresh(self: *Tray, ctx: *const common.Context) void {
        _ = self;
        _ = ctx;
    }

    pub fn claimSelection(self: *Tray, ctx: *const common.Context) !void {
        _ = c.XSetSelectionOwner(ctx.gfx.display, self.selection_atom, self.owner_window, c.CurrentTime);
        if (c.XGetSelectionOwner(ctx.gfx.display, self.selection_atom) != self.owner_window) {
            return error.TraySelectionUnavailable;
        }

        var event = std.mem.zeroes(c.XEvent);
        event.xclient.type = c.ClientMessage;
        event.xclient.window = ctx.gfx.root;
        event.xclient.message_type = self.manager_atom;
        event.xclient.format = 32;
        event.xclient.data.l[0] = c.CurrentTime;
        event.xclient.data.l[1] = @intCast(self.selection_atom);
        event.xclient.data.l[2] = @intCast(self.owner_window);
        _ = c.XSendEvent(ctx.gfx.display, ctx.gfx.root, c.False, c.StructureNotifyMask, &event);
        _ = c.XFlush(ctx.gfx.display);
    }

    pub fn measure(self: *const Tray, ctx: *const common.Context) i32 {
        return self.widthFor(trayIconSize(ctx.config.height), self.config.item_gap);
    }

    pub fn draw(self: *Tray, ctx: *const common.Context, rect: common.Rect) void {
        self.relayout(ctx.gfx.display, rect.x, trayY(), trayIconSize(ctx.config.height), self.config.item_gap);
    }

    pub fn handleEvent(self: *Tray, ctx: *const common.Context, rect: common.Rect, event: *const c.XEvent) !common.Update {
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
        const icon_x = rect.x + @as(i32, @intCast(self.icons.items.len)) * (trayIconSize(ctx.config.height) + self.config.item_gap);
        const added = try self.addIcon(ctx.gfx.display, ctx.gfx.window, icon_window, icon_x, trayY());
        if (added) self.relayout(ctx.gfx.display, rect.x, trayY(), trayIconSize(ctx.config.height), self.config.item_gap);
        return added;
    }

    fn addIcon(
        self: *Tray,
        display: *c.Display,
        panel_window: c.Window,
        icon_window: c.Window,
        panel_x: i32,
        panel_y: i32,
    ) !bool {
        if (self.contains(icon_window)) return false;
        _ = c.XSelectInput(display, icon_window, c.StructureNotifyMask | c.PropertyChangeMask);
        _ = c.XReparentWindow(display, icon_window, panel_window, panel_x, panel_y);
        _ = c.XMapWindow(display, icon_window);
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
        for (self.icons.items) |icon| {
            _ = c.XMoveResizeWindow(display, icon.window, x, start_y, @intCast(icon_size), @intCast(icon_size));
            _ = c.XMapWindow(display, icon.window);
            x += icon_size + item_gap;
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
        var event = std.mem.zeroes(c.XEvent);
        event.xclient.type = c.ClientMessage;
        event.xclient.window = icon_window;
        event.xclient.message_type = self.xembed_atom;
        event.xclient.format = 32;
        event.xclient.data.l[0] = c.CurrentTime;
        event.xclient.data.l[1] = xembed_embedded_notify;
        event.xclient.data.l[2] = 0;
        event.xclient.data.l[3] = @intCast(self.owner_window);
        event.xclient.data.l[4] = 0;
        _ = c.XSendEvent(display, icon_window, c.False, c.NoEventMask, &event);
    }
};

fn trayY() i32 {
    return tray_inset_y;
}

fn trayIconSize(panel_height: i32) i32 {
    return panel_height - tray_inset_y * 2;
}
