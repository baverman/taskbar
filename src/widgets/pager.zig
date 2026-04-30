const std = @import("std");
const cfg = @import("../config.zig");
const x11 = @import("../x11.zig");
const common = @import("common.zig");
const c = x11.c;

const Desktop = struct {
    index: u32,
    name: []u8,
};

pub const Pager = struct {
    config: cfg.Pager,
    style: common.ResolvedStyle,
    font: *c.XftFont,
    fallback_font: *c.XftFont,
    desktops: std.ArrayList(Desktop),
    current_desktop: u32,

    pub fn init(ctx: *const common.Context, base_style: cfg.Style, config: cfg.Pager) !Pager {
        const style = common.resolveStyle(base_style, config.style);
        return .{
            .config = config,
            .style = style,
            .font = try ctx.openFont(style.font),
            .fallback_font = try ctx.openFont(.{ .name = "DejaVu Sans", .size = style.font.size }),
            .desktops = .{},
            .current_desktop = 0,
        };
    }

    pub fn deinit(self: *Pager, ctx: *const common.Context) void {
        for (self.desktops.items) |desktop| ctx.allocator.free(desktop.name);
        self.desktops.deinit(ctx.allocator);
        c.XftFontClose(ctx.gfx.display, self.font);
        c.XftFontClose(ctx.gfx.display, self.fallback_font);
    }

    pub fn refresh(self: *Pager, ctx: *const common.Context) !void {
        for (self.desktops.items) |desktop| ctx.allocator.free(desktop.name);
        self.desktops.clearRetainingCapacity();

        const desktop_count = try ctx.readCardinalProperty(ctx.gfx.root, ctx.gfx.atoms.net_number_of_desktops) orelse 1;
        self.current_desktop = try ctx.readCardinalProperty(ctx.gfx.root, ctx.gfx.atoms.net_current_desktop) orelse 0;

        const names_data = try ctx.readPropertyBytes(ctx.gfx.root, ctx.gfx.atoms.net_desktop_names, ctx.gfx.atoms.utf8_string);
        defer if (names_data) |data| ctx.allocator.free(data);

        var name_iter = x11.DesktopNameIter.init(names_data orelse &.{});
        var i: u32 = 0;
        while (i < desktop_count) : (i += 1) {
            const fallback = try std.fmt.allocPrint(ctx.allocator, "{d}", .{i + 1});
            errdefer ctx.allocator.free(fallback);
            const desktop_name = if (name_iter.next()) |name| try ctx.allocator.dupe(u8, name) else fallback;
            if (desktop_name.ptr != fallback.ptr) ctx.allocator.free(fallback);
            try self.desktops.append(ctx.allocator, .{ .index = i, .name = desktop_name });
        }
    }

    pub fn handleEvent(self: *Pager, ctx: *const common.Context, event: *const c.XEvent) !common.Update {
        if (event.type != c.PropertyNotify) return .{};
        const property = event.xproperty;
        if (property.window != ctx.gfx.root) return .{};
        if (property.atom != ctx.gfx.atoms.net_current_desktop and
            property.atom != ctx.gfx.atoms.net_number_of_desktops and
            property.atom != ctx.gfx.atoms.net_desktop_names) return .{};
        try self.refresh(ctx);
        return .{
            .redraw = true,
            .relayout = property.atom != ctx.gfx.atoms.net_current_desktop,
        };
    }

    pub fn measure(self: *const Pager, ctx: *const common.Context) i32 {
        var width: i32 = 0;
        for (self.desktops.items) |desktop| width += ctx.textItemWidth(self.font, desktop.name, self.style.padding);
        return width;
    }

    pub fn draw(self: *Pager, ctx: *const common.Context, rect: common.Rect) void {
        var x = rect.x;
        for (self.desktops.items) |desktop| {
            const item_width = ctx.textItemWidth(self.font, desktop.name, self.style.padding);
            if (desktop.index == self.current_desktop) {
                ctx.fillRect(self.style.active_bg, .{ .x = x, .y = rect.y, .width = item_width, .height = rect.height });
            }
            ctx.drawText(self.font, self.fallback_font, if (desktop.index == self.current_desktop) self.style.active_text else self.style.text, x + self.style.padding, ctx.textBaseline(self.font) + self.style.text_offset, desktop.name);
            x += item_width;
        }
    }

    pub fn click(self: *Pager, ctx: *const common.Context, rect: common.Rect, x: i32, y: i32) bool {
        _ = y;
        var left = rect.x;
        for (self.desktops.items) |desktop| {
            const width = ctx.textItemWidth(self.font, desktop.name, self.style.padding);
            if (x >= left and x <= left + width) {
                ctx.setCurrentDesktop(desktop.index);
                return true;
            }
            left += width;
        }
        return false;
    }
};
