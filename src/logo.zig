//! Logo layar awal: gambar Claudia (assets/claudia.png) yang ditanam di dalam binary,
//! di-decode saat start lalu diperkecil jadi sel setengah blok (▀) berwarna asli.

const std = @import("std");
const theme = @import("ui/theme.zig");

/// Lebar logo dalam kolom terminal.
pub const LOGO_W: u16 = 44;

pub const Cell = struct {
    top: theme.Color,
    bottom: theme.Color,
    top_a: u8 = 255,
    bottom_a: u8 = 255,
};

pub const Grid = struct {
    w: u16 = 0,
    h: u16 = 0,
    cells: []Cell = &.{},

    pub fn cellAt(self: Grid, x: u16, y: u16) ?Cell {
        if (x >= self.w or y >= self.h) return null;
        return self.cells[@as(usize, y) * self.w + x];
    }
};

var grid_storage: ?Grid = null;

/// Logo yang sudah siap dipakai (kosong kalau gambarnya gagal dibaca).
pub fn get(a: std.mem.Allocator) Grid {
    if (grid_storage) |g| return g;
    const g = load(a) catch Grid{};
    grid_storage = g;
    return g;
}

pub fn logoHeight(a: std.mem.Allocator) u16 {
    const g = get(a);
    return if (g.h == 0) 6 else g.h;
}

const Image = struct {
    w: usize,
    h: usize,
    /// RGBA 8-bit.
    px: []u8,
};

pub const Error = error{ BadPng, Unsupported, OutOfMemory };

pub fn load(a: std.mem.Allocator) !Grid {
    const raw = @embedFile("assets/claudia.png");
    var img = try decodePng(a, raw);
    defer a.free(img.px);

    const out_w: usize = LOGO_W;
    // Satu sel terminal kira-kira dua kali lebih tinggi daripada lebar.
    const out_h: usize = @max(1, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(out_w)) * @as(f64, @floatFromInt(img.h)) / @as(f64, @floatFromInt(img.w)) / 2.0))));
    const pix_h = out_h * 2;

    const cells = try a.alloc(Cell, out_w * out_h);
    const sx = @as(f64, @floatFromInt(img.w)) / @as(f64, @floatFromInt(out_w));
    const sy = @as(f64, @floatFromInt(img.h)) / @as(f64, @floatFromInt(pix_h));

    var oy: usize = 0;
    while (oy < pix_h) : (oy += 1) {
        var ox: usize = 0;
        while (ox < out_w) : (ox += 1) {
            const c = sampleBox(&img, sx, sy, ox, oy);
            const cy = oy / 2;
            const idx = cy * out_w + ox;
            if (oy % 2 == 0) {
                cells[idx].top = c.color;
                cells[idx].top_a = c.alpha;
            } else {
                cells[idx].bottom = c.color;
                cells[idx].bottom_a = c.alpha;
            }
        }
    }
    return .{ .w = @intCast(out_w), .h = @intCast(out_h), .cells = cells };
}

const Sample = struct { color: theme.Color, alpha: u8 };

/// Rata-rata warna dalam kotak; warna ditimbang alpha supaya tepi transparan tidak jadi gelap.
fn sampleBox(img: *const Image, sx: f64, sy: f64, ox: usize, oy: usize) Sample {
    const x0: usize = @intFromFloat(@as(f64, @floatFromInt(ox)) * sx);
    const y0: usize = @intFromFloat(@as(f64, @floatFromInt(oy)) * sy);
    const x1: usize = @min(img.w, @max(x0 + 1, @as(usize, @intFromFloat(@as(f64, @floatFromInt(ox + 1)) * sx))));
    const y1: usize = @min(img.h, @max(y0 + 1, @as(usize, @intFromFloat(@as(f64, @floatFromInt(oy + 1)) * sy))));
    var r: u64 = 0;
    var g: u64 = 0;
    var b: u64 = 0;
    var a: u64 = 0;
    var n: u64 = 0;
    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const i = (y * img.w + x) * 4;
            const al: u64 = img.px[i + 3];
            r += @as(u64, img.px[i]) * al;
            g += @as(u64, img.px[i + 1]) * al;
            b += @as(u64, img.px[i + 2]) * al;
            a += al;
            n += 1;
        }
    }
    if (n == 0 or a == 0) return .{ .color = theme.BG, .alpha = 0 };
    return .{
        .color = .{ .r = @intCast(r / a), .g = @intCast(g / a), .b = @intCast(b / a) },
        .alpha = @intCast(@min(a / n, 255)),
    };
}

// ── PNG ──────────────────────────────────────────────────

fn be32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .big);
}

pub fn decodePng(a: std.mem.Allocator, data: []const u8) Error!Image {
    if (data.len < 8 or !std.mem.eql(u8, data[0..8], "\x89PNG\r\n\x1a\n")) return error.BadPng;
    var idat: std.ArrayListUnmanaged(u8) = .empty;
    defer idat.deinit(a);
    var palette: [256][3]u8 = undefined;
    var palette_len: usize = 0;
    var trns: [256]u8 = @splat(255);
    var w: usize = 0;
    var h: usize = 0;
    var depth: u8 = 0;
    var color_type: u8 = 0;
    var interlace: u8 = 0;

    var pos: usize = 8;
    while (pos + 8 <= data.len) {
        const len = be32(data[pos .. pos + 4]);
        const kind = data[pos + 4 .. pos + 8];
        pos += 8;
        if (pos + len + 4 > data.len) return error.BadPng;
        const body = data[pos .. pos + len];
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len < 13) return error.BadPng;
            w = be32(body[0..4]);
            h = be32(body[4..8]);
            depth = body[8];
            color_type = body[9];
            interlace = body[12];
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            palette_len = @min(len / 3, 256);
            for (0..palette_len) |i| palette[i] = .{ body[i * 3], body[i * 3 + 1], body[i * 3 + 2] };
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            if (color_type == 3) {
                for (0..@min(len, 256)) |i| trns[i] = body[i];
            }
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(a, body);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            break;
        }
        pos += len + 4;
    }
    if (w == 0 or h == 0 or depth != 8 or interlace != 0) return error.Unsupported;
    const channels: usize = switch (color_type) {
        0 => 1,
        2 => 3,
        3 => 1,
        4 => 2,
        6 => 4,
        else => return error.Unsupported,
    };

    var in = std.Io.Reader.fixed(idat.items);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var dec = std.compress.flate.Decompress.init(&in, .zlib, &window);
    const raw = dec.reader.allocRemaining(a, .unlimited) catch return error.BadPng;
    defer a.free(raw);

    const stride = w * channels;
    if (raw.len < (stride + 1) * h) return error.BadPng;
    var pixels = try a.alloc(u8, stride * h);
    defer a.free(pixels);

    // Buka filter baris demi baris (0 none, 1 sub, 2 up, 3 average, 4 paeth).
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const src = raw[y * (stride + 1) ..];
        const filter = src[0];
        const row_in = src[1 .. 1 + stride];
        const row_out = pixels[y * stride .. (y + 1) * stride];
        const prev: ?[]const u8 = if (y == 0) null else pixels[(y - 1) * stride .. y * stride];
        var x: usize = 0;
        while (x < stride) : (x += 1) {
            const left: u8 = if (x >= channels) row_out[x - channels] else 0;
            const up: u8 = if (prev) |p| p[x] else 0;
            const up_left: u8 = if (prev != null and x >= channels) prev.?[x - channels] else 0;
            const add: u8 = switch (filter) {
                0 => 0,
                1 => left,
                2 => up,
                3 => @intCast((@as(u16, left) + @as(u16, up)) / 2),
                4 => paeth(left, up, up_left),
                else => return error.BadPng,
            };
            row_out[x] = row_in[x] +% add;
        }
    }

    var px = try a.alloc(u8, w * h * 4);
    var i: usize = 0;
    while (i < w * h) : (i += 1) {
        var r: u8 = 0;
        var g: u8 = 0;
        var b: u8 = 0;
        var al: u8 = 255;
        switch (color_type) {
            0 => {
                r = pixels[i];
                g = r;
                b = r;
            },
            2 => {
                r = pixels[i * 3];
                g = pixels[i * 3 + 1];
                b = pixels[i * 3 + 2];
            },
            3 => {
                const idx = pixels[i];
                if (idx < palette_len) {
                    r = palette[idx][0];
                    g = palette[idx][1];
                    b = palette[idx][2];
                }
                al = trns[idx];
            },
            4 => {
                r = pixels[i * 2];
                g = r;
                b = r;
                al = pixels[i * 2 + 1];
            },
            else => {
                r = pixels[i * 4];
                g = pixels[i * 4 + 1];
                b = pixels[i * 4 + 2];
                al = pixels[i * 4 + 3];
            },
        }
        // Simpan alpha apa adanya; pemakainya yang memutuskan latar pengganti.
        px[i * 4] = r;
        px[i * 4 + 1] = g;
        px[i * 4 + 2] = b;
        px[i * 4 + 3] = al;
    }
    return .{ .w = w, .h = h, .px = px };
}

fn paeth(left: u8, up: u8, up_left: u8) u8 {
    const p: i32 = @as(i32, left) + @as(i32, up) - @as(i32, up_left);
    const pa: i32 = @intCast(@abs(p - @as(i32, left)));
    const pb: i32 = @intCast(@abs(p - @as(i32, up)));
    const pc: i32 = @intCast(@abs(p - @as(i32, up_left)));
    if (pa <= pb and pa <= pc) return left;
    if (pb <= pc) return up;
    return up_left;
}
