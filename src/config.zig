const std = @import("std");

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
    margin_left: i32 = 0,
    margin_right: i32 = 0,
};

pub const Taskbar = struct {
    style: StyleOverride = .{},
    width: Width = .flex,
    max_item_width: ?i32 = null,
    margin_left: i32 = 0,
    margin_right: i32 = 0,
};

pub const Tray = struct {
    style: StyleOverride = .{},
    width: Width = .min_content,
    margin_left: i32 = 0,
    margin_right: i32 = 0,
    icon_size: ?i32 = null,
    item_gap: i32 = 2,
};

pub const Clock = struct {
    style: StyleOverride = .{},
    width: Width = .min_content,
    margin_left: i32 = 0,
    margin_right: i32 = 0,
    text_align: Align = .right,
    format: [:0]const u8 = "%H:%M",
};

pub const Widget = union(enum) {
    pager: Pager,
    taskbar: Taskbar,
    tray: Tray,
    clock: Clock,
};

pub const Config = struct {
    height: i32,
    style: Style,
    widgets: []const Widget,
};

pub fn defaultConfig() Config {
    return .{
        .height = 29,
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
            .{ .pager = .{
                .margin_right = 8,
            } },
            .{ .taskbar = .{
                .max_item_width = 500,
                .margin_right = 8,
            } },
            .{ .tray = .{
                .icon_size = 22,
            } },
            .{ .clock = .{
                .margin_right = 4,
            } },
        },
    };
}

pub fn load(allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) !Config {
    var scratch_mem: [16 * 1024]u8 = undefined;
    var scratch_fba = std.heap.FixedBufferAllocator.init(&scratch_mem);
    const scratch = scratch_fba.allocator();

    const path = try findConfigPath(scratch, environ_map);
    const config_path = path orelse return defaultConfig();

    var source_buf: [64 * 1024:0]u8 = undefined;
    const source = std.Io.Dir.cwd().readFile(io, config_path, source_buf[0..]) catch |err| switch (err) {
        error.FileNotFound => return defaultConfig(),
        else => return err,
    };
    source_buf[source.len] = 0;
    const source_z: [:0]u8 = source_buf[0..source.len :0];

    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(allocator);

    return std.zon.parse.fromSliceAlloc(Config, allocator, source_z, &diag, .{
        .free_on_error = false,
    }) catch |err| switch (err) {
        error.ParseZon => {
            std.debug.print("failed to parse config {s}\n", .{config_path});
            var stderr = std.debug.lockStderr(&.{}).file_writer.interface;
            defer std.debug.unlockStderr();
            diag.format(&stderr) catch {};
            return error.ParseZon;
        },
        else => return err,
    };
}

fn findConfigPath(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) !?[]const u8 {
    if (environ_map.get("XDG_CONFIG_HOME")) |xdg| {
        return try std.fs.path.join(allocator, &.{ xdg, "taskbar.zon" });
    }
    if (environ_map.get("HOME")) |home| {
        return try std.fs.path.join(allocator, &.{ home, ".config", "taskbar.zon" });
    }
    return null;
}
