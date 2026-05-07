const std = @import("std");
const cfg = @import("../config.zig");
const common = @import("common.zig");
const c = @import("../x11.zig").c;
const utils = @import("../utils.zig");

const max_title_len = 512;

pub const WindowEntry = struct {
    window: c.Window,
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
    active_window: c.Window,
    windows_buf: []c.Window,

    pub fn init(ctx: *const common.Context, base_style: cfg.Style, config: cfg.Taskbar) !Taskbar {
        const style = common.resolveStyle(base_style, config.style);
        return .{
            .config = config,
            .style = style,
            .font = try ctx.openFont(style.font),
            .windows = .{},
            .active_window = 0,
            .windows_buf = try ctx.allocator.alloc(c.Window, 1024),
        };
    }

    pub fn deinit(self: *Taskbar, ctx: *const common.Context) void {
        self.windows.deinit(ctx.allocator);
        ctx.allocator.free(self.windows_buf);
        c.pango_font_description_free(self.font);
    }

    pub fn update(self: *Taskbar, ctx: *const common.Context) !common.Status {
        self.windows.clearRetainingCapacity();

        const current_desktop = try ctx.readCardinalProperty(ctx.gfx.root, ctx.gfx.atoms.net_current_desktop) orelse 0;
        const reported_active_window = try ctx.readWindowProperty(ctx.gfx.root, ctx.gfx.atoms.net_active_window) orelse 0;
        self.active_window = 0;

        const windows = try ctx.readWindowListPropertyInto(self.windows_buf, ctx.gfx.root, ctx.gfx.atoms.net_client_list) orelse
            &.{};

        for (windows) |window| {
            if (window == ctx.gfx.window) continue;
            ctx.subscribeClientWindow(window);
            const desktop = try ctx.readCardinalProperty(window, ctx.gfx.atoms.net_wm_desktop) orelse continue;
            if (desktop != current_desktop and desktop != 0xFFFFFFFF) continue;
            if (try ctx.hasAtomProperty(window, ctx.gfx.atoms.net_wm_window_type, ctx.gfx.atoms.net_wm_window_type_dock)) continue;
            if (try ctx.hasAtomProperty(window, ctx.gfx.atoms.net_wm_state, ctx.gfx.atoms.net_wm_state_skip_taskbar)) continue;

            var entry = WindowEntry{
                .window = window,
                .desktop = desktop,
            };
            const title = try ctx.readWindowTitleInto(&entry.title_buf, window) orelse utils.fillString(&entry.title_buf, "noname");
            entry.title_len = title.len;
            try self.windows.append(ctx.allocator, entry);
            if (window == reported_active_window) self.active_window = window;
        }
        return .{ .redraw = true };
    }

    pub fn handleEvent(self: *Taskbar, ctx: *const common.Context, rect: common.Rect, event: *const c.XEvent) !common.Status {
        switch (event.type) {
            c.PropertyNotify => {
                const property = event.xproperty;
                if (property.window == ctx.gfx.window) return .{};
                if (property.window == ctx.gfx.root) {
                    if (property.atom != ctx.gfx.atoms.net_current_desktop and
                        property.atom != ctx.gfx.atoms.net_client_list and
                        property.atom != ctx.gfx.atoms.net_active_window) return .{};
                } else if (property.atom != ctx.gfx.atoms.net_wm_name and
                    property.atom != ctx.gfx.atoms.wm_name and
                    property.atom != ctx.gfx.atoms.net_wm_icon_name and
                    property.atom != ctx.gfx.atoms.net_wm_desktop and
                    property.atom != ctx.gfx.atoms.net_wm_state) return .{};
                return .{ .update = true };
            },
            c.ButtonPress => {
                const x = event.xbutton.x;
                const y = event.xbutton.y;
                if (y < 0 or y > ctx.config.height) return .{};
                return self.handleButtonPress(ctx, rect, @intCast(x), @intCast(y));
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
        var x = rect.x;
        for (self.windows.items) |window| {
            if (item_width <= 0) break;
            const draw_width = item_width;
            if (window.window == self.active_window) {
                ctx.fillRect(self.style.active_bg, .{ .x = x, .y = rect.y, .width = draw_width, .height = rect.height });
            }
            ctx.drawText(
                self.font,
                if (window.window == self.active_window) self.style.active_text else self.style.text,
                .{ .x = x + self.style.padding, .y = rect.y, .width = @max(0, draw_width - self.style.padding * 2), .height = rect.height },
                window.title(),
                .left,
                self.style.text_offset,
                true,
            );
            x += draw_width;
        }
    }

    fn handleButtonPress(self: *Taskbar, ctx: *const common.Context, rect: common.Rect, x: i32, _: i32) common.Status {
        const width = self.itemWidth(rect.width);
        var left = rect.x;
        for (self.windows.items, 0..) |window, idx| {
            const draw_width = if (idx + 1 == self.windows.items.len) rect.x + rect.width - left else width;
            if (x >= left and x <= left + draw_width) {
                ctx.activateWindow(window.window);
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
