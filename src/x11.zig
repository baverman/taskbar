const std = @import("std");

pub const c = @cImport({
    @cInclude("poll.h");
    @cInclude("time.h");
    @cInclude("X11/Xatom.h");
    @cInclude("X11/Xlib-xcb.h");
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
    @cInclude("cairo/cairo-xlib.h");
    @cInclude("pango/pangocairo.h");
});

pub const Atoms = struct {
    manager: c.Atom,
    net_active_window: c.Atom,
    net_client_list: c.Atom,
    net_client_list_stacking: c.Atom,
    net_current_desktop: c.Atom,
    net_desktop_names: c.Atom,
    net_number_of_desktops: c.Atom,
    net_system_tray_opcode: c.Atom,
    net_system_tray_s0: c.Atom,
    net_wm_desktop: c.Atom,
    net_wm_icon_name: c.Atom,
    net_wm_name: c.Atom,
    net_wm_state: c.Atom,
    net_wm_state_skip_taskbar: c.Atom,
    net_wm_state_sticky: c.Atom,
    net_wm_strut: c.Atom,
    net_wm_strut_partial: c.Atom,
    net_wm_window_type: c.Atom,
    net_wm_window_type_dock: c.Atom,
    utf8_string: c.Atom,
    wm_class: c.Atom,
    wm_name: c.Atom,
    xembed: c.Atom,
    xembed_info: c.Atom,
};

pub const DesktopNameIter = struct {
    bytes: []const u8,
    pos: usize,

    pub fn init(bytes: []const u8) DesktopNameIter {
        return .{ .bytes = bytes, .pos = 0 };
    }

    pub fn next(iter: *DesktopNameIter) ?[]const u8 {
        if (iter.pos >= iter.bytes.len) return null;
        const start = iter.pos;
        while (iter.pos < iter.bytes.len and iter.bytes[iter.pos] != 0) : (iter.pos += 1) {}
        const name = iter.bytes[start..iter.pos];
        if (iter.pos < iter.bytes.len) iter.pos += 1;
        return name;
    }
};

pub fn internAtom(display: *c.Display, name: [:0]const u8) c.Atom {
    return c.XInternAtom(display, name.ptr, c.False);
}

pub fn internAtoms(display: *c.Display) Atoms {
    return .{
        .manager = internAtom(display, "MANAGER"),
        .net_active_window = internAtom(display, "_NET_ACTIVE_WINDOW"),
        .net_client_list = internAtom(display, "_NET_CLIENT_LIST"),
        .net_client_list_stacking = internAtom(display, "_NET_CLIENT_LIST_STACKING"),
        .net_current_desktop = internAtom(display, "_NET_CURRENT_DESKTOP"),
        .net_desktop_names = internAtom(display, "_NET_DESKTOP_NAMES"),
        .net_number_of_desktops = internAtom(display, "_NET_NUMBER_OF_DESKTOPS"),
        .net_system_tray_opcode = internAtom(display, "_NET_SYSTEM_TRAY_OPCODE"),
        .net_system_tray_s0 = internAtom(display, "_NET_SYSTEM_TRAY_S0"),
        .net_wm_desktop = internAtom(display, "_NET_WM_DESKTOP"),
        .net_wm_icon_name = internAtom(display, "_NET_WM_ICON_NAME"),
        .net_wm_name = internAtom(display, "_NET_WM_NAME"),
        .net_wm_state = internAtom(display, "_NET_WM_STATE"),
        .net_wm_state_skip_taskbar = internAtom(display, "_NET_WM_STATE_SKIP_TASKBAR"),
        .net_wm_state_sticky = internAtom(display, "_NET_WM_STATE_STICKY"),
        .net_wm_strut = internAtom(display, "_NET_WM_STRUT"),
        .net_wm_strut_partial = internAtom(display, "_NET_WM_STRUT_PARTIAL"),
        .net_wm_window_type_dock = internAtom(display, "_NET_WM_WINDOW_TYPE_DOCK"),
        .net_wm_window_type = internAtom(display, "_NET_WM_WINDOW_TYPE"),
        .utf8_string = internAtom(display, "UTF8_STRING"),
        .wm_class = internAtom(display, "WM_CLASS"),
        .wm_name = internAtom(display, "WM_NAME"),
        .xembed_info = internAtom(display, "_XEMBED_INFO"),
        .xembed = internAtom(display, "_XEMBED"),
    };
}

pub fn sendClientMessage(display: *c.Display, target: c.Window, window: c.Window, message_type: c.Atom, event_mask: c_long, data: [5]c_long) void {
    var event = std.mem.zeroes(c.XEvent);
    event.xclient.type = c.ClientMessage;
    event.xclient.window = window;
    event.xclient.message_type = message_type;
    event.xclient.format = 32;
    event.xclient.data.l = data;
    _ = c.XSendEvent(display, target, c.False, event_mask, &event);
}
