const std = @import("std");
const cfg = @import("../config.zig");
const common = @import("common.zig");
const x11 = @import("../x11.zig");
const c = x11.c;
const x = x11.x;
const z = x11.z;
const utils = @import("../utils.zig");
const PT = z.PropertyType;

const max_title_len = 512;

pub const WindowEntry = struct {
    window: x.Window,
    desktop: u32,
    title_buf: [max_title_len]u8 = undefined,
    title_len: usize = 0,

    pub fn title(self: *const @This()) []const u8 {
        return self.title_buf[0..self.title_len];
    }
};

pub const Taskbar = struct {
    config: cfg.Taskbar,
    style: cfg.Style,
    font: *c.PangoFontDescription,
    windows: std.ArrayList(WindowEntry),
    active_window: x.Window,
    windows_buf: []x.Window,

    pub fn init(ctx: *const common.Context, base_style: cfg.Style, config: cfg.Taskbar) !Taskbar {
        const style = common.resolveStyle(base_style, config.style);
        return .{
            .config = config,
            .style = style,
            .font = try ctx.openFont(style.font),
            .windows = .empty,
            .active_window = x.Window.None,
            .windows_buf = try ctx.allocator.alloc(x.Window, 1024),
        };
    }

    pub fn deinit(self: *Taskbar, ctx: *const common.Context) void {
        self.windows.deinit(ctx.allocator);
        ctx.allocator.free(self.windows_buf);
        c.pango_font_description_free(self.font);
    }

    pub fn update(self: *Taskbar, ctx: *const common.Context) !common.Status {
        const atoms = &ctx.gfx.atoms;
        const cn = ctx.gfx.conn;
        self.windows.clearRetainingCapacity();

        const current_desktop = try z.getScalarProperty(cn, ctx.gfx.root, atoms._NET_CURRENT_DESKTOP, PT.cardinal) orelse 0;
        const reported_active_window = try z.getScalarProperty(cn, ctx.gfx.root, atoms._NET_ACTIVE_WINDOW, PT.window) orelse x.Window.None;
        self.active_window = x.Window.None;

        const windows = try z.getProperty(cn, ctx.gfx.root, ctx.gfx.atoms._NET_CLIENT_LIST, PT.window, self.windows_buf);

        for (windows) |window| {
            if (window == ctx.gfx.window) continue;
            try ctx.subscribeClientWindow(window);
            const desktop = try z.getScalarProperty(cn, window, atoms._NET_WM_DESKTOP, PT.cardinal) orelse continue;
            if (desktop != current_desktop and desktop != 0xFFFFFFFF) continue;
            if (try ctx.hasAtomProperty(window, atoms._NET_WM_WINDOW_TYPE, atoms._NET_WM_WINDOW_TYPE_DOCK)) continue;
            if (try ctx.hasAtomProperty(window, atoms._NET_WM_STATE, atoms._NET_WM_STATE_SKIP_TASKBAR)) continue;

            var entry = WindowEntry{
                .window = window,
                .desktop = desktop,
            };
            const title = try ctx.getWindowTitle(window, &entry.title_buf) orelse utils.fillString(&entry.title_buf, "noname");
            entry.title_len = title.len;
            try self.windows.append(ctx.allocator, entry);
            if (window == reported_active_window) self.active_window = window;
        }
        return .{ .redraw = true };
    }

    pub fn handleEvent(self: *Taskbar, ctx: *const common.Context, rect: common.Rect, event: *const x.Event) !common.Status {
        const atoms = &ctx.gfx.atoms;
        switch (event.*) {
            .PropertyNotify => |property| {
                if (property.window == ctx.gfx.window) return .{};
                if (property.window == ctx.gfx.root) {
                    if (property.atom != atoms._NET_CURRENT_DESKTOP and
                        property.atom != atoms._NET_CLIENT_LIST and
                        property.atom != atoms._NET_ACTIVE_WINDOW) return .{};
                } else if (property.atom != atoms._NET_WM_NAME and
                    property.atom != atoms.WM_NAME and
                    property.atom != atoms._NET_WM_ICON_NAME and
                    property.atom != atoms._NET_WM_DESKTOP and
                    property.atom != atoms._NET_WM_STATE) return .{};
                return .{ .update = true };
            },
            .ButtonPress => |button| {
                if (button.event_y < 0 or button.event_y > ctx.config.height) return .{};
                return self.handleButtonPress(ctx, rect, button.event_x, button.event_y);
            },
            else => return .{},
        }
    }

    pub fn measure(self: *const Taskbar, ctx: *const common.Context) i32 {
        _ = self;
        _ = ctx;
        return 0;
    }

    pub fn draw(self: *Taskbar, ctx: *const common.Context, rect: common.Rect) void {
        const item_width = self.itemWidth(rect.width);
        var x_pos = rect.x;
        for (self.windows.items) |window| {
            if (item_width <= 0) break;
            const draw_width = item_width;
            if (window.window == self.active_window) {
                ctx.fillRect(self.style.active_bg, .{ .x = x_pos, .y = rect.y, .width = draw_width, .height = rect.height });
            }
            ctx.drawText(
                self.font,
                if (window.window == self.active_window) self.style.active_text else self.style.text,
                .{ .x = x_pos + self.style.padding, .y = rect.y, .width = @max(0, draw_width - self.style.padding * 2), .height = rect.height },
                window.title(),
                .left,
                self.style.text_offset,
                true,
            );
            x_pos += draw_width;
        }
    }

    fn handleButtonPress(self: *Taskbar, ctx: *const common.Context, rect: common.Rect, x_pos: i32, _: i32) common.Status {
        const width = self.itemWidth(rect.width);
        var left = rect.x;
        for (self.windows.items, 0..) |window, idx| {
            const draw_width = if (idx + 1 == self.windows.items.len) rect.x + rect.width - left else width;
            if (x_pos >= left and x_pos <= left + draw_width) {
                ctx.activateWindow(window.window) catch {};
                return .{};
            }
            left += draw_width;
        }
        return .{};
    }

    fn itemWidth(self: *const Taskbar, total_width: i32) i32 {
        if (self.windows.items.len == 0) return 0;
        const natural = @divFloor(total_width, @as(i32, @intCast(self.windows.items.len)));
        if (self.config.max_item_width) |max_width| return @min(natural, max_width);
        return natural;
    }
};
