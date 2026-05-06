pub fn fillString(dst: []u8, src: []const u8) []const u8 {
    const len = @min(dst.len, src.len);
    @memcpy(dst[0..len], src[0..len]);
    return dst[0..len];
}
