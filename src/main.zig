const std = @import("std");
const App = @import("app.zig").App;
const cfg = @import("config.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var config = try cfg.load(arena.allocator());
    var app = try App.init(arena.allocator(), &config);
    defer app.deinit();
    try app.run();
}
