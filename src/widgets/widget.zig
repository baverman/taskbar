const cfg = @import("../config.zig");
const common = @import("common.zig");
const pager_mod = @import("pager.zig");
const taskbar_mod = @import("taskbar.zig");
const tray_mod = @import("tray.zig");
const clock_mod = @import("clock.zig");

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
            inline else => |*w| w.deinit(ctx),
        }
    }
};
