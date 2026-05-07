const std = @import("std");
const App = @import("app.zig").App;
const cfg = @import("config.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var config = try cfg.load(gpa, io, init.environ_map);
    var app = try App.init(gpa, io, &config);
    defer app.deinit();
    try app.run();
}
