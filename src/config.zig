pub const Font = struct {
    name: []const u8,
    size: i32,
};

pub const Style = struct {
    font: Font,
    bg: u32,
    text: u32,
    active_bg: u32,
    active_text: u32,
    padding: i32,
    text_offset: i32,
};

pub const StyleOverride = struct {
    font: ?Font = null,
    bg: ?u32 = null,
    text: ?u32 = null,
    active_bg: ?u32 = null,
    active_text: ?u32 = null,
    padding: ?i32 = null,
    text_offset: ?i32 = null,
};

pub const Width = union(enum) {
    min_content,
    fixed: i32,
    flex,
};

pub const Align = enum {
    left,
    center,
    right,
};

pub const Pager = struct {
    style: StyleOverride = .{},
    width: Width = .min_content,
};

pub const Taskbar = struct {
    style: StyleOverride = .{},
    width: Width = .flex,
    max_item_width: ?i32 = null,
};

pub const Tray = struct {
    style: StyleOverride = .{},
    width: Width = .min_content,
    item_gap: i32 = 2,
};

pub const Clock = struct {
    style: StyleOverride = .{},
    width: Width = .{ .fixed = 64 },
    text_align: Align = .right,
    format: []const u8 = "%H:%M",
};

pub const Widget = union(enum) {
    pager: Pager,
    taskbar: Taskbar,
    tray: Tray,
    clock: Clock,
};

pub const Config = struct {
    height: i32,
    gap: i32,
    style: Style,
    widgets: []const Widget,
};

pub const config = Config{
    .height = 29,
    .gap = 8,
    .style = .{
        .font = .{
            .name = "InputUI Sans Compressed",
            .size = 15,
        },
        .bg = 0x222222,
        .text = 0xaaaaaa,
        .active_bg = 0x535d6c,
        .active_text = 0xffffff,
        .padding = 6,
        .text_offset = -1,
    },
    .widgets = &.{
        .{ .pager = .{} },
        .{ .taskbar = .{
            .max_item_width = 500,
        } },
        .{ .tray = .{} },
        .{ .clock = .{} },
    },
};
