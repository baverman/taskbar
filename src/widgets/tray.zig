const std = @import("std");
const cfg = @import("../config.zig");
const common = @import("common.zig");
const x11 = @import("../x11.zig");
const c = x11.c;
const x = x11.x;

const tray_inset_y = 4;
const xembed_embedded_notify: u32 = 0;
const system_tray_request_dock: u32 = 0;

const TrayIcon = struct {
    window: x.Window,
};

pub const Tray = struct {
    config: cfg.Tray,
    style: cfg.Style,
    allocator: std.mem.Allocator,
    icons: std.ArrayList(TrayIcon),
    owner_window: x.Window,
    selection_atom: x.Atom,
    opcode_atom: x.Atom,
    xembed_atom: x.Atom,
    xembed_info_atom: x.Atom,
    manager_atom: x.Atom,
    started: bool,

    pub fn init(ctx: *const common.Context, base_style: cfg.Style, config: cfg.Tray) Tray {
        return .{
            .config = config,
            .style = common.resolveStyle(base_style, config.style),
            .allocator = ctx.allocator,
            .icons = .empty,
            .owner_window = ctx.gfx.window,
            .selection_atom = ctx.gfx.atoms._NET_SYSTEM_TRAY_S0,
            .opcode_atom = ctx.gfx.atoms._NET_SYSTEM_TRAY_OPCODE,
            .xembed_atom = ctx.gfx.atoms._XEMBED,
            .xembed_info_atom = ctx.gfx.atoms._XEMBED_INFO,
            .manager_atom = ctx.gfx.atoms.MANAGER,
            .started = false,
        };
    }

    pub fn deinit(self: *Tray, ctx: *const common.Context) void {
        _ = ctx;
        self.icons.deinit(self.allocator);
    }

    pub fn update(self: *Tray, ctx: *const common.Context) !common.Status {
        if (self.started) return .{};
        try ctx.gfx.conn.request(x.SetSelectionOwner, .{
            .owner = self.owner_window,
            .selection = self.selection_atom,
            .time = @intFromEnum(x.Time.CurrentTime),
        });
        const owner = try ctx.gfx.conn.request(x.GetSelectionOwner, .{
            .selection = self.selection_atom,
        });
        if (owner.owner != self.owner_window) {
            return error.TraySelectionUnavailable;
        }

        try x11.sendClientMessage(
            ctx.gfx.conn,
            ctx.gfx.root,
            ctx.gfx.root,
            self.manager_atom,
            x.EventMask.of(&.{.StructureNotify}),
            &.{ @intFromEnum(x.Time.CurrentTime), @intFromEnum(self.selection_atom), @intFromEnum(self.owner_window) },
        );
        self.started = true;
        return .{};
    }

    pub fn measure(self: *const Tray, ctx: *const common.Context) i32 {
        return self.widthFor(iconSize(self, ctx), self.config.item_gap);
    }

    pub fn draw(self: *Tray, ctx: *const common.Context, rect: common.Rect) void {
        self.relayout(ctx.gfx.conn, rect.x, trayY(), iconSize(self, ctx), self.config.item_gap);
    }

    pub fn handleEvent(self: *Tray, ctx: *const common.Context, rect: common.Rect, event: *const x.Event) !common.Status {
        switch (event.*) {
            .ClientMessage => |client| {
                if (!self.isDockRequest(&client)) return .{};
                const icon_window = self.dockRequestWindow(&client);
                if (try self.dock(ctx, rect, icon_window)) {
                    return .{ .redraw = true, .relayout = true };
                }
                return .{};
            },
            .DestroyNotify => |destroy| {
                if (self.removeIcon(destroy.window)) {
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

    fn isDockRequest(self: *const Tray, event: *const x.ClientMessageEvent) bool {
        return event.type == self.opcode_atom and
            event.format == 32 and
            x11.clientMessageDataU32(event, 1) == system_tray_request_dock;
    }

    fn dockRequestWindow(self: *const Tray, event: *const x.ClientMessageEvent) x.Window {
        _ = self;
        return @enumFromInt(x11.clientMessageDataU32(event, 2));
    }

    fn dock(self: *Tray, ctx: *const common.Context, rect: common.Rect, icon_window: x.Window) !bool {
        const icon_size = iconSize(self, ctx);
        const icon_x = rect.x + self.widthFor(icon_size, self.config.item_gap);
        const added = try self.addIcon(ctx.gfx.conn, ctx.gfx.window, icon_window, icon_x, trayY(), icon_size);
        if (added) self.relayout(ctx.gfx.conn, rect.x, trayY(), icon_size, self.config.item_gap);
        return added;
    }

    fn addIcon(
        self: *Tray,
        conn: *x11.z.Connection,
        panel_window: x.Window,
        icon_window: x.Window,
        panel_x: i32,
        panel_y: i32,
        icon_size: i32,
    ) !bool {
        if (self.contains(icon_window)) return false;
        if (!embedIconWindow(conn, panel_window, icon_window, panel_x, panel_y, icon_size)) return false;
        try self.icons.append(self.allocator, .{ .window = icon_window });
        try self.sendXEmbedEmbeddedNotify(conn, icon_window);
        return true;
    }

    fn removeIcon(self: *Tray, icon_window: x.Window) bool {
        for (self.icons.items, 0..) |icon, idx| {
            if (icon.window != icon_window) continue;
            _ = self.icons.orderedRemove(idx);
            return true;
        }
        return false;
    }

    fn relayout(self: *Tray, conn: *x11.z.Connection, start_x: i32, start_y: i32, icon_size: i32, item_gap: i32) void {
        var x_pos = start_x;
        var idx: usize = 0;
        while (idx < self.icons.items.len) {
            const icon = self.icons.items[idx];
            if (!moveResizeMapIcon(conn, icon.window, x_pos, start_y, icon_size)) {
                _ = self.icons.orderedRemove(idx);
                continue;
            }
            x_pos += icon_size + item_gap;
            idx += 1;
        }
    }

    fn contains(self: *const Tray, icon_window: x.Window) bool {
        for (self.icons.items) |icon| {
            if (icon.window == icon_window) return true;
        }
        return false;
    }

    fn sendXEmbedEmbeddedNotify(self: *Tray, conn: *x11.z.Connection, icon_window: x.Window) !void {
        try x11.sendClientMessage(
            conn,
            icon_window,
            icon_window,
            self.xembed_atom,
            x.EventMask.of(&.{.NoEvent}),
            &.{ @intFromEnum(x.Time.CurrentTime), xembed_embedded_notify, 0, @intFromEnum(self.owner_window) },
        );
    }
};

fn trayY() i32 {
    return tray_inset_y;
}

fn iconSize(self: *const Tray, ctx: *const common.Context) i32 {
    return self.config.icon_size orelse (ctx.config.height - tray_inset_y * 2);
}

fn moveResizeMapIcon(conn: *x11.z.Connection, icon_window: x.Window, x_pos: i32, y_pos: i32, size: i32) bool {
    conn.request(x.ConfigureWindow, .{
        .window = icon_window,
        .value_list = .{
            .x = x_pos,
            .y = y_pos,
            .width = @intCast(size),
            .height = @intCast(size),
        },
    }) catch |err| return trayBadWindowTolerated(conn, err);
    conn.request(x.MapWindow, .{ .window = icon_window }) catch |err| return trayBadWindowTolerated(conn, err);
    return true;
}

fn embedIconWindow(
    conn: *x11.z.Connection,
    panel_window: x.Window,
    icon_window: x.Window,
    panel_x: i32,
    panel_y: i32,
    icon_size: i32,
) bool {
    conn.request(x.ChangeWindowAttributes, .{
        .window = icon_window,
        .value_list = .{
            .event_mask = x.EventMask.of(&.{ .StructureNotify, .PropertyChange }),
        },
    }) catch |err| return trayBadWindowTolerated(conn, err);
    conn.request(x.ReparentWindow, .{
        .window = icon_window,
        .parent = panel_window,
        .x = @intCast(panel_x),
        .y = @intCast(panel_y),
    }) catch |err| return trayBadWindowTolerated(conn, err);
    return moveResizeMapIcon(conn, icon_window, panel_x, panel_y, icon_size);
}

fn trayBadWindowTolerated(conn: *x11.z.Connection, err: anyerror) bool {
    if (err != error.X11ProtocolError) return false;
    return conn.lastError().code == .Window;
}
