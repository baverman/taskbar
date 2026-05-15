const std = @import("std");
pub const z = @import("zix11");
pub const x = z.xproto;
pub const shm = z.shm;

pub const c = @import("c");

pub const Atoms = struct {
    manager: x.Atom,
    net_active_window: x.Atom,
    net_client_list: x.Atom,
    net_current_desktop: x.Atom,
    net_desktop_names: x.Atom,
    net_number_of_desktops: x.Atom,
    net_system_tray_opcode: x.Atom,
    net_system_tray_s0: x.Atom,
    net_wm_desktop: x.Atom,
    net_wm_icon_name: x.Atom,
    net_wm_name: x.Atom,
    net_wm_state: x.Atom,
    net_wm_state_skip_taskbar: x.Atom,
    net_wm_state_sticky: x.Atom,
    net_wm_strut: x.Atom,
    net_wm_strut_partial: x.Atom,
    net_wm_window_type: x.Atom,
    net_wm_window_type_dock: x.Atom,
    utf8_string: x.Atom,
    wm_class: x.Atom,
    wm_name: x.Atom,
    wm_normal_hints: x.Atom,
    wm_size_hints: x.Atom,
    xembed: x.Atom,
    xembed_info: x.Atom,
};

pub fn internAtoms(conn: *z.Connection) !Atoms {
    return .{
        .manager = try z.internAtom(conn, "MANAGER", false),
        .net_active_window = try z.internAtom(conn, "_NET_ACTIVE_WINDOW", false),
        .net_client_list = try z.internAtom(conn, "_NET_CLIENT_LIST", false),
        .net_current_desktop = try z.internAtom(conn, "_NET_CURRENT_DESKTOP", false),
        .net_desktop_names = try z.internAtom(conn, "_NET_DESKTOP_NAMES", false),
        .net_number_of_desktops = try z.internAtom(conn, "_NET_NUMBER_OF_DESKTOPS", false),
        .net_system_tray_opcode = try z.internAtom(conn, "_NET_SYSTEM_TRAY_OPCODE", false),
        .net_system_tray_s0 = try z.internAtom(conn, "_NET_SYSTEM_TRAY_S0", false),
        .net_wm_desktop = try z.internAtom(conn, "_NET_WM_DESKTOP", false),
        .net_wm_icon_name = try z.internAtom(conn, "_NET_WM_ICON_NAME", false),
        .net_wm_name = try z.internAtom(conn, "_NET_WM_NAME", false),
        .net_wm_state = try z.internAtom(conn, "_NET_WM_STATE", false),
        .net_wm_state_skip_taskbar = try z.internAtom(conn, "_NET_WM_STATE_SKIP_TASKBAR", false),
        .net_wm_state_sticky = try z.internAtom(conn, "_NET_WM_STATE_STICKY", false),
        .net_wm_strut = try z.internAtom(conn, "_NET_WM_STRUT", false),
        .net_wm_strut_partial = try z.internAtom(conn, "_NET_WM_STRUT_PARTIAL", false),
        .net_wm_window_type_dock = try z.internAtom(conn, "_NET_WM_WINDOW_TYPE_DOCK", false),
        .net_wm_window_type = try z.internAtom(conn, "_NET_WM_WINDOW_TYPE", false),
        .utf8_string = try z.internAtom(conn, "UTF8_STRING", false),
        .wm_class = try z.internAtom(conn, "WM_CLASS", false),
        .wm_name = try z.internAtom(conn, "WM_NAME", false),
        .wm_normal_hints = try z.internAtom(conn, "WM_NORMAL_HINTS", false),
        .wm_size_hints = try z.internAtom(conn, "WM_SIZE_HINTS", false),
        .xembed_info = try z.internAtom(conn, "_XEMBED_INFO", false),
        .xembed = try z.internAtom(conn, "_XEMBED", false),
    };
}

pub fn sendClientMessage(
    conn: *z.Connection,
    target: x.Window,
    window: x.Window,
    message_type: x.Atom,
    event_mask: u32,
    data: []const u32,
) !void {
    const event = x.ClientMessageEvent{
        .format = 32,
        .window = window,
        .type = message_type,
        .data = z.clientMessageData(u32, data),
    };
    try conn.request(x.SendEvent, .{
        .propagate = false,
        .destination = target,
        .event_mask = event_mask,
        .event = try event.toBytes(),
    });
}

pub fn clientMessageDataU32(event: *const x.ClientMessageEvent, index: usize) u32 {
    std.debug.assert(index < 5);
    const word_start = index * @sizeOf(u32);
    const word_bytes = event.data.raw[word_start..][0..@sizeOf(u32)];
    return std.mem.readInt(u32, word_bytes, .little);
}
