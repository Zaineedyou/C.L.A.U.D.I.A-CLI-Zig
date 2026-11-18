//! Kartu prompt: bingkai bulat berwarna pelangi, baris model, dan petunjuk di bawahnya.
//! Port 1:1 dari src/ui/prompt.zig.

const std = @import("std");
const theme = @import("theme.zig");
const anim = @import("anim.zig");
const screen_mod = @import("screen.zig");
const ui = @import("../ui.zig");

const Screen = screen_mod.Screen;
const Rect = screen_mod.Rect;

const PLACEHOLDERS = [_][]const u8{
    "Perbaiki TODO di kode ini",
    "Apa tech stack proyek ini?",
    "Jelasin kode ini",
    "Cari bug di fungsi ini",
};

/// Menggambar kartu prompt; mengembalikan posisi kursor kalau ada.
pub fn draw(s: *Screen, app: anytype, layout: anytype, screen: Rect) ?screen_mod.Cursor {
    const area = layout.prompt;
    if (area.w < 10 or area.h < 4) return null;
    // Kartu bulat dengan bingkai pelangi; geraknya sedikit lebih cepat saat balasan datang.
    anim.roundedCard(s, area, if (app.streaming) app.tick * 2 else app.tick);

    const a = app.frameAlloc();
    const text_area = Rect{ .x = area.x + 2, .y = area.y + 1, .w = area.w - 4, .h = 1 };
    const meta_area = Rect{ .x = area.x + 2, .y = area.y + 2, .w = area.w - 4, .h = 1 };

    const win = app.input.window(a, text_area.w) catch null;
    var col: usize = 0;
    if (app.input.isEmpty()) {
        const hint = std.fmt.allocPrint(a, "Tanya apa aja… \"{s}\"", .{PLACEHOLDERS[app.tick / 200 % PLACEHOLDERS.len]}) catch "";
        _ = s.text(text_area.x, text_area.y, hint, theme.DIM, s.bgAt(text_area.x, text_area.y), text_area.right());
    } else if (win) |w| {
        _ = s.text(text_area.x, text_area.y, w.visible, theme.FG, s.bgAt(text_area.x, text_area.y), text_area.right());
        col = w.col;
    }

    // Baris model: "Claudia · model  Provider".
    var x = s.text(meta_area.x, meta_area.y, app.cfg.name, theme.AI, s.bgAt(meta_area.x, meta_area.y), meta_area.right());
    x = s.text(x, meta_area.y, " · ", theme.DIM, s.bgAt(x, meta_area.y), meta_area.right());
    const model = if (app.cfg.model().len == 0) "(belum pilih)" else app.cfg.model();
    x = s.text(x, meta_area.y, model, theme.FG, s.bgAt(x, meta_area.y), meta_area.right());
    const p = app.cfg.current();
    x = s.text(x, meta_area.y, " ", theme.DIM, s.bgAt(x, meta_area.y), meta_area.right());
    x = s.text(x, meta_area.y, p.name, theme.DIM, s.bgAt(x, meta_area.y), meta_area.right());
    if (!app.cfg.isReady(p)) {
        const warn = std.fmt.allocPrint(a, "  belum ada key ({s})", .{p.requirement()}) catch "";
        _ = s.textBold(x, meta_area.y, warn, theme.ERR, s.bgAt(x, meta_area.y), true, meta_area.right());
    }

    var cursor: ?screen_mod.Cursor = null;
    if (app.picker == null) {
        cursor = .{ .x = text_area.x + @as(u16, @intCast(col)), .y = text_area.y };
    }

    if (layout.hint.bottom() > screen.bottom()) return cursor;
    // Petunjuk di bawah prompt: folder kerja di kiri, pintasan di kanan.
    _ = s.text(layout.hint.x, layout.hint.y, app.cwd, theme.DIM, s.bgAt(layout.hint.x, layout.hint.y), layout.hint.right());

    var right = std.ArrayListUnmanaged(RightSpan).empty;
    defer right.deinit(s.a);
    if (app.messages.len() > 0) {
        right.append(s.a, .{ .text = std.fmt.allocPrint(a, "{d} token  ", .{ui.approxTokens(app)}) catch "", .fg = theme.DIM }) catch {};
    }
    right.append(s.a, .{ .text = "ctrl+p ", .fg = theme.FG }) catch {};
    right.append(s.a, .{ .text = "commands  ", .fg = theme.DIM }) catch {};
    right.append(s.a, .{ .text = "ctrl+o ", .fg = theme.FG }) catch {};
    right.append(s.a, .{ .text = "model", .fg = theme.DIM }) catch {};
    var right_w: usize = 0;
    for (right.items) |sp| right_w += anim.countChars(sp.text);
    if (anim.countChars(app.cwd) + right_w + 2 < layout.hint.w) {
        const start = layout.hint.right() - @as(u16, @intCast(right_w));
        var rx = start;
        for (right.items) |sp| {
            rx = s.text(rx, layout.hint.y, sp.text, sp.fg, s.bgAt(rx, layout.hint.y), layout.hint.right());
        }
    }
    return cursor;
}

const RightSpan = struct { text: []const u8, fg: theme.Color };
