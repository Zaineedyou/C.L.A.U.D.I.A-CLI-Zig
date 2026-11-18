//! Buffer sel + penggambar ANSI. Pengganti ratatui: satu sel = satu karakter (bisa lebar 2),
//! dengan warna teks dan latar 24-bit. Yang dikirim ke terminal tiap frame cuma sel yang berubah.

const std = @import("std");
const theme = @import("theme.zig");
const width = @import("../width.zig");
const util = @import("../util.zig");

const Color = theme.Color;

pub const Cell = struct {
    bytes: [4]u8 = .{ ' ', 0, 0, 0 },
    len: u8 = 1,
    fg: Color = theme.FG,
    bg: Color = theme.BG,
    bold: bool = false,
    /// Sel lanjutan dari karakter lebar di kirinya; isinya tidak digambar.
    cont: bool = false,

    fn eql(a: Cell, b: Cell) bool {
        if (a.len != b.len or a.cont != b.cont) return false;
        if (a.cont) return true;
        return std.mem.eql(u8, a.bytes[0..a.len], b.bytes[0..b.len]) and
            a.fg.eql(b.fg) and a.bg.eql(b.bg) and a.bold == b.bold;
    }

    pub fn ch(self: *const Cell) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Screen = struct {
    a: std.mem.Allocator,
    w: u16 = 0,
    h: u16 = 0,
    cells: []Cell = &.{},
    prev: []Cell = &.{},
    /// Teks ANSI yang sudah jadi, dipakai ulang tiap frame.
    buf: util.Str = .{},
    cursor: ?struct { x: u16, y: u16 } = null,
    full_redraw: bool = true,

    pub fn init(a: std.mem.Allocator, w: u16, h: u16) !Screen {
        var s = Screen{ .a = a };
        try s.resize(w, h);
        return s;
    }

    pub fn resize(self: *Screen, w: u16, h: u16) !void {
        if (self.w == w and self.h == h) return;
        const n = @as(usize, w) * @as(usize, h);
        const fresh = try self.a.alloc(Cell, n);
        @memset(fresh, Cell{});
        if (self.cells.len > 0) self.a.free(self.cells);
        self.cells = fresh;
        const old_prev = try self.a.alloc(Cell, n);
        @memset(old_prev, Cell{ .bytes = .{ 0, 0, 0, 0 }, .len = 0 });
        if (self.prev.len > 0) self.a.free(self.prev);
        self.prev = old_prev;
        self.w = w;
        self.h = h;
        self.full_redraw = true;
    }

    pub fn area(self: *const Screen) Rect {
        return .{ .x = 0, .y = 0, .w = self.w, .h = self.h };
    }

    pub fn inBounds(self: *const Screen, x: i32, y: i32) bool {
        return x >= 0 and y >= 0 and x < @as(i32, self.w) and y < @as(i32, self.h);
    }

    fn at(self: *Screen, x: u16, y: u16) ?*Cell {
        if (x >= self.w or y >= self.h) return null;
        return &self.cells[@as(usize, y) * self.w + x];
    }

    /// Isi seluruh layar dengan satu warna latar (dipakai sebelum animasi latar).
    pub fn clear(self: *Screen, bg: Color) void {
        for (self.cells) |*c| c.* = .{ .bg = bg, .fg = theme.FG };
    }

    pub fn fill(self: *Screen, r: Rect, bg: Color) void {
        var y = r.y;
        while (y < r.y + r.h) : (y += 1) {
            var x = r.x;
            while (x < r.x + r.w) : (x += 1) {
                if (self.at(x, y)) |c| {
                    c.bg = bg;
                }
            }
        }
    }

    pub fn setBg(self: *Screen, x: u16, y: u16, bg: Color) void {
        if (self.at(x, y)) |c| c.bg = bg;
    }

    pub fn bgAt(self: *Screen, x: u16, y: u16) Color {
        const c = self.at(x, y) orelse return theme.BG;
        return c.bg;
    }

    /// Ganti isi satu sel dengan karakter (UTF-8) dan gaya.
    pub fn put(self: *Screen, x: u16, y: u16, s: []const u8, fg: Color, bg: Color) void {
        self.putStyled(x, y, s, fg, bg, false);
    }

    pub fn putStyled(self: *Screen, x: u16, y: u16, s: []const u8, fg: Color, bg: Color, bold: bool) void {
        const cell = self.at(x, y) orelse return;
        const n = @min(s.len, 4);
        cell.* = .{ .bytes = .{ ' ', 0, 0, 0 }, .len = @intCast(n), .fg = fg, .bg = bg, .bold = bold };
        @memcpy(cell.bytes[0..n], s[0..n]);
        const wdt = width.strWidth(s[0..n]);
        if (wdt >= 2) {
            if (self.at(x + 1, y)) |next_cell| {
                next_cell.* = .{ .cont = true, .bg = bg, .fg = fg };
            }
        }
    }

    /// Gambar satu codepoint.
    pub fn putCp(self: *Screen, x: u16, y: u16, cp: u21, fg: Color, bg: Color, bold: bool) void {
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch return;
        self.putStyled(x, y, tmp[0..n], fg, bg, bold);
    }

    /// Tulis teks mulai (x, y), berhenti di tepi kanan `max_x`. Kembalikan kolom setelah teks.
    pub fn text(self: *Screen, x_in: u16, y: u16, s: []const u8, fg: Color, bg: Color, max_x: u16) u16 {
        return self.textBold(x_in, y, s, fg, bg, false, max_x);
    }

    pub fn textBold(self: *Screen, x_in: u16, y: u16, s: []const u8, fg: Color, bg: Color, bold: bool, max_x: u16) u16 {
        var x = x_in;
        var i: usize = 0;
        while (i < s.len) {
            const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            if (i + n > s.len) break;
            const cp = std.unicode.utf8Decode(s[i .. i + n]) catch {
                i += 1;
                continue;
            };
            const wdt = width.charWidth(cp);
            if (x + wdt > max_x) break;
            self.putStyled(x, y, s[i .. i + n], fg, bg, bold);
            x += wdt;
            i += n;
        }
        return x;
    }

    pub fn textRight(self: *Screen, right_x: u16, y: u16, s: []const u8, fg: Color, bg: Color, min_x: u16) void {
        const wdt: u16 = @intCast(width.strWidth(s));
       	const start = if (right_x >= wdt) right_x - wdt else 0;
        if (start < min_x) return;
        _ = self.text(start, y, s, fg, bg, right_x);
    }

    /// Bingkai kotak dengan sudut membulat. `border_color` boleh fungsi posisi untuk pelangi.
    pub fn roundBox(self: *Screen, r: Rect, border_at: anytype, bg: Color) void {
        if (r.w < 2 or r.h < 2) return;
        var dx: u16 = 0;
        while (dx < r.w) : (dx += 1) {
            const ch: []const u8 = if (dx == 0) "╭" else if (dx == r.w - 1) "╮" else "─";
            self.put(r.x + dx, r.y, ch, border_at(r.x + dx, r.y, dx, 0), bg);
            const ch2: []const u8 = if (dx == 0) "╰" else if (dx == r.w - 1) "╯" else "─";
            self.put(r.x + dx, r.y + r.h - 1, ch2, border_at(r.x + dx, r.y + r.h - 1, dx, 1), bg);
        }
        var dy: u16 = 1;
        while (dy + 1 < r.h) : (dy += 1) {
            self.put(r.x, r.y + dy, "│", border_at(r.x, r.y + dy, 0, 2), bg);
            self.put(r.x + r.w - 1, r.y + dy, "│", border_at(r.x + r.w - 1, r.y + dy, 1, 2), bg);
        }
    }

    /// Bandingkan dengan frame sebelumnya dan kirim cuma yang berubah.
    pub fn flush(self: *Screen, cursor: ?Cursor) void {
        self.render(&self.buf, cursor);
        if (self.buf.len() > 0) term_write(self.buf.items());
    }

    /// Bangun teks ANSI frame ini ke `out` (dikosongkan dulu).
    pub fn render(self: *Screen, out: *util.Str, cursor: ?Cursor) void {
        out.clear();
        const a = self.a;
        out.append(a, "\x1b[?25l") catch {}; // sembunyikan kursor selama menggambar
        var last: ?usize = null;
        var cur_fg = Color{ .r = 0, .g = 0, .b = 0 };
        var cur_bg = Color{ .r = 0, .g = 0, .b = 0 };
        var cur_bold = false;
        var style_valid = false;
        var y: u16 = 0;
        while (y < self.h) : (y += 1) {
            var x: u16 = 0;
            while (x < self.w) : (x += 1) {
                const idx = @as(usize, y) * self.w + x;
                const cell = self.cells[idx];
                if (self.full_redraw or !cell.eql(self.prev[idx])) {
                    if (last == null or last.? + 1 != idx) {
                        out.appendFmt(a, "\x1b[{d};{d}H", .{ y + 1, x + 1 }) catch {};
                    }
                    if (!style_valid or cur_fg.r != cell.fg.r or cur_fg.g != cell.fg.g or cur_fg.b != cell.fg.b or
                        cur_bg.r != cell.bg.r or cur_bg.g != cell.bg.g or cur_bg.b != cell.bg.b or cur_bold != cell.bold)
                    {
                        out.appendFmt(a, "\x1b[0;38;2;{d};{d};{d};48;2;{d};{d};{d}", .{
                            cell.fg.r, cell.fg.g, cell.fg.b, cell.bg.r, cell.bg.g, cell.bg.b,
                        }) catch {};
                        if (cell.bold) out.append(a, ";1") catch {};
                        out.append(a, "m") catch {};
                        cur_fg = cell.fg;
                        cur_bg = cell.bg;
                        cur_bold = cell.bold;
                        style_valid = true;
                    }
                    if (cell.cont) {
                        // Sel lanjutan: karakter lebar sudah mengisi dua kolom.
                    } else if (cell.len == 0) {
                        out.append(a, " ") catch {};
                    } else {
                        out.append(a, (&cell).ch()) catch {};
                    }
                    last = idx;
                }
                self.prev[idx] = cell;
            }
        }
        if (cursor) |c| {
            out.appendFmt(a, "\x1b[0m\x1b[{d};{d}H\x1b[?25h", .{ c.y + 1, c.x + 1 }) catch {};
        } else {
            out.append(a, "\x1b[0m") catch {};
        }
        self.full_redraw = false;
    }
};

extern fn write(fd: c_int, buf: [*]const u8, n: usize) isize;

fn term_write(bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = write(1, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

pub const Rect = struct {
    x: u16 = 0,
    y: u16 = 0,
    w: u16 = 0,
    h: u16 = 0,

    pub fn right(self: Rect) u16 {
        return self.x + self.w;
    }

    pub fn bottom(self: Rect) u16 {
        return self.y + self.h;
    }

    pub fn contains(self: Rect, x: u16, y: u16) bool {
        return x >= self.x and x < self.right() and y >= self.y and y < self.bottom();
    }

    pub fn inner(self: Rect) Rect {
        if (self.w < 2 or self.h < 2) return .{ .x = self.x, .y = self.y, .w = 0, .h = 0 };
        return .{ .x = self.x + 1, .y = self.y + 1, .w = self.w - 2, .h = self.h - 2 };
    }

    pub fn intersect(a: Rect, b: Rect) Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.right(), b.right());
        const y1 = @min(a.bottom(), b.bottom());
        if (x1 <= x0 or y1 <= y0) return .{ .x = x0, .y = y0, .w = 0, .h = 0 };
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }
};

/// Posisi kursor teks yang diminta frame ini.
pub const Cursor = struct { x: u16, y: u16 };

test "glyph bytes are intact" {
    var s = try Screen.init(std.testing.allocator, 4, 1);
    defer std.testing.allocator.free(s.cells);
    defer std.testing.allocator.free(s.prev);
    s.put(0, 0, "▀", theme.FG, theme.BG);
    try std.testing.expectEqual(@as(u8, 3), s.cells[0].len);
    try std.testing.expectEqualStrings("▀", s.cells[0].ch());
    s.putStyled(1, 0, "╭", theme.FG, theme.BG, true);
    try std.testing.expectEqualStrings("╭", s.cells[1].ch());
}
