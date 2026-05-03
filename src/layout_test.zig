const std = @import("std");
const cfg = @import("config.zig");
const layout = @import("layout.zig");
const common = @import("widgets/common.zig");

fn testContext(config: *const cfg.Config) common.Context {
    return .{
        .allocator = undefined,
        .config = config,
        .gfx = undefined,
    };
}

fn testItem(widget_cfg: cfg.Widget) layout.LayoutItem {
    return .{
        .widget = .{ .clock = undefined },
        .config = widget_cfg,
        .rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .dirty = false,
    };
}

test "fixed items respect margins" {
    const config = cfg.Config{
        .height = 29,
        .style = cfg.defaultConfig().style,
        .widgets = &.{},
    };
    var ctx = testContext(&config);
    var items = [_]layout.LayoutItem{
        testItem(.{ .clock = .{ .width = .{ .fixed = 20 }, .margin_left = 2, .margin_right = 3 } }),
        testItem(.{ .clock = .{ .width = .{ .fixed = 10 }, .margin_left = 4, .margin_right = 1 } }),
    };

    layout.relayout(&ctx, 100, &items);

    try std.testing.expect(items[0].dirty);
    try std.testing.expectEqual(common.Rect{ .x = 2, .y = 0, .width = 20, .height = 29 }, items[0].rect);
    try std.testing.expectEqual(common.Rect{ .x = 29, .y = 0, .width = 10, .height = 29 }, items[1].rect);
}

test "flex item consumes remaining width and shifts following items" {
    const config = cfg.Config{
        .height = 29,
        .style = cfg.defaultConfig().style,
        .widgets = &.{},
    };
    var ctx = testContext(&config);
    var items = [_]layout.LayoutItem{
        testItem(.{ .clock = .{ .width = .{ .fixed = 20 }, .margin_right = 5 } }),
        testItem(.{ .taskbar = .{ .width = .flex, .margin_left = 3, .margin_right = 7 } }),
        testItem(.{ .clock = .{ .width = .{ .fixed = 15 }, .margin_left = 2 } }),
    };

    layout.relayout(&ctx, 100, &items);

    try std.testing.expectEqual(common.Rect{ .x = 0, .y = 0, .width = 20, .height = 29 }, items[0].rect);
    try std.testing.expectEqual(common.Rect{ .x = 28, .y = 0, .width = 48, .height = 29 }, items[1].rect);
    try std.testing.expectEqual(common.Rect{ .x = 85, .y = 0, .width = 15, .height = 29 }, items[2].rect);
}

test "zero width fixed item does not consume margins" {
    const config = cfg.Config{
        .height = 31,
        .style = cfg.defaultConfig().style,
        .widgets = &.{},
    };
    var ctx = testContext(&config);
    var items = [_]layout.LayoutItem{
        testItem(.{ .clock = .{ .width = .{ .fixed = 0 }, .margin_left = 10, .margin_right = 10 } }),
        testItem(.{ .clock = .{ .width = .{ .fixed = 20 } } }),
    };

    layout.relayout(&ctx, 70, &items);

    try std.testing.expectEqual(common.Rect{ .x = 0, .y = 0, .width = 0, .height = 31 }, items[0].rect);
    try std.testing.expectEqual(common.Rect{ .x = 0, .y = 0, .width = 20, .height = 31 }, items[1].rect);
}

test "last flex wins" {
    const config = cfg.Config{
        .height = 29,
        .style = cfg.defaultConfig().style,
        .widgets = &.{},
    };
    var ctx = testContext(&config);
    var items = [_]layout.LayoutItem{
        testItem(.{ .taskbar = .{ .width = .flex } }),
        testItem(.{ .taskbar = .{ .width = .flex } }),
    };

    layout.relayout(&ctx, 100, &items);

    try std.testing.expectEqual(common.Rect{ .x = 0, .y = 0, .width = 0, .height = 29 }, items[0].rect);
    try std.testing.expectEqual(common.Rect{ .x = 0, .y = 0, .width = 100, .height = 29 }, items[1].rect);
}
