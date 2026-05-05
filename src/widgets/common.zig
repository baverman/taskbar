const std = @import("std");
const cfg = @import("../config.zig");
const x11 = @import("../x11.zig");
const c = x11.c;

pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const Update = packed struct {
    redraw: bool = false,
    relayout: bool = false,
};

pub const Gfx = struct {
    display: *c.Display,
    screen_num: c_int,
    root: c.Window,
    window: c.Window,
    visual: ?*c.Visual,
    cairo_surface: *c.cairo_surface_t,
    cairo: *c.cairo_t,
    atoms: x11.Atoms,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    config: *const cfg.Config,
    gfx: Gfx,

    pub fn panelWidth(ctx: *const Context) i32 {
        return c.XDisplayWidth(ctx.gfx.display, ctx.gfx.screen_num);
    }

    pub fn openFont(ctx: *const Context, font: cfg.Font) !*c.PangoFontDescription {
        _ = ctx;
        var buffer: [256]u8 = undefined;
        const name = try std.fmt.bufPrintZ(&buffer, "{s} {d}", .{ font.name, font.size });
        return c.pango_font_description_from_string(name.ptr) orelse return error.PangoFontDescriptionFailed;
    }

    pub fn fillRect(ctx: *const Context, color: u32, rect: Rect) void {
        setSourceColor(ctx.gfx.cairo, color);
        c.cairo_rectangle(ctx.gfx.cairo, @floatFromInt(rect.x), @floatFromInt(rect.y), @floatFromInt(rect.width), @floatFromInt(rect.height));
        _ = c.cairo_fill(ctx.gfx.cairo);
    }

    pub fn measureText(ctx: *const Context, font: *c.PangoFontDescription, text: []const u8) i32 {
        if (text.len == 0) return 0;
        const layout = c.pango_cairo_create_layout(ctx.gfx.cairo) orelse return 0;
        defer c.g_object_unref(layout);
        c.pango_layout_set_font_description(layout, font);
        c.pango_layout_set_text(layout, text.ptr, @intCast(text.len));
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
        const layout = c.pango_cairo_create_layout(ctx.gfx.cairo) orelse return;
        defer c.g_object_unref(layout);

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
        c.cairo_rectangle(ctx.gfx.cairo, @floatFromInt(rect.x), @floatFromInt(rect.y), @floatFromInt(rect.width), @floatFromInt(rect.height));
        c.cairo_clip(ctx.gfx.cairo);
        setSourceColor(ctx.gfx.cairo, color_rgb);
        c.cairo_move_to(ctx.gfx.cairo, @floatFromInt(rect.x), @floatFromInt(y));
        c.pango_cairo_show_layout(ctx.gfx.cairo, layout);
        _ = c.cairo_restore(ctx.gfx.cairo);
    }

    pub fn readWindowTitleInto(ctx: *const Context, dst: []u8, window: c.Window) ![]const u8 {
        if (try ctx.readPropertyBytesInto(dst, window, ctx.gfx.atoms.net_wm_name, ctx.gfx.atoms.utf8_string)) |title| return title;
        return (try ctx.readPropertyBytesInto(dst, window, ctx.gfx.atoms.wm_name, c.AnyPropertyType)) orelse &.{};
    }

    pub fn readCardinalProperty(ctx: *const Context, window: c.Window, atom: c.Atom) !?u32 {
        const prop = try ctx.getProperty(window, atom, 0, 1, c.XA_CARDINAL, 32) orelse return null;
        defer prop.deinit();
        const values: [*]const c_ulong = @ptrCast(@alignCast(prop.bytes.ptr));
        return @truncate(values[0]);
    }

    pub fn readWindowProperty(ctx: *const Context, window: c.Window, atom: c.Atom) !?c.Window {
        const prop = try ctx.getProperty(window, atom, 0, 1, c.XA_WINDOW, 32) orelse return null;
        defer prop.deinit();
        const values: [*]const c_ulong = @ptrCast(@alignCast(prop.bytes.ptr));
        return values[0];
    }

    pub fn readWindowListProperty(ctx: *const Context, window: c.Window, atom: c.Atom) !?[]c.Window {
        const prop = try ctx.getProperty(window, atom, 0, 4096, c.XA_WINDOW, 32) orelse return null;
        defer prop.deinit();
        const values: [*]const c_ulong = @ptrCast(@alignCast(prop.bytes.ptr));
        const owned = try ctx.allocator.alloc(c.Window, prop.nitems);
        for (owned, 0..) |*dst, idx| dst.* = values[idx];
        return owned;
    }

    pub fn readPropertyBytesInto(ctx: *const Context, dst: []u8, window: c.Window, atom: c.Atom, expected_type: c.Atom) !?[]const u8 {
        const prop = try ctx.getProperty(window, atom, 0, 4096, expected_type, 8) orelse return null;
        defer prop.deinit();
        const len = @min(dst.len, prop.bytes.len);
        @memcpy(dst[0..len], prop.bytes[0..len]);
        return dst[0..len];
    }

    pub fn hasAtomProperty(ctx: *const Context, window: c.Window, property_atom: c.Atom, expected_atom: c.Atom) !bool {
        const prop = try ctx.getProperty(window, property_atom, 0, 32, c.XA_ATOM, 32) orelse return false;
        defer prop.deinit();
        const values: [*]const c_ulong = @ptrCast(@alignCast(prop.bytes.ptr));
        for (0..prop.nitems) |idx| {
            if (values[idx] == expected_atom) return true;
        }
        return false;
    }

    pub fn subscribeClientWindow(ctx: *const Context, window: c.Window) void {
        _ = c.XSelectInput(ctx.gfx.display, window, c.PropertyChangeMask | c.StructureNotifyMask);
    }

    pub fn setCurrentDesktop(ctx: *const Context, index: u32) void {
        var event = std.mem.zeroes(c.XEvent);
        event.xclient.type = c.ClientMessage;
        event.xclient.window = ctx.gfx.root;
        event.xclient.message_type = ctx.gfx.atoms.net_current_desktop;
        event.xclient.format = 32;
        event.xclient.data.l[0] = index;
        event.xclient.data.l[1] = c.CurrentTime;
        _ = c.XSendEvent(ctx.gfx.display, ctx.gfx.root, c.False, c.SubstructureRedirectMask | c.SubstructureNotifyMask, &event);
        _ = c.XFlush(ctx.gfx.display);
    }

    pub fn activateWindow(ctx: *const Context, window: c.Window) void {
        var event = std.mem.zeroes(c.XEvent);
        event.xclient.type = c.ClientMessage;
        event.xclient.window = window;
        event.xclient.message_type = ctx.gfx.atoms.net_active_window;
        event.xclient.format = 32;
        event.xclient.data.l[0] = 1;
        event.xclient.data.l[1] = c.CurrentTime;
        event.xclient.data.l[2] = 0;
        _ = c.XSendEvent(ctx.gfx.display, ctx.gfx.root, c.False, c.SubstructureRedirectMask | c.SubstructureNotifyMask, &event);
        _ = c.XFlush(ctx.gfx.display);
    }

    const PropertyData = struct {
        actual_type: c.Atom,
        actual_format: c_int,
        nitems: usize,
        bytes: []const u8,
        raw_prop: [*c]u8,

        fn deinit(self: @This()) void {
            if (self.raw_prop != null) _ = c.XFree(self.raw_prop);
        }
    };

    fn getProperty(ctx: *const Context, window: c.Window, atom: c.Atom, long_offset: c_long, long_length: c_long, req_type: c.Atom, req_format: c_int) !?PropertyData {
        var actual_type: c.Atom = 0;
        var actual_format: c_int = 0;
        var nitems: c_ulong = 0;
        var bytes_after: c_ulong = 0;
        var prop: [*c]u8 = null;
        if (c.XGetWindowProperty(ctx.gfx.display, window, atom, long_offset, long_length, c.False, req_type, &actual_type, &actual_format, &nitems, &bytes_after, &prop) != c.Success) return null;
        if (nitems == 0 or prop == null or actual_format != req_format) {
            if (prop != null) _ = c.XFree(prop);
            return null;
        }
        const len = switch (req_format) {
            8 => @as(usize, @intCast(nitems)),
            16 => @as(usize, @intCast(nitems)) * 2,
            32 => @as(usize, @intCast(nitems)) * @sizeOf(c_ulong),
            else => 0,
        };
        if (len == 0) {
            _ = c.XFree(prop);
            return null;
        }
        return .{
            .actual_type = actual_type,
            .actual_format = actual_format,
            .nitems = @intCast(nitems),
            .bytes = @as([*]const u8, @ptrCast(prop))[0..len],
            .raw_prop = prop,
        };
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
