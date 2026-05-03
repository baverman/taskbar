const cfg = @import("../config.zig");
const common = @import("common.zig");
const x11 = @import("../x11.zig");
const c = x11.c;

pub const Clock = struct {
    config: cfg.Clock,
    style: cfg.Style,
    font: *c.PangoFontDescription,
    text: [32]u8,
    len: usize,
    last_clock_minute: i64,

    pub fn init(ctx: *const common.Context, base_style: cfg.Style, config: cfg.Clock) !Clock {
        const style = common.resolveStyle(base_style, config.style);
        return .{
            .config = config,
            .style = style,
            .font = try ctx.openFont(style.font),
            .text = [_]u8{0} ** 32,
            .len = 0,
            .last_clock_minute = -1,
        };
    }

    pub fn deinit(self: *Clock, ctx: *const common.Context) void {
        _ = ctx;
        c.pango_font_description_free(self.font);
    }

    pub fn refresh(self: *Clock, ctx: *const common.Context) !void {
        _ = self.update(ctx);
    }

    pub fn start(_: *Clock, _: *const common.Context) !void {}

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
        ctx.drawText(
            self.font,
            self.style.text,
            .{ .x = rect.x + self.style.padding, .y = rect.y, .width = @max(0, rect.width - self.style.padding * 2), .height = rect.height },
            text,
            self.config.text_align,
            self.style.text_offset,
            false,
        );
    }

    pub fn handleEvent(_: *Clock, _: *const common.Context, _: common.Rect, _: *const c.XEvent) !common.Update {
        return .{};
    }

    pub fn click(_: *Clock, _: *const common.Context, _: common.Rect, _: i32, _: i32) common.Update {
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
