const std = @import("std");
pub const z = @import("zix11");
pub const x = z.xproto;
pub const shm = z.shm;

pub const c = @import("c");

pub const Atoms = enum {
    MANAGER,
    _NET_ACTIVE_WINDOW,
    _NET_CLIENT_LIST,
    _NET_CURRENT_DESKTOP,
    _NET_DESKTOP_NAMES,
    _NET_NUMBER_OF_DESKTOPS,
    _NET_SYSTEM_TRAY_OPCODE,
    _NET_SYSTEM_TRAY_S0,
    _NET_WM_DESKTOP,
    _NET_WM_ICON_NAME,
    _NET_WM_NAME,
    _NET_WM_STATE,
    _NET_WM_STATE_SKIP_TASKBAR,
    _NET_WM_STRUT,
    _NET_WM_STRUT_PARTIAL,
    _NET_WM_WINDOW_TYPE,
    _NET_WM_WINDOW_TYPE_DOCK,
    UTF8_STRING,
    WM_CLASS,
    WM_NAME,
    WM_NORMAL_HINTS,
    WM_SIZE_HINTS,
    _XEMBED,
    _XEMBED_INFO,
};

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
