const std = @import("std");
const cfg = @import("../config.zig");
const x11 = @import("../x11.zig");
const common = @import("common.zig");
const c = x11.c;

const max_names_len = 1024;
const max_fallback_name_len = 32;

const Desktop = struct {
    index: u32,
    name: ?[]const u8 = null,
    title_width: i32 = 0,

    fn title(self: *const Desktop, fallback_buf: []u8) []const u8 {
        if (self.name) |name| return name;
        return std.fmt.bufPrint(fallback_buf, "{d}", .{self.index + 1}) catch unreachable;
    }
};

pub const Pager = struct {
    config: cfg.Pager,
    style: cfg.Style,
    font: *c.PangoFontDescription,
    desktops: std.ArrayList(Desktop),
    names_buf: []u8,
    current_desktop: u32,

    pub fn init(ctx: *const common.Context, base_style: cfg.Style, config: cfg.Pager) !Pager {
        const style = common.resolveStyle(base_style, config.style);
        return .{
            .config = config,
            .style = style,
            .font = try ctx.openFont(style.font),
            .desktops = .{},
            .names_buf = try ctx.allocator.alloc(u8, max_names_len),
            .current_desktop = 0,
        };
    }

    pub fn deinit(self: *Pager, ctx: *const common.Context) void {
        self.desktops.deinit(ctx.allocator);
        ctx.allocator.free(self.names_buf);
        c.pango_font_description_free(self.font);
    }

    pub fn update(self: *Pager, ctx: *const common.Context) !common.Status {
        var old_width: i32 = 0;
        for (self.desktops.items) |desktop| old_width += desktop.title_width;

        self.desktops.clearRetainingCapacity();

        const desktop_count = try ctx.readCardinalProperty(ctx.gfx.root, ctx.gfx.atoms.net_number_of_desktops) orelse 1;
        self.current_desktop = try ctx.readCardinalProperty(ctx.gfx.root, ctx.gfx.atoms.net_current_desktop) orelse 0;

        const names_data = try ctx.readPropertyBytesInto(self.names_buf, ctx.gfx.root, ctx.gfx.atoms.net_desktop_names, ctx.gfx.atoms.utf8_string);
        var name_iter = x11.DesktopNameIter.init(names_data orelse &.{});
        var i: u32 = 0;
        while (i < desktop_count) : (i += 1) {
            try self.desktops.append(ctx.allocator, .{
                .index = i,
                .name = name_iter.next(),
            });
            const desktop = &self.desktops.items[self.desktops.items.len - 1];
            var fallback_buf: [max_fallback_name_len]u8 = undefined;
            desktop.title_width = ctx.textItemWidth(self.font, desktop.title(&fallback_buf), self.style.padding);
        }
        return .{
            .redraw = true,
            .relayout = old_width != self.measure(ctx),
        };
    }

    pub fn handleEvent(self: *Pager, ctx: *const common.Context, rect: common.Rect, event: *const c.XEvent) !common.Status {
        switch (event.type) {
            c.PropertyNotify => {
                const property = event.xproperty;
                if (property.window != ctx.gfx.root) return .{};
                if (property.atom != ctx.gfx.atoms.net_current_desktop and
                    property.atom != ctx.gfx.atoms.net_number_of_desktops and
                    property.atom != ctx.gfx.atoms.net_desktop_names) return .{};
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

    pub fn measure(self: *const Pager, ctx: *const common.Context) i32 {
        _ = ctx;
        var width: i32 = 0;
        for (self.desktops.items) |desktop| width += desktop.title_width;
        return width;
    }

    pub fn draw(self: *Pager, ctx: *const common.Context, rect: common.Rect) void {
        var x = rect.x;
        for (self.desktops.items) |desktop| {
            var fallback_buf: [max_fallback_name_len]u8 = undefined;
            const label = desktop.title(&fallback_buf);
            const item_width = desktop.title_width;
            if (desktop.index == self.current_desktop) {
                ctx.fillRect(self.style.active_bg, .{ .x = x, .y = rect.y, .width = item_width, .height = rect.height });
            }
            ctx.drawText(
                self.font,
                if (desktop.index == self.current_desktop) self.style.active_text else self.style.text,
                .{ .x = x + self.style.padding, .y = rect.y, .width = @max(0, item_width - self.style.padding * 2), .height = rect.height },
                label,
                .left,
                self.style.text_offset,
                false,
            );
            x += item_width;
        }
    }

    fn handleButtonPress(self: *Pager, ctx: *const common.Context, rect: common.Rect, x: i32, y: i32) common.Status {
        _ = y;
        var left = rect.x;
        for (self.desktops.items) |desktop| {
            const width = desktop.title_width;
            if (x >= left and x <= left + width) {
                ctx.setCurrentDesktop(desktop.index);
                return .{};
            }
            left += width;
        }
        return .{};
    }
};
