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

pub const ResolvedStyle = struct {
    font: cfg.Font,
    bg: u32,
    text: u32,
    active_bg: u32,
    active_text: u32,
    padding: i32,
    text_offset: i32,
};

pub const Gfx = struct {
    display: *c.Display,
    screen_num: c_int,
    root: c.Window,
    window: c.Window,
    gc: c.GC,
    visual: ?*c.Visual,
    colormap: c.Colormap,
    xft_draw: *c.XftDraw,
    atoms: x11.Atoms,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    config: *const cfg.Config,
    gfx: Gfx,

    pub fn panelWidth(ctx: *const Context) i32 {
        return c.XDisplayWidth(ctx.gfx.display, ctx.gfx.screen_num);
    }

    pub fn openFont(ctx: *const Context, font: cfg.Font) !*c.XftFont {
        var buffer: [256]u8 = undefined;
        const name = try std.fmt.bufPrint(&buffer, "{s}-{d}", .{ font.name, font.size });
        return c.XftFontOpenName(ctx.gfx.display, ctx.gfx.screen_num, name.ptr) orelse return error.XftFontOpenFailed;
    }

    pub fn fillRect(ctx: *const Context, color: u32, rect: Rect) void {
        _ = c.XSetForeground(ctx.gfx.display, ctx.gfx.gc, color);
        _ = c.XFillRectangle(ctx.gfx.display, ctx.gfx.window, ctx.gfx.gc, @intCast(rect.x), @intCast(rect.y), @intCast(rect.width), @intCast(rect.height));
    }

    pub fn textBaseline(ctx: *const Context, font: *c.XftFont) i32 {
        const text_height = font.ascent + font.descent;
        return @divFloor(ctx.config.height - text_height, 2) + font.ascent;
    }

    pub fn measureText(ctx: *const Context, font: *c.XftFont, text: []const u8) i32 {
        if (text.len == 0) return 0;
        var extents: c.XGlyphInfo = undefined;
        c.XftTextExtentsUtf8(ctx.gfx.display, font, text.ptr, @intCast(text.len), &extents);
        return extents.xOff;
    }

    pub fn textItemWidth(ctx: *const Context, font: *c.XftFont, text: []const u8, padding: i32) i32 {
        return ctx.measureText(font, text) + padding * 2;
    }

    pub fn fitText(ctx: *const Context, font: *c.XftFont, text: []const u8, max_width: i32) []const u8 {
        if (ctx.measureText(font, text) <= max_width) return text;
        var end = text.len;
        while (end > 0) : (end -= 1) {
            const candidate = text[0..end];
            if (ctx.measureText(font, candidate) <= max_width) return candidate;
        }
        return "";
    }

    pub fn drawText(ctx: *const Context, font: *c.XftFont, fallback_font: *c.XftFont, color_rgb: u32, x: i32, baseline_y: i32, text: []const u8) void {
        if (text.len == 0) return;
        var color: c.XftColor = undefined;
        defer c.XftColorFree(ctx.gfx.display, ctx.gfx.visual, ctx.gfx.colormap, &color);
        var value = c.XRenderColor{
            .red = @intCast(((color_rgb >> 16) & 0xff) * 257),
            .green = @intCast(((color_rgb >> 8) & 0xff) * 257),
            .blue = @intCast((color_rgb & 0xff) * 257),
            .alpha = 0xffff,
        };
        if (c.XftColorAllocValue(ctx.gfx.display, ctx.gfx.visual, ctx.gfx.colormap, &value, &color) == 0) return;

        var draw_x = x;
        var utf8 = std.unicode.Utf8View.init(text) catch return;
        var iter = utf8.iterator();
        while (iter.nextCodepointSlice()) |slice| {
            const draw_font = if (c.XftCharExists(ctx.gfx.display, font, tryDecodeCodepoint(slice)) != 0) font else fallback_font;
            c.XftDrawStringUtf8(ctx.gfx.xft_draw, &color, draw_font, draw_x, baseline_y, slice.ptr, @intCast(slice.len));
            draw_x += ctx.measureText(draw_font, slice);
        }
    }

    pub fn readWindowTitle(ctx: *const Context, window: c.Window) !?[]u8 {
        if (try ctx.readPropertyBytes(window, ctx.gfx.atoms.net_wm_name, ctx.gfx.atoms.utf8_string)) |title| return title;
        return try ctx.readPropertyBytesAny(window, ctx.gfx.atoms.wm_name);
    }

    pub fn readCardinalProperty(ctx: *const Context, window: c.Window, atom: c.Atom) !?u32 {
        var actual_type: c.Atom = 0;
        var actual_format: c_int = 0;
        var nitems: c_ulong = 0;
        var bytes_after: c_ulong = 0;
        var prop: [*c]u8 = null;
        if (c.XGetWindowProperty(ctx.gfx.display, window, atom, 0, 1, c.False, c.XA_CARDINAL, &actual_type, &actual_format, &nitems, &bytes_after, &prop) != c.Success) return null;
        defer {
            if (prop != null) _ = c.XFree(prop);
        }
        if (nitems == 0 or actual_format != 32 or prop == null) return null;
        const values: [*]c_ulong = @ptrCast(@alignCast(prop));
        return @truncate(values[0]);
    }

    pub fn readWindowProperty(ctx: *const Context, window: c.Window, atom: c.Atom) !?c.Window {
        var actual_type: c.Atom = 0;
        var actual_format: c_int = 0;
        var nitems: c_ulong = 0;
        var bytes_after: c_ulong = 0;
        var prop: [*c]u8 = null;
        if (c.XGetWindowProperty(ctx.gfx.display, window, atom, 0, 1, c.False, c.XA_WINDOW, &actual_type, &actual_format, &nitems, &bytes_after, &prop) != c.Success) return null;
        defer {
            if (prop != null) _ = c.XFree(prop);
        }
        if (nitems == 0 or actual_format != 32 or prop == null) return null;
        const values: [*]c_ulong = @ptrCast(@alignCast(prop));
        return values[0];
    }

    pub fn readWindowListProperty(ctx: *const Context, window: c.Window, atom: c.Atom) !?[]c.Window {
        var actual_type: c.Atom = 0;
        var actual_format: c_int = 0;
        var nitems: c_ulong = 0;
        var bytes_after: c_ulong = 0;
        var prop: [*c]u8 = null;
        if (c.XGetWindowProperty(ctx.gfx.display, window, atom, 0, 4096, c.False, c.XA_WINDOW, &actual_type, &actual_format, &nitems, &bytes_after, &prop) != c.Success) return null;
        defer {
            if (prop != null) _ = c.XFree(prop);
        }
        if (nitems == 0 or actual_format != 32 or prop == null) return null;
        const values: [*]c_ulong = @ptrCast(@alignCast(prop));
        const owned = try ctx.allocator.alloc(c.Window, @intCast(nitems));
        for (owned, 0..) |*dst, idx| dst.* = values[idx];
        return owned;
    }

    pub fn readPropertyBytes(ctx: *const Context, window: c.Window, atom: c.Atom, expected_type: c.Atom) !?[]u8 {
        var actual_type: c.Atom = 0;
        var actual_format: c_int = 0;
        var nitems: c_ulong = 0;
        var bytes_after: c_ulong = 0;
        var prop: [*c]u8 = null;
        if (c.XGetWindowProperty(ctx.gfx.display, window, atom, 0, 4096, c.False, expected_type, &actual_type, &actual_format, &nitems, &bytes_after, &prop) != c.Success) return null;
        defer {
            if (prop != null) _ = c.XFree(prop);
        }
        if (nitems == 0 or actual_format != 8 or prop == null) return null;
        const raw: [*]const u8 = @ptrCast(prop);
        return try ctx.allocator.dupe(u8, raw[0..@intCast(nitems)]);
    }

    pub fn readPropertyBytesAny(ctx: *const Context, window: c.Window, atom: c.Atom) !?[]u8 {
        var actual_type: c.Atom = 0;
        var actual_format: c_int = 0;
        var nitems: c_ulong = 0;
        var bytes_after: c_ulong = 0;
        var prop: [*c]u8 = null;
        if (c.XGetWindowProperty(ctx.gfx.display, window, atom, 0, 4096, c.False, c.AnyPropertyType, &actual_type, &actual_format, &nitems, &bytes_after, &prop) != c.Success) return null;
        defer {
            if (prop != null) _ = c.XFree(prop);
        }
        if (nitems == 0 or actual_format != 8 or prop == null) return null;
        const raw: [*]const u8 = @ptrCast(prop);
        return try ctx.allocator.dupe(u8, raw[0..@intCast(nitems)]);
    }

    pub fn hasAtomProperty(ctx: *const Context, window: c.Window, property_atom: c.Atom, expected_atom: c.Atom) !bool {
        var actual_type: c.Atom = 0;
        var actual_format: c_int = 0;
        var nitems: c_ulong = 0;
        var bytes_after: c_ulong = 0;
        var prop: [*c]u8 = null;
        if (c.XGetWindowProperty(ctx.gfx.display, window, property_atom, 0, 32, c.False, c.XA_ATOM, &actual_type, &actual_format, &nitems, &bytes_after, &prop) != c.Success) return false;
        defer {
            if (prop != null) _ = c.XFree(prop);
        }
        if (nitems == 0 or actual_format != 32 or prop == null) return false;
        const values: [*]c_ulong = @ptrCast(@alignCast(prop));
        for (0..@intCast(nitems)) |idx| {
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
};

pub fn resolveStyle(base: cfg.Style, override: cfg.StyleOverride) ResolvedStyle {
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

fn tryDecodeCodepoint(slice: []const u8) c.FcChar32 {
    return @intCast(std.unicode.utf8Decode(slice) catch 0xfffd);
}
