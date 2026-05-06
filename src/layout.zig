const common = @import("widgets/common.zig");

pub fn relayout(ctx: *const common.Context, total_width: i32, items: anytype) void {
    var flex_index: ?usize = null;
    var flex_x: i32 = 0;
    var x: i32 = 0;

    for (items, 0..) |*item, idx| {
        const width_cfg = switch (item.config) {
            inline else => |v| v.width,
        };

        const width = switch (width_cfg) {
            .min_content => switch (item.widget) {
                inline else => |*w| w.measure(ctx),
            },
            .fixed => |w| w,
            .flex => blk: {
                flex_index = idx;
                break :blk 0;
            },
        };

        item.rect = .{
            .x = x,
            .y = 0,
            .width = width,
            .height = ctx.config.height,
        };

        if (width > 0) {
            item.rect.x += switch (item.config) {
                inline else => |*v| v.margin_left,
            };

            x = item.rect.x + item.rect.width + switch (item.config) {
                inline else => |*v| v.margin_right,
            };

            if (flex_index == null) {
                flex_x = x;
            }
        }
    }

    if (flex_index) |idx| {
        var fitem = &items[idx];

        const ml = switch (fitem.config) {
            inline else => |*v| v.margin_left,
        };

        const mr = switch (fitem.config) {
            inline else => |*v| v.margin_right,
        };

        fitem.rect = .{
            .x = flex_x,
            .y = 0,
            .width = @max(0, total_width - x - ml - mr),
            .height = ctx.config.height,
        };

        if (fitem.rect.width > 0) {
            fitem.rect.x += ml;
            x = fitem.rect.x + fitem.rect.width + mr;

            for (items[idx + 1 ..]) |*item| {
                item.rect.x += x - flex_x;
            }
        }
    }
}
