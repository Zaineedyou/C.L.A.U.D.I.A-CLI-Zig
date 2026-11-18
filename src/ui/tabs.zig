//! Baris tab sesi di paling atas, seperti OpenCode: judul memudar di ujung, tab aktif tebal, "+" di akhir.
//! Tiap tab dan "+" bisa diklik/disentuh; tinggi area klik dua baris supaya gampang kena jari.

const std = @import("std");
const util = @import("../util.zig");
const theme = @import("theme.zig");
const anim = @import("anim.zig");
const screen_mod = @import("screen.zig");
const width = @import("../width.zig");

const Screen = screen_mod.Screen;
const Rect = screen_mod.Rect;
const Color = theme.Color;

/// Lebar minimum sebuah tab; kalau tidak muat, tab digulir ke sekitar tab aktif.
const MIN_W: usize = 12;
const MAX_W: usize = 28;
/// Judul yang kepanjangan memudar di sekian sel terakhir, bukan dipotong keras.
const FADE: usize = 4;
/// Lebar tombol "+" yang tampak.
const ADD_W: usize = 3;

pub const Click = union(enum) {
    /// Tab ke-n.
    tab: usize,
    /// Tombol "+" (sesi baru).
    new,
};

pub const Hit = struct {
    rect: Rect,
    click: Click,
};

/// Susunan baris tab; dipakai bersama oleh penggambaran dan pengenalan klik.
const Strip = struct {
    titles: []const ?[]const u8,
    has_empty: bool,
    start: usize,
    fit: usize,
    width: usize,
};

fn layout(a: std.mem.Allocator, area: Rect, app: anytype, store: *util.List(?[]const u8)) Strip {
    const count = app.tabs.len();
    store.clearRetainingCapacity();
    var i: usize = 0;
    while (i < count) : (i += 1) store.append(std.heap.c_allocator, app.tabTitle(i)) catch {};
    _ = a;
    const titles = store.items;
    // Sesi kosong tampil sebagai "+ New session"; kalau sudah ada, tombol "+" tidak perlu.
    var has_empty = false;
    for (titles) |t| {
        if (t == null) has_empty = true;
    }
    const add_w: usize = if (has_empty) 0 else ADD_W;
    const avail = @as(usize, area.w) -| add_w;
    const fit = std.math.clamp(avail / MIN_W, 1, count);
    const start = if (count > fit) @min(app.active -| (fit - 1), count - fit) else 0;
    const tab_w = @min(@max(avail / fit, 1), MAX_W);
    return .{ .titles = titles, .has_empty = has_empty, .start = start, .fit = fit, .width = tab_w };
}

/// Area klik: tiap tab yang terlihat, ditambah "+" kalau ada.
pub fn hits(a: std.mem.Allocator, area: Rect, app: anytype, out: *util.List(Hit)) void {
    out.clearRetainingCapacity();
    if (area.w < 8 or area.h == 0) return;
    var titles = util.List(?[]const u8).init();
    defer titles.deinit(std.heap.c_allocator);
    const l = layout(a, area, app, &titles);
    const zone = Rect{ .x = area.x, .y = area.y, .w = area.w, .h = 2 };
    var i = l.start;
    while (i < l.start + l.fit) : (i += 1) {
        const x = area.x + @as(u16, @intCast((i - l.start) * l.width));
        out.append(std.heap.c_allocator, .{
            .rect = Rect.intersect(.{ .x = x, .y = area.y, .w = @intCast(l.width), .h = 2 }, zone),
            .click = .{ .tab = i },
        }) catch {};
    }
    if (!l.has_empty) {
        const x = area.x + @as(u16, @intCast(l.fit * l.width));
        out.append(std.heap.c_allocator, .{
            .rect = Rect.intersect(.{ .x = x, .y = area.y, .w = ADD_W * 2, .h = 2 }, zone),
            .click = .new,
        }) catch {};
    }
}

const Clipped = struct { text: []const u8, used: usize, cut: bool };

/// Potong `text` sampai `width` sel; kembalikan teks, lebar terpakai, dan apakah terpotong.
fn clip(text: []const u8, w: usize) Clipped {
    var used: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const take = @min(n, text.len - i);
        const cp = std.unicode.utf8Decode(text[i .. i + take]) catch 0xFFFD;
        const cw = width.charWidth(cp);
        if (used + cw > w) return .{ .text = text[0..i], .used = used, .cut = true };
        used += cw;
        i += take;
    }
    return .{ .text = text, .used = used, .cut = false };
}

pub fn draw(s: *Screen, area: Rect, app: anytype) void {
    if (area.w < 8 or area.h == 0) return;
    var titles = util.List(?[]const u8).init();
    defer titles.deinit(std.heap.c_allocator);
    const l = layout(s.a, area, app, &titles);
    const tab_w = l.width;

    var x = area.x;
    var i = l.start;
    while (i < l.start + l.fit) : (i += 1) {
        const active = i == app.active;
        const title = l.titles[i];
        const label: []const u8 = title orelse "New session";
        const base: Color = if (active) theme.FG else theme.DIM;
        const busy = active and app.streaming;
        const marker: []const u8 = if (busy)
            theme.spinner(app.tick)
        else if (title == null)
            "+ "
        else if (active)
            "✦ "
        else
            "  ";

        _ = s.textBold(x, area.y, " ", base, s.bgAt(x, area.y), active, area.right());
        x += 1;
        const marker_color: Color = if (busy) theme.AI else base;
        x = s.textBold(x, area.y, marker, marker_color, s.bgAt(x, area.y), active, area.right());

        const room = tab_w -| 4;
        const clipped = clip(label, room);
        var k: usize = 0;
        var it = anim.Utf8Iter{ .s = clipped.text };
        while (it.next()) |cp| : (k += 1) {
            const from_end = anim.countChars(clipped.text) - k;
            var color = base;
            if (clipped.cut and from_end <= FADE) {
                const t = 0.2 + 0.7 * (@as(f32, @floatFromInt(FADE - from_end)) / @as(f32, @floatFromInt(FADE - 1)));
                color = theme.mix(base, theme.BG, t);
            }
            const cw = width.charWidth(cp);
            if (x + cw > area.right()) break;
            s.putCp(x, area.y, cp, color, s.bgAt(x, area.y), active);
            x += cw;
        }
        const pad = room -| clipped.used + 1;
        var j: usize = 0;
        while (j < pad) : (j += 1) {
            if (x >= area.right()) break;
            _ = s.textBold(x, area.y, " ", base, s.bgAt(x, area.y), active, area.right());
            x += 1;
        }
    }
    if (!l.has_empty) {
        _ = s.text(x, area.y, " + ", theme.DIM, s.bgAt(x, area.y), area.right());
    }
    // Tab aktif diberi kaca buram.
    const ax = area.x + @as(u16, @intCast((app.active - l.start) * tab_w));
    anim.tint(s, Rect.intersect(.{ .x = ax, .y = area.y, .w = @intCast(tab_w), .h = 1 }, area), theme.WHITE, 0.6);
}
