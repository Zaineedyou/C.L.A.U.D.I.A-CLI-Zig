//! Palet dan matematika warna. Port 1:1 dari src/ui/theme.rs.

const std = @import("std");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn eql(a: Color, b: Color) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b;
    }
};

/// Pink pastel dasar; latar sebenarnya gradien (lihat `backdrop`), ini dipakai buat memudarkan teks.
pub const BG = Color{ .r = 255, .g = 228, .b = 240 };
/// Latar kartu: prompt, pesan user, blok kode, popup.
pub const PANEL = Color{ .r = 255, .g = 247, .b = 251 };
/// Latar kartu sidebar.
pub const RAISED = Color{ .r = 255, .g = 243, .b = 249 };
pub const FG = Color{ .r = 62, .g = 42, .b = 72 };
pub const DIM = Color{ .r = 116, .g = 88, .b = 124 };
pub const USER = Color{ .r = 214, .g = 84, .b = 156 };
pub const AI = Color{ .r = 150, .g = 100, .b = 222 };
pub const HEAD = Color{ .r = 226, .g = 118, .b = 40 };
pub const OK = Color{ .r = 56, .g = 160, .b = 112 };
pub const ERR = Color{ .r = 214, .g = 66, .b = 92 };
pub const CODE_FG = Color{ .r = 18, .g = 116, .b = 128 };
pub const CODE_BG = Color{ .r = 246, .g = 238, .b = 255 };
pub const WHITE = Color{ .r = 255, .g = 255, .b = 255 };
pub const ACCENT_A = Color{ .r = 214, .g = 84, .b = 156 };
pub const ACCENT_B = Color{ .r = 90, .g = 150, .b = 232 };

/// Warna-warni cerah buat teks dan garis yang bergerak pelan.
pub const RAINBOW = [_]Color{
    .{ .r = 236, .g = 92, .b = 150 },
    .{ .r = 242, .g = 140, .b = 96 },
    .{ .r = 226, .g = 172, .b = 48 },
    .{ .r = 64, .g = 182, .b = 132 },
    .{ .r = 78, .g = 160, .b = 228 },
    .{ .r = 150, .g = 108, .b = 236 },
};

/// Warna pastel buat latar: dominan pink, diselingi peach, lilac, biru langit, dan mint.
pub const PASTEL = [_]Color{
    .{ .r = 255, .g = 210, .b = 230 },
    .{ .r = 255, .g = 224, .b = 214 },
    .{ .r = 255, .g = 204, .b = 226 },
    .{ .r = 236, .g = 214, .b = 255 },
    .{ .r = 210, .g = 232, .b = 255 },
    .{ .r = 214, .g = 246, .b = 232 },
    .{ .r = 240, .g = 214, .b = 250 },
    .{ .r = 255, .g = 214, .b = 236 },
};

const SPINNER = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

pub fn spinner(tick: usize) []const u8 {
    return SPINNER[(tick / 3) % SPINNER.len];
}

/// Campur dua warna; `t` = 0 → `a`, 1 → `b`.
pub fn mix(a: Color, b: Color, t_in: f32) Color {
    const t = std.math.clamp(t_in, 0.0, 1.0);
    const ch = struct {
        fn f(x: u8, y: u8, tt: f32) u8 {
            return @intFromFloat(@round(@as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(y)) - @as(f32, @floatFromInt(x))) * tt));
        }
    }.f;
    return .{ .r = ch(a.r, b.r, t), .g = ch(a.g, b.g, t), .b = ch(a.b, b.b, t) };
}

/// Gelombang 0..1 yang naik-turun, satu siklus tiap `period` tick.
pub fn pulse(tick: usize, period: f32) f32 {
    return 0.5 + 0.5 * std.math.sin(std.math.tau * @as(f32, @floatFromInt(tick)) / period);
}

/// Warna di sepanjang palet melingkar; `pos` 0..1 (lewat dari itu berputar lagi).
pub fn palette(colors: []const Color, pos: f32) Color {
    const n = colors.len;
    const p = @mod(pos, 1.0) * @as(f32, @floatFromInt(n));
    const i = @min(@as(usize, @intFromFloat(@floor(p))), n - 1);
    return mix(colors[i], colors[(i + 1) % n], p - @floor(p));
}

/// Pelangi yang mengalir pelan; `pos` 0..1 di sepanjang objek.
pub fn flow(pos: f32, tick: usize) Color {
    return palette(&RAINBOW, pos * 0.6 - @as(f32, @floatFromInt(tick)) * 0.004);
}

/// Warna latar pastel di sel (x, y) dari layar `w` x `h`. Bergeser pelan dan dibulatkan per 4 tingkat,
/// supaya sebagian besar sel tidak berubah antar frame.
pub fn backdrop(x: u16, y: u16, w: u16, h: u16, tick: usize) Color {
    const fx = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(@max(w, 1)));
    const fy = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(@max(h, 1)));
    const drift = @as(f32, @floatFromInt(tick / 8)) * 0.0056;
    const c = palette(&PASTEL, fx * 0.35 + fy * 0.65 + drift);
    return .{ .r = c.r / 4 * 4, .g = c.g / 4 * 4, .b = c.b / 4 * 4 };
}

/// Posisi animasi 0..1 dengan easing smoothstep.
pub fn ease(step: u8, max: u8) f32 {
    const t = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(max));
    return t * t * (3.0 - 2.0 * t);
}

pub fn lerp(a: anytype, b: @TypeOf(a), t: f32) @TypeOf(a) {
    const af: f32 = @floatFromInt(a);
    const bf: f32 = @floatFromInt(b);
    return @intFromFloat(@round(af + (bf - af) * t));
}

test "mix endpoints" {
    try std.testing.expect(mix(BG, FG, 0.0).eql(BG));
    try std.testing.expect(mix(BG, FG, 1.0).eql(FG));
}

test "lerp rounds" {
    try std.testing.expectEqual(@as(u16, 5), lerp(@as(u16, 0), @as(u16, 10), 0.5));
}
