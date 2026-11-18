//! Popup di tengah layar: browser file, dialog API key, editor system prompt, dan picker.
//! Port 1:1 dari src/ui/popup.zig.

const std = @import("std");
const theme = @import("theme.zig");
const anim = @import("anim.zig");
const screen_mod = @import("screen.zig");
const files = @import("../files.zig");
const picker_mod = @import("../picker.zig");
const provider = @import("../provider.zig");

const Screen = screen_mod.Screen;
const Rect = screen_mod.Rect;
const Color = theme.Color;

pub fn draw(s: *Screen, app: anytype, area: Rect) ?screen_mod.Cursor {
    if (editorPopup(s, app, area)) |pos| return pos;
    if (keyPopup(s, app, area)) |pos| return pos;
    browserPopup(s, app, area);
    return pickerPopup(s, app, area);
}

fn centered(area: Rect, w_in: u16, h_in: u16) Rect {
    const w = @min(w_in, area.w -| 2);
    const h = @min(h_in, area.h -| 2);
    return .{
        .x = area.x + (area.w - w) / 2,
        .y = area.y + (area.h - h) / 2,
        .w = w,
        .h = h,
    };
}

/// Bingkai bulat berpelangi dengan judul, lalu isi berkaca buram. Kembalikan area dalam.
fn panel(s: *Screen, area: Rect, tick: usize, title: []const u8, footer: []const u8) Rect {
    anim.roundedCard(s, area, tick);
    var x = anim.flowing(s, area.x + 3, area.y, title, tick, area.right() -| 1);
    x = s.text(x, area.y, " ", theme.DIM, s.bgAt(x, area.y), area.right() -| 1);
    _ = anim.slashes(s, x, area.y, 8, tick, area.right() -| 1);
    if (footer.len > 0 and area.h > 1) {
        s.textRight(area.right() -| 2, area.y + area.h - 1, footer, theme.DIM, s.bgAt(area.right() -| 3, area.y + area.h - 1), area.x + 2);
    }
    return Rect{ .x = area.x + 2, .y = area.y + 1, .w = area.w -| 4, .h = area.h -| 2 };
}

// ── browser file ─────────────────────────────────────────

fn browserPopup(s: *Screen, app: anytype, screen: Rect) void {
    const browser = if (app.browser) |*b| b else return;
    const height = theme.lerp(@as(u16, 6), @as(u16, 22), theme.ease(browser.age, picker_mod.POPUP_FRAMES));
    const area = centered(screen, 84, height);
    if (area.w < 10 or area.h < 4) return;
    const a = s.a;

    const path = browser.dir;
    const shown = if (anim.countChars(path) > 46)
        std.fmt.allocPrint(a, "…{s}", .{tailChars(path, 45)}) catch path
    else
        path;
    const title = std.fmt.allocPrint(a, "File {s}", .{shown}) catch "File";
    const inner = panel(s, area, app.tick, title, " enter buka/lampirkan · tab lampirkan · ← naik · esc tutup ");
    if (inner.w < 12 or inner.h == 0) return;

    const width: usize = inner.w;
    var y = inner.y;
    const bottom = inner.bottom();
    if (browser.err) |e| {
        if (y < bottom) {
            _ = s.text(inner.x, y, e, theme.ERR, s.bgAt(inner.x, y), inner.right());
            y += 1;
        }
    }
    if (browser.filter.len() > 0 and y < bottom) {
        const line = std.fmt.allocPrint(a, "› {s}", .{browser.filter.items()}) catch "";
        _ = s.text(inner.x, y, line, theme.HEAD, s.bgAt(inner.x, y), inner.right());
        y += 1;
    }
    const rows: usize = bottom -| y;
    const count = browser.visibleCount();
    const top = (browser.selected + 1) -| rows;
    if (count == 0 and y < bottom) {
        _ = s.text(inner.x, y, "(kosong)", theme.DIM, s.bgAt(inner.x, y), inner.right());
        y += 1;
    }
    var i = top;
    while (i < count and y < bottom) : (i += 1) {
        const entry = browser.visibleAt(i) orelse break;
        const size = if (entry.is_dir) "" else files.humanSize(a, entry.size);
        const room = width -| (anim.countChars(size) + 1);
        const marker = if (entry.is_dir) "▸ " else "  ";
        const slash = if (entry.is_dir) "/" else "";
        var line = std.ArrayListUnmanaged(u8).empty;
        defer line.deinit(a);
        const label = std.fmt.allocPrint(a, "{s}{s}{s}", .{ marker, entry.name, slash }) catch entry.name;
        line.appendSlice(a, clipChars(label, room)) catch {};
        const used = anim.countChars(line.items);
        const pad = width -| (used + anim.countChars(size));
        var k: usize = 0;
        while (k < pad) : (k += 1) line.append(a, ' ') catch {};
        line.appendSlice(a, size) catch {};

        const selected = i == browser.selected;
        const fg: Color = if (selected) theme.WHITE else if (entry.is_dir) theme.HEAD else theme.FG;
        const bg: Color = if (selected) theme.AI else s.bgAt(inner.x, y);
        _ = s.textBold(inner.x, y, line.items, fg, bg, selected, inner.right());
        y += 1;
    }
}

fn tailChars(text: []const u8, n: usize) []const u8 {
    const total = anim.countChars(text);
    if (total <= n) return text;
    var skip = total - n;
    var i: usize = 0;
    while (i < text.len and skip > 0) : (skip -= 1) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        i += @min(len, text.len - i);
    }
    return text[i..];
}

/// Potong teks sampai `n` karakter (bukan kolom), seperti `.chars().take()` di Rust.
fn clipChars(text: []const u8, n: usize) []const u8 {
    var i: usize = 0;
    var taken: usize = 0;
    while (i < text.len and taken < n) : (taken += 1) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        i += @min(len, text.len - i);
    }
    return text[0..i];
}

// ── API key ──────────────────────────────────────────────

fn keyPopup(s: *Screen, app: anytype, screen: Rect) ?screen_mod.Cursor {
    const entry = if (app.keyentry) |*e| e else return null;
    const p = &provider.ALL[entry.provider];
    const height = theme.lerp(@as(u16, 5), @as(u16, 9), theme.ease(entry.age, picker_mod.POPUP_FRAMES));
    const area = centered(screen, 64, height);
    if (area.w < 10 or area.h < 4) return null;
    const a = s.a;

    const title = std.fmt.allocPrint(a, "Hubungkan {s}", .{p.name}) catch "Hubungkan";
    const inner = panel(s, area, app.tick, title, " enter simpan · ctrl+u hapus · esc balik ");
    if (inner.w < 6 or inner.h < 3) return null;

    const hint = std.fmt.allocPrint(a, "atau set {s} di environment", .{p.requirement()}) catch "";
    _ = s.text(inner.x, inner.y, hint, theme.DIM, s.bgAt(inner.x, inner.y), inner.right());

    const input_area = Rect{ .x = inner.x, .y = inner.y + 2, .w = inner.w, .h = 1 };
    anim.tint(s, input_area, theme.FG, 0.10);
    const win = entry.input.window(a, @as(usize, inner.w) -| 2) catch null;
    var col: usize = 0;
    _ = s.text(input_area.x, input_area.y, " ", theme.FG, s.bgAt(input_area.x, input_area.y), input_area.right());
    if (entry.input.isEmpty()) {
        _ = s.text(input_area.x + 1, input_area.y, "API key", theme.DIM, s.bgAt(input_area.x + 1, input_area.y), input_area.right());
    } else if (win) |w| {
        col = w.col;
        var dots = std.ArrayListUnmanaged(u8).empty;
        defer dots.deinit(a);
        var k: usize = 0;
        while (k < anim.countChars(w.visible)) : (k += 1) dots.appendSlice(a, "•") catch {};
        _ = s.text(input_area.x + 1, input_area.y, dots.items, theme.FG, s.bgAt(input_area.x + 1, input_area.y), input_area.right());
    }

    if (inner.h >= 5) {
        if (entry.err) |e| {
            _ = s.text(inner.x, inner.y + 4, e, theme.ERR, s.bgAt(inner.x, inner.y + 4), inner.right());
        }
    }
    return .{ .x = input_area.x + 1 + @as(u16, @intCast(col)), .y = input_area.y };
}

// ── editor system prompt ─────────────────────────────────

fn editorPopup(s: *Screen, app: anytype, screen: Rect) ?screen_mod.Cursor {
    const editor = if (app.editor) |*e| e else return null;
    const height = theme.lerp(@as(u16, 5), @as(u16, 20), theme.ease(editor.age, picker_mod.POPUP_FRAMES));
    const area = centered(screen, 76, height);
    if (area.w < 10 or area.h < 4) return null;
    const a = s.a;

    const inner = panel(s, area, app.tick, "System prompt", " ctrl+s simpan · ctrl+r bawaan · ctrl+u kosong · esc batal ");
    if (inner.w < 2 or inner.h == 0) return null;

    const lay = editor.layout(a, inner.w) catch return null;
    const visible: usize = inner.h;
    const top = (lay.cy + 1) -| visible;
    var y = inner.y;
    var i = top;
    while (i < lay.rows.len and y < inner.bottom()) : (i += 1) {
        _ = s.text(inner.x, y, lay.rows[i].items(), theme.FG, s.bgAt(inner.x, y), inner.right());
        y += 1;
    }
    const cy = if (lay.cy >= top) lay.cy - top else 0;
    return .{
        .x = inner.x + @as(u16, @intCast(lay.cx)),
        .y = inner.y + @as(u16, @intCast(@min(cy, inner.h -| 1))),
    };
}

// ── picker ───────────────────────────────────────────────

fn pickerPopup(s: *Screen, app: anytype, screen: Rect) ?screen_mod.Cursor {
    const picker = if (app.picker) |*p| p else return null;
    const height = theme.lerp(@as(u16, 5), @as(u16, 24), theme.ease(picker.age, picker_mod.POPUP_FRAMES));
    const area = centered(screen, 76, height);
    if (area.w < 12 or area.h < 4) return null;
    const a = s.a;

    const count = picker.items.len();
    const title = switch (picker.kind) {
        .provider => std.fmt.allocPrint(a, "Provider ({d})", .{count}) catch "Provider",
        .model => std.fmt.allocPrint(a, "Model · {s} ({d})", .{ app.cfg.current().name, count }) catch "Model",
        .connect => std.fmt.allocPrint(a, "Hubungkan provider ({d})", .{count}) catch "Hubungkan",
        .command => std.fmt.allocPrint(a, "Perintah ({d})", .{count}) catch "Perintah",
    };
    const inner = panel(s, area, app.tick, title, " ↑↓ pilih · Enter ok · Esc tutup ");
    if (inner.w < 4 or inner.h == 0) return null;

    var y = inner.y;
    // Baris pencarian.
    var x = s.text(inner.x, y, "⌕ ", theme.HEAD, s.bgAt(inner.x, y), inner.right());
    if (picker.filter.len() == 0) {
        x = s.text(x, y, "ketik buat nyaring…", theme.DIM, s.bgAt(x, y), inner.right());
    } else {
        _ = s.text(x, y, picker.filter.items(), theme.FG, s.bgAt(x, y), inner.right());
    }
    if (picker.loading) {
        const load = std.fmt.allocPrint(a, "  {s} ngambil daftar…", .{theme.spinner(app.tick)}) catch "";
        _ = s.text(x, y, load, theme.DIM, s.bgAt(x, y), inner.right());
    }
    y += 1;
    if (y >= inner.bottom()) return null;
    var dashes = std.ArrayListUnmanaged(u8).empty;
    defer dashes.deinit(a);
    var k: usize = 0;
    while (k < inner.w) : (k += 1) dashes.appendSlice(a, "─") catch {};
    _ = s.text(inner.x, y, dashes.items, theme.DIM, s.bgAt(inner.x, y), inner.right());
    y += 1;

    const rows = (inner.bottom() -| y);
    const vis = picker.visibleCount();
    const top = (picker.selected + 1) -| rows;
    if (vis == 0) {
        const query = std.mem.trim(u8, picker.filter.items(), " \t\r\n");
        const text = if (picker.kind == .model and query.len > 0)
            std.fmt.allocPrint(a, "Enter: pakai \"{s}\" secara manual", .{query}) catch ""
        else
            "nggak ada yang cocok";
        if (y < inner.bottom()) _ = s.text(inner.x, y, text, theme.DIM, s.bgAt(inner.x, y), inner.right());
        return null;
    }
    var i = top;
    while (i < vis and y < inner.bottom()) : (i += 1) {
        const item = picker.visibleAt(i) orelse break;
        const selected = i == picker.selected;
        const fg: Color = if (selected) theme.WHITE else theme.FG;
        const bg: Color = if (selected) theme.AI else s.bgAt(inner.x, y);
        var cx = s.textBold(inner.x, y, if (selected) "▸ " else "  ", fg, bg, selected, inner.right());
        cx = s.textBold(cx, y, item.label, fg, bg, selected, inner.right());
        if (item.hint.len > 0) {
            const hint = std.fmt.allocPrint(a, "  {s}", .{item.hint}) catch "";
            cx = s.text(cx, y, hint, theme.DIM, bg, inner.right());
        }
        if (item.current) {
            _ = s.text(cx, y, "  ✓", theme.HEAD, bg, inner.right());
        }
        y += 1;
    }
    return null;
}
