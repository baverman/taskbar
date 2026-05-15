const std = @import("std");
const App = @import("app.zig").App;
const cfg = @import("config.zig");
const z = @import("x11.zig").z;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var config = try cfg.load(gpa, io, init.environ_map);
    var conn = try z.Connection.connectFromEnv(gpa, io, init.environ_map);
    defer conn.deinit();

    var app = try App.init(gpa, io, &conn, &config);
    defer app.deinit();
    try app.run();
}
