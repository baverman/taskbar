const std = @import("std");
const x11 = @import("x11.zig");
const c = x11.c;
const x = x11.x;
const z = x11.z;
const shm = x11.shm;
const failed_shm_addr = @as(?*anyopaque, @ptrFromInt(std.math.maxInt(usize)));

pub const Surface = struct {
    window: x.Window,
    gc: x.Gcontext,
    shmseg: shm.Seg,
    depth: u8,
    width: u16,
    height: u16,
    shmid: c_int,
    shmaddr: ?*anyopaque,
    pixels: []align(@alignOf(u32)) u8,
    cairo_surface: ?*c.cairo_surface_t,

    pub fn init(conn: *z.Connection, window: x.Window, depth: u8, width: u16, height: u16) !Surface {
        try conn.registerExtension(.MIT_SHM);
        _ = try conn.request(shm.QueryVersion, .{});

        const gc = try conn.allocId(x.Gcontext);
        errdefer _ = conn.request(x.FreeGC, .{ .gc = gc }) catch {};
        try conn.request(x.CreateGC, .{
            .cid = gc,
            .drawable = .{ .window = window },
            .value_list = .{},
        });

        const shmseg = try conn.allocId(shm.Seg);

        var shm_surface = Surface{
            .window = window,
            .gc = gc,
            .shmseg = shmseg,
            .depth = depth,
            .width = 0,
            .height = 0,
            .shmid = -1,
            .shmaddr = null,
            .pixels = &.{},
            .cairo_surface = null,
        };
        errdefer shm_surface.deinit(conn);

        try shm_surface.resize(conn, width, height);
        return shm_surface;
    }

    pub fn deinit(self: *Surface, conn: *z.Connection) void {
        self.destroyImageResources(conn);
        _ = conn.request(x.FreeGC, .{ .gc = self.gc }) catch {};
    }

    pub fn resize(self: *Surface, conn: *z.Connection, width: u16, height: u16) !void {
        self.destroyImageResources(conn);

        self.width = width;
        self.height = height;

        const image_len = @as(usize, width) * @as(usize, height) * 4;
        self.shmid = c.shmget(c.IPC_PRIVATE, image_len, c.IPC_CREAT | 0o600);
        if (self.shmid < 0) return error.ShmGetFailed;
        errdefer {
            _ = c.shmctl(self.shmid, c.IPC_RMID, null);
            self.shmid = -1;
        }

        self.shmaddr = c.shmat(self.shmid, null, 0);
        if (self.shmaddr == failed_shm_addr) return error.ShmAttachFailed;
        errdefer {
            _ = c.shmdt(self.shmaddr);
            self.shmaddr = null;
        }

        const pixels_ptr: [*]align(@alignOf(u32)) u8 = @ptrCast(@alignCast(self.shmaddr));
        self.pixels = pixels_ptr[0..image_len];

        try conn.request(shm.Attach, .{
            .shmseg = self.shmseg,
            .shmid = @intCast(self.shmid),
            .read_only = false,
        });

        self.cairo_surface = c.cairo_image_surface_create_for_data(
            self.pixels.ptr,
            c.CAIRO_FORMAT_ARGB32,
            width,
            height,
            width * 4,
        ) orelse return error.CairoSurfaceCreateFailed;
        errdefer {
            c.cairo_surface_destroy(self.cairo_surface);
            self.cairo_surface = null;
        }
    }

    pub fn present(self: *Surface, conn: *z.Connection) void {
        const cairo_surface = self.cairo_surface orelse return;
        c.cairo_surface_flush(cairo_surface);
        conn.request(shm.PutImage, .{
            .drawable = .{ .window = self.window },
            .gc = self.gc,
            .total_width = self.width,
            .total_height = self.height,
            .src_x = 0,
            .src_y = 0,
            .src_width = self.width,
            .src_height = self.height,
            .dst_x = 0,
            .dst_y = 0,
            .depth = self.depth,
            .format = @intFromEnum(x.ImageFormat.ZPixmap),
            .send_event = false,
            .shmseg = self.shmseg,
            .offset = 0,
        }) catch {};
    }

    pub fn surface(self: *Surface) *c.cairo_surface_t {
        return self.cairo_surface orelse unreachable;
    }

    fn destroyImageResources(self: *Surface, conn: *z.Connection) void {
        if (self.cairo_surface) |owned_surface| {
            c.cairo_surface_destroy(owned_surface);
            self.cairo_surface = null;
        }
        if (self.shmid >= 0) {
            _ = conn.request(shm.Detach, .{ .shmseg = self.shmseg }) catch {};
            _ = c.shmdt(self.shmaddr);
            _ = c.shmctl(self.shmid, c.IPC_RMID, null);
            self.shmid = -1;
            self.shmaddr = null;
            self.pixels = &.{};
        }
    }
};
