const cfg = @import("../config.zig");
const common = @import("common.zig");
const x11 = @import("../x11.zig");
const c = x11.c;

pub const Clock = struct {
    config: cfg.Clock,
    style: common.ResolvedStyle,
    font: *c.XftFont,
    fallback_font: *c.XftFont,
    text: [32]u8,
    len: usize,
    last_clock_minute: i64,

    pub fn init(ctx: *const common.Context, base_style: cfg.Style, config: cfg.Clock) !Clock {
        const style = common.resolveStyle(base_style, config.style);
        return .{
            .config = config,
            .style = style,
            .font = try ctx.openFont(style.font),
            .fallback_font = try ctx.openFont(.{ .name = "DejaVu Sans", .size = style.font.size }),
            .text = [_]u8{0} ** 32,
            .len = 0,
            .last_clock_minute = -1,
        };
    }

    pub fn deinit(self: *Clock, ctx: *const common.Context) void {
        c.XftFontClose(ctx.gfx.display, self.font);
        c.XftFontClose(ctx.gfx.display, self.fallback_font);
    }

    pub fn refresh(self: *Clock, ctx: *const common.Context) void {
        _ = self.update(ctx);
    }

    pub fn tick(self: *Clock, ctx: *const common.Context) common.Update {
        if (!self.update(ctx)) return .{};
        return switch (self.config.width) {
            .min_content => .{ .redraw = true, .relayout = true },
            else => .{ .redraw = true },
        };
    }

    pub fn measure(self: *const Clock, ctx: *const common.Context) i32 {
        const text_width = ctx.measureText(self.font, self.text[0..self.len]);
        return text_width + self.style.padding * 2;
    }

    pub fn draw(self: *Clock, ctx: *const common.Context, rect: common.Rect) void {
        const text = self.text[0..self.len];
        const text_width = ctx.measureText(self.font, text);
        const available = @max(0, rect.width - self.style.padding * 2);
        const aligned_x = switch (self.config.text_align) {
            .left => rect.x + self.style.padding,
            .center => rect.x + self.style.padding + @divFloor(@max(0, available - text_width), 2),
            .right => rect.x + rect.width - self.style.padding - text_width,
        };
        ctx.drawText(self.font, self.fallback_font, self.style.text, aligned_x, ctx.textBaseline(self.font) + self.style.text_offset, text);
    }

    pub fn handleEvent(self: *Clock, ctx: *const common.Context, event: *const c.XEvent) common.Update {
        _ = self;
        _ = ctx;
        _ = event;
        return .{};
    }

    fn update(self: *Clock, ctx: *const common.Context) bool {
        _ = ctx;
        const now: c.time_t = c.time(null);
        const now_i64: i64 = @intCast(now);
        const now_minute = @divFloor(now_i64, 60);
        if (now_minute == self.last_clock_minute) return false;

        var local: c.struct_tm = undefined;
        if (c.localtime_r(&now, &local) == null) return false;
        const written = c.strftime(&self.text, self.text.len, self.config.format.ptr, &local);
        if (written == 0) return false;
        self.len = written;
        self.last_clock_minute = now_minute;
        return true;
    }
};
