const std = @import("std");
const cfg = @import("../config.zig");
const common = @import("common.zig");
const pager_mod = @import("pager.zig");
const taskbar_mod = @import("taskbar.zig");
const tray_mod = @import("tray.zig");
const clock_mod = @import("clock.zig");
const x11 = @import("../x11.zig");
const c = x11.c;

pub const Widget = union(enum) {
    pager: pager_mod.Pager,
    taskbar: taskbar_mod.Taskbar,
    tray: tray_mod.Tray,
    clock: clock_mod.Clock,

    pub fn initFromConfig(ctx: *const common.Context, base_style: cfg.Style, widget_cfg: cfg.Widget) !Widget {
        return switch (widget_cfg) {
            .pager => |v| .{ .pager = try pager_mod.Pager.init(ctx, base_style, v) },
            .taskbar => |v| .{ .taskbar = try taskbar_mod.Taskbar.init(ctx, base_style, v) },
            .tray => |v| .{ .tray = tray_mod.Tray.init(ctx, base_style, v) },
            .clock => |v| .{ .clock = try clock_mod.Clock.init(ctx, base_style, v) },
        };
    }

    pub fn deinit(self: *Widget, ctx: *const common.Context) void {
        switch (self.*) {
            .pager => |*w| w.deinit(ctx),
            .taskbar => |*w| w.deinit(ctx),
            .tray => |*w| w.deinit(),
            .clock => |*w| w.deinit(ctx),
        }
    }

    pub fn refresh(self: *Widget, ctx: *const common.Context) !void {
        switch (self.*) {
            .pager => |*w| try w.refresh(ctx),
            .taskbar => |*w| try w.refresh(ctx),
            .tray => |*w| w.refresh(ctx),
            .clock => |*w| w.refresh(ctx),
        }
    }

    pub fn claimSelection(self: *Widget, ctx: *const common.Context) !void {
        switch (self.*) {
            .tray => |*w| try w.claimSelection(ctx),
            else => {},
        }
    }

    pub fn measure(self: *Widget, ctx: *const common.Context) i32 {
        return switch (self.*) {
            .pager => |*w| w.measure(ctx),
            .taskbar => |*w| w.measure(ctx),
            .tray => |*w| w.measure(ctx),
            .clock => |*w| w.measure(ctx),
        };
    }

    pub fn draw(self: *Widget, ctx: *const common.Context, rect: common.Rect) void {
        switch (self.*) {
            .pager => |*w| w.draw(ctx, rect),
            .taskbar => |*w| w.draw(ctx, rect),
            .tray => |*w| w.draw(ctx, rect),
            .clock => |*w| w.draw(ctx, rect),
        }
    }

    pub fn click(self: *Widget, ctx: *const common.Context, rect: common.Rect, x: i32, y: i32) common.Update {
        switch (self.*) {
            .pager => |*w| _ = w.click(ctx, rect, x, y),
            .taskbar => |*w| _ = w.click(ctx, rect, x, y),
            else => {},
        }
        return .{};
    }

    pub fn handleEvent(self: *Widget, ctx: *const common.Context, rect: common.Rect, event: *const c.XEvent) !common.Update {
        return switch (self.*) {
            .pager => |*w| try w.handleEvent(ctx, event),
            .taskbar => |*w| try w.handleEvent(ctx, event),
            .tray => |*w| try w.handleEvent(ctx, rect, event),
            .clock => |*w| w.handleEvent(ctx, event),
        };
    }

    pub fn tick(self: *Widget, ctx: *const common.Context) common.Update {
        return switch (self.*) {
            .clock => |*w| w.tick(ctx),
            else => .{},
        };
    }
};
