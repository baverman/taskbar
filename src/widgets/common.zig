const std = @import("std");
const cfg = @import("../config.zig");
const cairo_mod = @import("../cairo.zig");
const x11 = @import("../x11.zig");
const c = x11.c;
const x = x11.x;
const z = x11.z;
const utils = @import("../utils.zig");
const PT = z.PropertyType;

pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const Status = struct {
    redraw: bool = false,
    relayout: bool = false,
    update: bool = false,
    next_update_in_ms: ?i64 = null,
};

pub const Gfx = struct {
    conn: *z.Connection,
    root: x.Window,
    window: x.Window,
    root_width: u16,
    root_depth: u8,
    root_visual: u32,
    cairo_surface: cairo_mod.Surface,
    cairo: *c.cairo_t,
    pango_layout: *c.PangoLayout,
    atoms: x11.Atoms,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const cfg.Config,
    gfx: Gfx,
    current_time_ms: i64,

    pub fn panelWidth(ctx: *const Context) i32 {
        return ctx.gfx.root_width;
    }

    pub fn openFont(ctx: *const Context, font: cfg.Font) !*c.PangoFontDescription {
        _ = ctx;
        var buffer: [256]u8 = undefined;
        const name = try std.fmt.bufPrintZ(&buffer, "{s} {d}", .{ font.name, font.size });
        return c.pango_font_description_from_string(name.ptr) orelse return error.PangoFontDescriptionFailed;
    }

    pub fn fillRect(ctx: *const Context, color: u32, rect: Rect) void {
        setSourceColor(ctx.gfx.cairo, color);
        c.cairo_rectangle(
            ctx.gfx.cairo,
            @floatFromInt(rect.x),
            @floatFromInt(rect.y),
            @floatFromInt(rect.width),
            @floatFromInt(rect.height),
        );
        _ = c.cairo_fill(ctx.gfx.cairo);
    }

    pub fn measureText(ctx: *const Context, font: *c.PangoFontDescription, text: []const u8) i32 {
        if (text.len == 0) return 0;
        const layout = ctx.gfx.pango_layout;
        c.pango_layout_set_font_description(layout, font);
        c.pango_layout_set_text(layout, text.ptr, @intCast(text.len));
        c.pango_layout_set_width(layout, -1);
        c.pango_layout_set_alignment(layout, c.PANGO_ALIGN_LEFT);
        c.pango_layout_set_ellipsize(layout, c.PANGO_ELLIPSIZE_NONE);
        var width: c_int = 0;
        var height: c_int = 0;
        c.pango_layout_get_pixel_size(layout, &width, &height);
        return width;
    }

    pub fn textItemWidth(ctx: *const Context, font: *c.PangoFontDescription, text: []const u8, padding: i32) i32 {
        return ctx.measureText(font, text) + padding * 2;
    }

    pub fn drawText(
        ctx: *const Context,
        font: *c.PangoFontDescription,
        color_rgb: u32,
        rect: Rect,
        text: []const u8,
        text_align: cfg.Align,
        text_offset: i32,
        ellipsize: bool,
    ) void {
        if (text.len == 0 or rect.width <= 0 or rect.height <= 0) return;
        const layout = ctx.gfx.pango_layout;
        c.pango_layout_set_font_description(layout, font);
        c.pango_layout_set_text(layout, text.ptr, @intCast(text.len));
        c.pango_layout_set_width(layout, rect.width * c.PANGO_SCALE);
        c.pango_layout_set_alignment(layout, switch (text_align) {
            .left => c.PANGO_ALIGN_LEFT,
            .center => c.PANGO_ALIGN_CENTER,
            .right => c.PANGO_ALIGN_RIGHT,
        });
        c.pango_layout_set_ellipsize(layout, if (ellipsize) c.PANGO_ELLIPSIZE_END else c.PANGO_ELLIPSIZE_NONE);

        var text_width: c_int = 0;
        var text_height: c_int = 0;
        c.pango_layout_get_pixel_size(layout, &text_width, &text_height);
        const y = rect.y + @divFloor(@max(0, rect.height - text_height), 2) + text_offset;

        _ = c.cairo_save(ctx.gfx.cairo);
        c.cairo_rectangle(
            ctx.gfx.cairo,
            @floatFromInt(rect.x),
            @floatFromInt(rect.y),
            @floatFromInt(rect.width),
            @floatFromInt(rect.height),
        );
        c.cairo_clip(ctx.gfx.cairo);
        setSourceColor(ctx.gfx.cairo, color_rgb);
        c.cairo_move_to(ctx.gfx.cairo, @floatFromInt(rect.x), @floatFromInt(y));
        c.pango_cairo_show_layout(ctx.gfx.cairo, layout);
        _ = c.cairo_restore(ctx.gfx.cairo);
    }

    pub fn getWindowTitle(ctx: *const Context, window: x.Window, buffer: []u8) !?[]const u8 {
        if (try ctx.readPropertyBytesInto(window, ctx.gfx.atoms.net_wm_icon_name, ctx.gfx.atoms.utf8_string, buffer)) |result| {
            return result;
        }
        if (try ctx.readPropertyBytesInto(window, ctx.gfx.atoms.net_wm_name, ctx.gfx.atoms.utf8_string, buffer)) |result| {
            return result;
        }
        return try ctx.readPropertyBytesInto(window, ctx.gfx.atoms.wm_name, x.Atom_.Any, buffer);
    }

    pub fn readPropertyBytesInto(
        ctx: *const Context,
        window: x.Window,
        property: x.Atom,
        expected_type: x.Atom,
        buffer: []u8,
    ) !?[]const u8 {
        const values = z.getProperty(ctx.gfx.conn, window, property, PT.string.as(expected_type), buffer) catch |err| switch (err) {
            error.UnexpectedType, error.UnexpectedFormat, error.PropertyTruncated => return null,
            else => return err,
        };
        if (values.len == 0) return null;
        return values;
    }

    pub fn hasAtomProperty(ctx: *const Context, window: x.Window, property_atom: x.Atom, expected_atom: x.Atom) !bool {
        var atoms_buf: [32]x.Atom = undefined;
        const values = z.getProperty(ctx.gfx.conn, window, property_atom, PT.atom, &atoms_buf) catch |err| switch (err) {
            error.UnexpectedType, error.UnexpectedFormat, error.PropertyTruncated => return false,
            else => return err,
        };
        for (values) |value| {
            if (expected_atom == value) return true;
        }
        return false;
    }

    pub fn subscribeClientWindow(ctx: *const Context, window: x.Window) !void {
        try ctx.gfx.conn.request(x.ChangeWindowAttributes, .{
            .window = window,
            .value_list = .{
                .event_mask = x.EventMask.of(&.{ .PropertyChange, .StructureNotify }),
            },
        });
    }

    pub fn setCurrentDesktop(ctx: *const Context, index: u32) !void {
        try x11.sendClientMessage(
            ctx.gfx.conn,
            ctx.gfx.root,
            ctx.gfx.root,
            ctx.gfx.atoms.net_current_desktop,
            x.EventMask.of(&.{ .SubstructureRedirect, .SubstructureNotify }),
            &.{ index, @intFromEnum(x.Time.CurrentTime) },
        );
    }

    pub fn activateWindow(ctx: *const Context, window: x.Window) !void {
        try x11.sendClientMessage(
            ctx.gfx.conn,
            ctx.gfx.root,
            window,
            ctx.gfx.atoms.net_active_window,
            x.EventMask.of(&.{ .SubstructureRedirect, .SubstructureNotify }),
            &.{ 1, @intFromEnum(x.Time.CurrentTime) },
        );
    }
};

pub fn resolveStyle(base: cfg.Style, override: cfg.StyleOverride) cfg.Style {
    return .{
        .font = override.font orelse base.font,
        .bg = override.bg orelse base.bg,
        .text = override.text orelse base.text,
        .active_bg = override.active_bg orelse base.active_bg,
        .active_text = override.active_text orelse base.active_text,
        .padding = override.padding orelse base.padding,
        .text_offset = override.text_offset orelse base.text_offset,
    };
}

fn setSourceColor(cr: *c.cairo_t, color_rgb: u32) void {
    c.cairo_set_source_rgb(
        cr,
        @as(f64, @floatFromInt((color_rgb >> 16) & 0xff)) / 255.0,
        @as(f64, @floatFromInt((color_rgb >> 8) & 0xff)) / 255.0,
        @as(f64, @floatFromInt(color_rgb & 0xff)) / 255.0,
    );
}
