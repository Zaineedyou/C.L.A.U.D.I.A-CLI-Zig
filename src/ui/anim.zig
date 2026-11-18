//! Animasi yang digambar langsung ke sel: latar pastel, logo foto, kilau, kartu bulat.
//! Port dari src/ui/anim.rs (bagian huruf ASCII diganti foto di logo.zig).

const std = @import("std");
const theme = @import("theme.zig");
const screen_mod = @import("screen.zig");
const logo_mod = @import("../logo.zig");
const width = @import("../width.zig");

const Screen = screen_mod.Screen;
const Rect = screen_mod.Rect;
const Color = theme.Color;

/// Tinggi area logo di layar awal (baris sel).
pub fn logoHeight(a: std.mem.Allocator) u16 {
    return logo_mod.logoHeight(a);
}

pub fn logoWidth() u16 {
    return logo_mod.LOGO_W;
}

/// Latar gradien pastel (pink, peach, lilac, biru langit, mint) yang bergeser pelan.
/// Sekaligus mengosongkan tiap sel, jadi sisa frame sebelumnya tidak tertinggal.
pub fn backdrop(s: *Screen, tick: usize) void {
    const w = s.w;
    const h = s.h;
    var y: u16 = 0;
    while (y < h) : (y += 1) {
        var x: u16 = 0;
        while (x < w) : (x += 1) {
            const bg = theme.backdrop(x, y, w, h, tick);
            const idx = @as(usize, y) * s.w + x;
            s.cells[idx] = .{ .bg = bg, .fg = theme.FG };
        }
    }
}

/// Foto Claudia: digambar sebagai sel setengah blok; `alpha` memudarkannya saat layar bergeser.
pub fn logo(s: *Screen, a: std.mem.Allocator, x: u16, y: u16, alpha: f32) void {
    const g = logo_mod.get(a);
    if (g.w == 0) return;
    var row: u16 = 0;
    while (row < g.h) : (row += 1) {
        var col: u16 = 0;
        while (col < g.w) : (col += 1) {
            const c = g.cellAt(col, row) orelse continue;
            // Warna yang tembus pandang dicampur ke latar di belakangnya (gradien pastel).
            const base = s.bgAt(x + col, y + row);
            const top = theme.mix(base, theme.mix(theme.BG, c.top, alpha), @as(f32, @floatFromInt(c.top_a)) / 255.0);
            const bottom = if (c.bottom_a < 8) base else theme.mix(base, c.bottom, @as(f32, @floatFromInt(c.bottom_a)) / 255.0);
            s.putStyled(x + col, y + row, "▀", top, bottom, false);
        }
    }
}

const GLYPHS = [_][]const u8{
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f", "A", "B", "C", "D", "E", "F", "~", "!",
    "@", "#", "$", "%", "^", "&", "*", "(", ")", "+", "=", "_",
};

fn hash(a: u32, b: u32) u32 {
    var h = a *% 374_761_393 +% b *% 668_265_263;
    h = (h ^ (h >> 13)) *% 1_274_126_177;
    return h ^ (h >> 16);
}

/// Kilau kecil warna-warni yang berkelip pelan di latar layar awal; posisinya tetap.
pub fn sparkles(s: *Screen, area: Rect, tick: usize, alpha: f32) void {
    if (alpha <= 0.0) return;
    var y = area.y;
    while (y < area.bottom() and y < s.h) : (y += 1) {
        var x = area.x;
        while (x < area.right() and x < s.w) : (x += 1) {
            const h = hash(x, @as(u32, y) ^ 0x9e37);
            if (h % 47 != 0) continue;
            const glyph: []const u8 = switch ((h / 47) % 4) {
                0, 1 => "·",
                2 => "✦",
                else => "✧",
            };
            const slow = tick / 4 * 4;
            const twinkle = 0.5 + 0.5 * @sin(@as(f32, @floatFromInt(slow)) * 0.03 + @as(f32, @floatFromInt(h % 97)));
            const color = theme.flow(@as(f32, @floatFromInt(h % 100)) / 100.0, slow);
            const idx = @as(usize, y) * s.w + x;
            const base = s.cells[idx].bg;
            s.putStyled(x, y, glyph, theme.mix(base, color, twinkle * 0.85 * alpha), base, false);
        }
    }
}

/// Deret huruf acak ala Crush: tiap sel ganti glyph sekitar empat kali per detik, warnanya pelangi.
pub fn cycle(s: *Screen, x_in: u16, y: u16, n: usize, tick: usize, max_x: u16) u16 {
    var x = x_in;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (x >= max_x) break;
        const glyph = cycleGlyph(i, tick);
        s.putStyled(x, y, glyph, cycleColor(i, n, tick), theme.BG, false);
        x += 1;
    }
    return x;
}

pub fn cycleGlyph(i: usize, tick: usize) []const u8 {
    return GLYPHS[hash(@intCast(i), @intCast(tick / 5)) % GLYPHS.len];
}

pub fn cycleColor(i: usize, n: usize, tick: usize) Color {
    const pos = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(@max(n, 1)));
    return theme.flow(pos, tick);
}

/// Titik-titik yang bertambah tiap 500 ms (lebar tetap, jadi teks di sebelahnya tidak goyang).
pub fn dots(tick: usize) []const u8 {
    return switch (tick / 10 % 4) {
        0 => "   ",
        1 => ".  ",
        2 => ".. ",
        else => "...",
    };
}

/// Garis miring ╱╱╱ ala header Crush, warnanya pelangi pudar.
pub fn slashes(s: *Screen, x_in: u16, y: u16, n: usize, tick: usize, max_x: u16) u16 {
    var x = x_in;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (x >= max_x) break;
        const pos = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(@max(n, 1)));
        s.putStyled(x, y, "╱", theme.mix(theme.BG, theme.flow(pos, tick), 0.6), theme.BG, false);
        x += 1;
    }
    return x;
}

/// Kaca buram: simbol lama dihapus dan latar di bawahnya dipucatkan ke putih.
pub fn frost(s: *Screen, area: Rect, amount: f32) void {
    var y = area.y;
    while (y < area.bottom() and y < s.h) : (y += 1) {
        var x = area.x;
        while (x < area.right() and x < s.w) : (x += 1) {
            const idx = @as(usize, y) * s.w + x;
            const bg = theme.mix(s.cells[idx].bg, theme.WHITE, amount);
            s.cells[idx] = .{ .bg = bg, .fg = theme.FG };
        }
    }
}

/// Hanya menggeser warna latar ke `color`; simbol dan warna teks tidak berubah.
pub fn tint(s: *Screen, area: Rect, color: Color, amount: f32) void {
    var y = area.y;
    while (y < area.bottom() and y < s.h) : (y += 1) {
        var x = area.x;
        while (x < area.right() and x < s.w) : (x += 1) {
            const idx = @as(usize, y) * s.w + x;
            s.cells[idx].bg = theme.mix(s.cells[idx].bg, color, amount);
        }
    }
}

/// Kartu bulat: bagian dalam berkaca buram, bingkai ╭─╮ berwarna pelangi mengalir.
pub fn roundedCard(s: *Screen, area: Rect, tick: usize) void {
    if (area.w < 3 or area.h < 3) return;
    const inner = Rect{ .x = area.x + 1, .y = area.y + 1, .w = area.w - 2, .h = area.h - 2 };
    frost(s, inner, 0.6);
    const w = area.w;
    const h = area.h;
    const total: f32 = @floatFromInt(@as(u32, w) + @as(u32, h));
    var dx: u16 = 0;
    while (dx < w) : (dx += 1) {
        const top: []const u8 = if (dx == 0) "╭" else if (dx == w - 1) "╮" else "─";
        const bottom: []const u8 = if (dx == 0) "╰" else if (dx == w - 1) "╯" else "─";
        s.putStyled(area.x + dx, area.y, top, theme.flow(@as(f32, @floatFromInt(dx)) / total, tick), s.bgAt(area.x + dx, area.y), false);
        s.putStyled(area.x + dx, area.y + h - 1, bottom, theme.flow(@as(f32, @floatFromInt(dx + h)) / total, tick), s.bgAt(area.x + dx, area.y + h - 1), false);
    }
    var dy: u16 = 1;
    while (dy + 1 < h) : (dy += 1) {
        s.putStyled(area.x, area.y + dy, "│", theme.flow(@as(f32, @floatFromInt(dy)) / total, tick), s.bgAt(area.x, area.y + dy), false);
        s.putStyled(area.x + w - 1, area.y + dy, "│", theme.flow(@as(f32, @floatFromInt(w + dy)) / total, tick), s.bgAt(area.x + w - 1, area.y + dy), false);
    }
}

/// Teks dengan gradien yang bergerak, tebal.
pub fn flowing(s: *Screen, x_in: u16, y: u16, text: []const u8, tick: usize, max_x: u16) u16 {
    const n = @max(countChars(text), 1);
    var x = x_in;
    var i: usize = 0;
    var it = Utf8Iter{ .s = text };
    while (it.next()) |cp| : (i += 1) {
        const color = theme.flow(@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n)), tick);
        const cw = width.charWidth(cp);
        if (x + cw > max_x) break;
        s.putCp(x, y, cp, color, s.bgAt(x, y), true);
        x += cw;
    }
    return x;
}

/// Teks redup dengan kilau yang menyapu dari kiri ke kanan.
pub fn shimmer(s: *Screen, x_in: u16, y: u16, text: []const u8, tick: usize, base: Color, max_x: u16) u16 {
    const n: f32 = @floatFromInt(@max(countChars(text), 1));
    const center = @mod(@as(f32, @floatFromInt(tick)) * 0.012, 1.6) - 0.3;
    var x = x_in;
    var i: usize = 0;
    var it = Utf8Iter{ .s = text };
    while (it.next()) |cp| : (i += 1) {
        const glow = @max(0.0, 1.0 - @abs(@as(f32, @floatFromInt(i)) / n - center) / 0.25);
        const cw = width.charWidth(cp);
        if (x + cw > max_x) break;
        s.putCp(x, y, cp, theme.mix(base, theme.FG, glow), s.bgAt(x, y), false);
        x += cw;
    }
    return x;
}

pub fn countChars(text: []const u8) usize {
    var it = Utf8Iter{ .s = text };
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

/// Iterator codepoint sederhana (pengganti .chars() milik Rust).
pub const Utf8Iter = struct {
    s: []const u8,
    i: usize = 0,

    pub fn next(self: *Utf8Iter) ?u21 {
        if (self.i >= self.s.len) return null;
        const n = std.unicode.utf8ByteSequenceLength(self.s[self.i]) catch {
            self.i += 1;
            return 0xFFFD;
        };
        if (self.i + n > self.s.len) {
            self.i = self.s.len;
            return 0xFFFD;
        }
        const cp = std.unicode.utf8Decode(self.s[self.i .. self.i + n]) catch 0xFFFD;
        self.i += n;
        return cp;
    }
};
