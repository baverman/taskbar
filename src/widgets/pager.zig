const std = @import("std");
const cfg = @import("../config.zig");
const x11 = @import("../x11.zig");
const common = @import("common.zig");
const c = x11.c;
const x = x11.x;
const PT = x11.z.PropertyType;

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
            .desktops = .empty,
            .names_buf = try ctx.allocator.alloc(u8, max_names_len),
            .current_desktop = 0,
        };
    }

    pub fn deinit(self: *Pager, ctx: *const common.Context) void {
        self.desktops.deinit(ctx.allocator);
        ctx.allocator.free(self.names_buf);
        c.pango_font_description_free(self.font);
    }

    pub fn update(self: *Pager, ctx: *common.Context) !common.Status {
        const atoms = &ctx.gfx.atoms;
        const cn = &ctx.gfx.conn;
        var old_width: i32 = 0;
        for (self.desktops.items) |desktop| old_width += desktop.title_width;

        self.desktops.clearRetainingCapacity();

        const desktop_count = try x11.z.getScalarProperty(cn, ctx.gfx.root, atoms._NET_NUMBER_OF_DESKTOPS, PT.cardinal) orelse 1;
        self.current_desktop = try x11.z.getScalarProperty(cn, ctx.gfx.root, atoms._NET_CURRENT_DESKTOP, PT.cardinal) orelse 0;

        const names_data = try ctx.readPropertyBytesInto(
            ctx.gfx.root,
            atoms._NET_DESKTOP_NAMES,
            atoms.UTF8_STRING,
            self.names_buf,
        );
        var name_iter = std.mem.splitScalar(u8, names_data orelse &.{}, 0);
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

    pub fn handleEvent(self: *Pager, ctx: *common.Context, rect: common.Rect, event: *const x.Event) !common.Status {
        const atoms = &ctx.gfx.atoms;
        switch (event.*) {
            .PropertyNotify => |property| {
                if (property.window != ctx.gfx.root) return .{};
                if (property.atom != atoms._NET_CURRENT_DESKTOP and
                    property.atom != atoms._NET_NUMBER_OF_DESKTOPS and
                    property.atom != atoms._NET_DESKTOP_NAMES) return .{};
                return .{ .update = true };
            },
            .ButtonPress => |button| {
                if (button.event_y < 0 or button.event_y > ctx.config.height) return .{};
                return self.handleButtonPress(ctx, rect, button.event_x, button.event_y);
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
        var x_pos = rect.x;
        for (self.desktops.items) |desktop| {
            var fallback_buf: [max_fallback_name_len]u8 = undefined;
            const label = desktop.title(&fallback_buf);
            const item_width = desktop.title_width;
            if (desktop.index == self.current_desktop) {
                ctx.fillRect(self.style.active_bg, .{
                    .x = x_pos,
                    .y = rect.y,
                    .width = item_width,
                    .height = rect.height,
                });
            }
            ctx.drawText(
                self.font,
                if (desktop.index == self.current_desktop) self.style.active_text else self.style.text,
                .{
                    .x = x_pos + self.style.padding,
                    .y = rect.y,
                    .width = @max(0, item_width - self.style.padding * 2),
                    .height = rect.height,
                },
                label,
                .left,
                self.style.text_offset,
                false,
            );
            x_pos += item_width;
        }
    }

    fn handleButtonPress(self: *Pager, ctx: *common.Context, rect: common.Rect, x_pos: i32, y: i32) common.Status {
        _ = y;
        var left = rect.x;
        for (self.desktops.items) |desktop| {
            const width = desktop.title_width;
            if (x_pos >= left and x_pos <= left + width) {
                ctx.setCurrentDesktop(desktop.index) catch {};
                return .{};
            }
            left += width;
        }
        return .{};
    }
};
