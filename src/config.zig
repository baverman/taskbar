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
    width: Width = .{ .fixed = 70 },
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

pub fn load(allocator: std.mem.Allocator) !Config {
    const path = try findConfigPath(allocator);
    const config_path = path orelse return defaultConfig();
    defer allocator.free(config_path);

    const file = try std.fs.openFileAbsolute(config_path, .{});
    defer file.close();

    const source = try file.readToEndAllocOptions(
        allocator,
        std.math.maxInt(usize),
        null,
        .of(u8),
        0,
    );

    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(allocator);

    return std.zon.parse.fromSlice(Config, allocator, source, &diag, .{
        .free_on_error = false,
    }) catch |err| switch (err) {
        error.ParseZon => {
            printParseError(config_path, &diag);
            return error.ParseZon;
        },
        else => return err,
    };
}

fn findConfigPath(allocator: std.mem.Allocator) !?[]const u8 {
    if (try xdgConfigPath(allocator)) |path| {
        if (try fileExists(path)) return path;
        allocator.free(path);
    }

    if (try homeConfigPath(allocator)) |path| {
        if (try fileExists(path)) return path;
        allocator.free(path);
    }

    return null;
}

fn xdgConfigPath(allocator: std.mem.Allocator) !?[]const u8 {
    const xdg = std.posix.getenv("XDG_CONFIG_HOME") orelse return null;

    return try std.fs.path.join(allocator, &.{ xdg, "taskbar.zon" });
}

fn homeConfigPath(allocator: std.mem.Allocator) !?[]const u8 {
    const home = std.posix.getenv("HOME") orelse return null;

    return try std.fs.path.join(allocator, &.{ home, ".config", "taskbar.zon" });
}

fn fileExists(path: []const u8) !bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    file.close();
    return true;
}

fn printParseError(path: []const u8, diag: *const std.zon.parse.Diagnostics) void {
    std.debug.print("failed to parse config {s}\n", .{path});

    var buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buffer);
    const writer = &stderr_writer.interface;
    diag.format(writer) catch {};
    writer.flush() catch {};
}
