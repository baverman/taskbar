const std = @import("std");

pub fn fillString(dst: []u8, src: []const u8) []const u8 {
    const len = @min(dst.len, src.len);
    @memcpy(dst[0..len], src[0..len]);
    return dst[0..len];
}

pub fn move(cond: *bool, value: anytype) std.meta.Child(@TypeOf(value)) {
    cond.* = true;
    defer value.* = undefined;
    return value.*;
}
