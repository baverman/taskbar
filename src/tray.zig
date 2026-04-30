const std = @import("std");
const x11 = @import("x11.zig");
const c = x11.c;

pub const xembed_embedded_notify: c_long = 0;
pub const system_tray_request_dock: c_long = 0;

pub const TrayIcon = struct {
    window: c.Window,
};

pub const Tray = struct {
    allocator: std.mem.Allocator,
    icons: std.ArrayList(TrayIcon),
    owner_window: c.Window,
    selection_atom: c.Atom,
    opcode_atom: c.Atom,
    xembed_atom: c.Atom,
    xembed_info_atom: c.Atom,
    manager_atom: c.Atom,

    pub fn init(allocator: std.mem.Allocator, owner_window: c.Window, atoms: x11.Atoms) Tray {
        return .{
            .allocator = allocator,
            .icons = .{},
            .owner_window = owner_window,
            .selection_atom = atoms.net_system_tray_s0,
            .opcode_atom = atoms.net_system_tray_opcode,
            .xembed_atom = atoms.xembed,
            .xembed_info_atom = atoms.xembed_info,
            .manager_atom = atoms.manager,
        };
    }

    pub fn deinit(tray: *Tray) void {
        tray.icons.deinit(tray.allocator);
    }

    pub fn claimSelection(tray: *Tray, display: *c.Display, root: c.Window) !void {
        _ = c.XSetSelectionOwner(display, tray.selection_atom, tray.owner_window, c.CurrentTime);
        if (c.XGetSelectionOwner(display, tray.selection_atom) != tray.owner_window) {
            return error.TraySelectionUnavailable;
        }

        var event = std.mem.zeroes(c.XEvent);
        event.xclient.type = c.ClientMessage;
        event.xclient.window = root;
        event.xclient.message_type = tray.manager_atom;
        event.xclient.format = 32;
        event.xclient.data.l[0] = c.CurrentTime;
        event.xclient.data.l[1] = @intCast(tray.selection_atom);
        event.xclient.data.l[2] = @intCast(tray.owner_window);
        _ = c.XSendEvent(display, root, c.False, c.StructureNotifyMask, &event);
        _ = c.XFlush(display);
    }

    pub fn layoutWidth(tray: *const Tray) i16 {
        _ = tray;
        return 0;
    }

    pub fn widthFor(tray: *const Tray, icon_size: i32, item_gap: i32) i32 {
        if (tray.icons.items.len == 0) return 0;
        const count: i32 = @intCast(tray.icons.items.len);
        return count * icon_size + (count - 1) * item_gap;
    }

    pub fn isDockRequest(tray: *const Tray, event: *const c.XClientMessageEvent) bool {
        return event.message_type == tray.opcode_atom and
            event.format == 32 and
            event.data.l[1] == system_tray_request_dock;
    }

    pub fn dockRequestWindow(tray: *const Tray, event: *const c.XClientMessageEvent) c.Window {
        _ = tray;
        return @intCast(event.data.l[2]);
    }

    pub fn addIcon(
        tray: *Tray,
        display: *c.Display,
        panel_window: c.Window,
        icon_window: c.Window,
        panel_x: i32,
        panel_y: i32,
    ) !bool {
        if (tray.contains(icon_window)) return false;
        _ = c.XSelectInput(display, icon_window, c.StructureNotifyMask | c.PropertyChangeMask);
        _ = c.XReparentWindow(display, icon_window, panel_window, panel_x, panel_y);
        _ = c.XMapWindow(display, icon_window);
        try tray.icons.append(tray.allocator, .{ .window = icon_window });
        tray.sendXEmbedEmbeddedNotify(display, icon_window);
        _ = c.XFlush(display);
        return true;
    }

    pub fn removeIcon(tray: *Tray, icon_window: c.Window) bool {
        for (tray.icons.items, 0..) |icon, idx| {
            if (icon.window != icon_window) continue;
            _ = tray.icons.orderedRemove(idx);
            return true;
        }
        return false;
    }

    pub fn relayout(tray: *Tray, display: *c.Display, start_x: i32, start_y: i32, icon_size: i32, item_gap: i32) void {
        var x = start_x;
        for (tray.icons.items) |icon| {
            _ = c.XMoveResizeWindow(display, icon.window, x, start_y, @intCast(icon_size), @intCast(icon_size));
            _ = c.XMapWindow(display, icon.window);
            x += icon_size + item_gap;
        }
        _ = c.XFlush(display);
    }

    pub fn contains(tray: *const Tray, icon_window: c.Window) bool {
        for (tray.icons.items) |icon| {
            if (icon.window == icon_window) return true;
        }
        return false;
    }

    fn sendXEmbedEmbeddedNotify(tray: *Tray, display: *c.Display, icon_window: c.Window) void {
        var event = std.mem.zeroes(c.XEvent);
        event.xclient.type = c.ClientMessage;
        event.xclient.window = icon_window;
        event.xclient.message_type = tray.xembed_atom;
        event.xclient.format = 32;
        event.xclient.data.l[0] = c.CurrentTime;
        event.xclient.data.l[1] = xembed_embedded_notify;
        event.xclient.data.l[2] = 0;
        event.xclient.data.l[3] = @intCast(tray.owner_window);
        event.xclient.data.l[4] = 0;
        _ = c.XSendEvent(display, icon_window, c.False, c.NoEventMask, &event);
    }
};
