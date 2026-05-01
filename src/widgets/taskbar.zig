const std = @import("std");
const cfg = @import("../config.zig");
const common = @import("common.zig");
const x11 = @import("../x11.zig");
const c = x11.c;

pub const WindowEntry = struct {
    window: c.Window,
    desktop: u32,
    title: []u8,
};

pub const Taskbar = struct {
    config: cfg.Taskbar,
    style: common.ResolvedStyle,
    font: *c.PangoFontDescription,
    windows: std.ArrayList(WindowEntry),
    active_window: c.Window,

    pub fn init(ctx: *const common.Context, base_style: cfg.Style, config: cfg.Taskbar) !Taskbar {
        const style = common.resolveStyle(base_style, config.style);
        return .{
            .config = config,
            .style = style,
            .font = try ctx.openFont(style.font),
            .windows = .{},
            .active_window = 0,
        };
    }

    pub fn deinit(self: *Taskbar, ctx: *const common.Context) void {
        for (self.windows.items) |window| ctx.allocator.free(window.title);
        self.windows.deinit(ctx.allocator);
        c.pango_font_description_free(self.font);
    }

    pub fn refresh(self: *Taskbar, ctx: *const common.Context) !void {
        for (self.windows.items) |window| ctx.allocator.free(window.title);
        self.windows.clearRetainingCapacity();

        const current_desktop = try ctx.readCardinalProperty(ctx.gfx.root, ctx.gfx.atoms.net_current_desktop) orelse 0;
        const reported_active_window = try ctx.readWindowProperty(ctx.gfx.root, ctx.gfx.atoms.net_active_window) orelse 0;
        self.active_window = 0;

        const windows = try ctx.readWindowListProperty(ctx.gfx.root, ctx.gfx.atoms.net_client_list) orelse
            try ctx.readWindowListProperty(ctx.gfx.root, ctx.gfx.atoms.net_client_list_stacking) orelse
            &.{};
        defer if (windows.len != 0) ctx.allocator.free(windows);

        for (windows) |window| {
            if (window == ctx.gfx.window) continue;
            ctx.subscribeClientWindow(window);
            const desktop = try ctx.readCardinalProperty(window, ctx.gfx.atoms.net_wm_desktop) orelse continue;
            if (desktop != current_desktop and desktop != 0xFFFFFFFF) continue;
            if (try ctx.hasAtomProperty(window, ctx.gfx.atoms.net_wm_window_type, ctx.gfx.atoms.net_wm_window_type_dock)) continue;
            if (try ctx.hasAtomProperty(window, ctx.gfx.atoms.net_wm_state, ctx.gfx.atoms.net_wm_state_skip_taskbar)) continue;
            if (try ctx.hasAtomProperty(window, ctx.gfx.atoms.orcsome_state, ctx.gfx.atoms.orcsome_skip_taskbar)) continue;

            const title = try ctx.readWindowTitle(window) orelse continue;
            errdefer ctx.allocator.free(title);
            try self.windows.append(ctx.allocator, .{ .window = window, .desktop = desktop, .title = title });
            if (window == reported_active_window) self.active_window = window;
        }
    }

    pub fn handleEvent(self: *Taskbar, ctx: *const common.Context, event: *const c.XEvent) !common.Update {
        if (event.type != c.PropertyNotify) return .{};
        const property = event.xproperty;
        if (property.window == ctx.gfx.window) return .{};
        if (property.window == ctx.gfx.root) {
            if (property.atom != ctx.gfx.atoms.net_current_desktop and
                property.atom != ctx.gfx.atoms.net_client_list and
                property.atom != ctx.gfx.atoms.net_client_list_stacking and
                property.atom != ctx.gfx.atoms.net_active_window) return .{};
        } else if (property.atom != ctx.gfx.atoms.net_wm_name and
            property.atom != ctx.gfx.atoms.wm_name and
            property.atom != ctx.gfx.atoms.net_wm_desktop and
            property.atom != ctx.gfx.atoms.net_wm_state and
            property.atom != ctx.gfx.atoms.orcsome_state) return .{};

        try self.refresh(ctx);
        return .{ .redraw = true };
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
            if (window.window == self.active_window) {
                ctx.fillRect(self.style.active_bg, .{ .x = x, .y = rect.y, .width = item_width, .height = rect.height });
            }
            ctx.drawText(
                self.font,
                if (window.window == self.active_window) self.style.active_text else self.style.text,
                .{ .x = x + self.style.padding, .y = rect.y, .width = @max(0, item_width - self.style.padding * 2), .height = rect.height },
                window.title,
                .left,
                self.style.text_offset,
                true,
            );
            x += item_width;
        }
    }

    pub fn click(self: *Taskbar, ctx: *const common.Context, rect: common.Rect, x: i32, y: i32) bool {
        _ = y;
        const width = self.itemWidth(rect.width);
        var left = rect.x;
        for (self.windows.items) |window| {
            if (x >= left and x <= left + width) {
                ctx.activateWindow(window.window);
                return true;
            }
            left += width;
        }
        return false;
    }

    fn itemWidth(self: *const Taskbar, total_width: i32) i32 {
        if (self.windows.items.len == 0) return 0;
        const natural = @divFloor(total_width, @as(i32, @intCast(self.windows.items.len)));
        if (self.config.max_item_width) |max_width| return @min(natural, max_width);
        return natural;
    }
};
