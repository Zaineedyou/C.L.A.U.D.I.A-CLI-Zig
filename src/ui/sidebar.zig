//! Sidebar sesi ala OpenCode: judul, konteks, dan folder kerja di dasar.
//! Port 1:1 dari src/ui/sidebar.rs.

const std = @import("std");
const theme = @import("theme.zig");
const anim = @import("anim.zig");
const screen_mod = @import("screen.zig");
const width = @import("../width.zig");
const ui = @import("../ui.zig");

const Screen = screen_mod.Screen;
const Rect = screen_mod.Rect;

/// Judul sesi: baris pertama pesan user pertama, dipotong sesuai lebar.
fn title(a: std.mem.Allocator, app: anytype, w: usize) []const u8 {
    var first: []const u8 = "Sesi baru";
    for (app.messages.items) |*m| {
        if (m.role == .user) {
            const content = m.content.items();
            const nl = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
            first = std.mem.trim(u8, content[0..nl], " \t\r");
            break;
        }
    }
    const first_trimmed = first;
    if (width.strWidth(first_trimmed) <= w or w <= 1) return first_trimmed;
    // Potong sampai w-1 kolom lalu tambahkan elipsis.
    var used: usize = 0;
    var i: usize = 0;
    while (i < first_trimmed.len) {
        const n = std.unicode.utf8ByteSequenceLength(first_trimmed[i]) catch 1;
        const take = @min(n, first_trimmed.len - i);
        const cp = std.unicode.utf8Decode(first_trimmed[i .. i + take]) catch 0xFFFD;
        const cw = width.charWidth(cp);
        if (used + cw > w - 1) break;
        used += cw;
        i += take;
    }
    return std.fmt.allocPrint(a, "{s}…", .{first_trimmed[0..i]}) catch first_trimmed;
}

pub fn draw(s: *Screen, area: Rect, app: anytype) void {
    if (area.w < 14 or area.h < 5) return;
    const a = s.a;
    // Kartu bulat yang melayang di atas latar pastel.
    const card = Rect{ .x = area.x + 1, .y = area.y, .w = area.w - 2, .h = area.h - 1 };
    anim.roundedCard(s, card, app.tick);
    const inner = Rect{ .x = card.x + 2, .y = card.y + 1, .w = card.w - 4, .h = card.h -| 2 };
    const w: usize = inner.w;

    const p = app.cfg.current();
    const dot_color = if (app.cfg.isReady(p)) theme.OK else theme.ERR;
    var y = inner.y;
    const max_y = inner.bottom();

    y = drawBold(s, inner.x, y, max_y, title(a, app, w), theme.FG);
    var x = inner.x;
    var i: usize = 0;
    while (i < w) : (i += 1) {
        x = anim.slashes(s, x, y, 1, app.tick, inner.right());
    }
    y += 1;
    y += 1; // baris kosong

    y = drawBold(s, inner.x, y, max_y, "Context", theme.FG);
    y = drawDim(s, inner.x, y, max_y, std.fmt.allocPrint(a, "{d} tokens", .{ui.approxTokens(app)}) catch "");
    y = drawDim(s, inner.x, y, max_y, std.fmt.allocPrint(a, "{d} pesan", .{app.messages.len()}) catch "");
    y += 1;

    y = drawBold(s, inner.x, y, max_y, "Provider", theme.FG);
    if (y < max_y) {
        const x2 = s.text(inner.x, y, "● ", dot_color, s.bgAt(inner.x, y), inner.right());
        _ = s.text(x2, y, p.name, theme.FG, s.bgAt(x2, y), inner.right());
        y += 1;
    }
    y = drawDim(s, inner.x, y, max_y, app.cfg.model());
    y += 1;

    y = drawBold(s, inner.x, y, max_y, "Akses file", theme.FG);
    _ = drawDim(s, inner.x, y, max_y, app.access.label());

    if (inner.h > 1) {
        const foot_y = inner.bottom() - 1;
        _ = s.text(inner.x, foot_y, app.cwd, theme.DIM, s.bgAt(inner.x, foot_y), inner.right());
    }
}

fn drawBold(s: *Screen, x: u16, y: u16, max_y: u16, text: []const u8, color: theme.Color) u16 {
    if (y >= max_y) return max_y;
    _ = s.textBold(x, y, text, color, s.bgAt(x, y), false, s.w);
    return y + 1;
}

fn drawDim(s: *Screen, x: u16, y: u16, max_y: u16, text: []const u8) u16 {
    if (y >= max_y) return max_y;
    _ = s.text(x, y, text, theme.DIM, s.bgAt(x, y), s.w);
    return y + 1;
}
