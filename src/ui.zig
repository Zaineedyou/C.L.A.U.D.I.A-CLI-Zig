//! Pembagian area layar dan urutan penggambaran. Port 1:1 dari src/ui/mod.rs.

const std = @import("std");
const theme = @import("ui/theme.zig");
const anim = @import("ui/anim.zig");

pub const dropdown = @import("ui/dropdown.zig");
pub const home = @import("ui/home.zig");
pub const markdown = @import("ui/markdown.zig");
pub const messages = @import("ui/messages.zig");
pub const popup = @import("ui/popup.zig");
pub const prompt = @import("ui/prompt.zig");
pub const sidebar = @import("ui/sidebar.zig");
pub const tabs = @import("ui/tabs.zig");
pub const screen_mod = @import("ui/screen.zig");

pub const Screen = screen_mod.Screen;
pub const Rect = screen_mod.Rect;

pub const PROMPT_H: u16 = 4;
/// Prompt + baris petunjuk.
pub const BLOCK_H: u16 = PROMPT_H + 1;
pub const SIDEBAR_W: u16 = 42;
pub const SIDEBAR_MIN_SCREEN: u16 = 106;

pub const SLIDE_FRAMES: u8 = 16;

/// Pembagian area layar. Dihitung ulang tiap frame dari `app.slide`, jadi
/// prompt meluncur dari tengah ke bawah dan sidebar melebar mulus.
pub const Layout = struct {
    t: f32,
    tabs: Rect,
    main: Rect,
    /// Lebar sidebar; 0 = tidak ditampilkan.
    side_w: u16,
    messages: Rect,
    status: Rect,
    prompt: Rect,
    hint: Rect,
    home_top: u16,
    home_prompt_offset: u16,

    pub fn compute(area: Rect, slide: u8, logo_h: u16) Layout {
        const t = theme.ease(slide, SLIDE_FRAMES);
        // Baris paling atas dipakai tab sesi; sisanya jadi badan layar.
        const tabs_row = Rect{ .x = area.x, .y = area.y, .w = area.w, .h = @min(area.h, 1) };
        const body = Rect{ .x = area.x, .y = area.y + tabs_row.h, .w = area.w, .h = area.h -| tabs_row.h };
        const side_w: u16 = if (body.w >= SIDEBAR_MIN_SCREEN) theme.lerp(@as(u16, 0), SIDEBAR_W, t) else 0;
        const main = Rect{ .x = body.x, .y = body.y, .w = body.w -| side_w, .h = body.h };

        const home_w: u16 = @min(main.w -| 4, @as(u16, 75));
        const session_w: u16 = main.w -| 5;
        const w: u16 = theme.lerp(home_w, session_w, t);
        const x = theme.lerp(main.x + (main.w - home_w) / 2, main.x + 3, t);

        const offset = logo_h + 2;
        const home_h = offset + BLOCK_H;
        const home_top = main.y + (main.h -| home_h) / 2;
        const bottom_y = main.bottom() -| BLOCK_H;
        const home_y = @min(home_top + offset, bottom_y);
        const y = @max(theme.lerp(home_y, bottom_y, t), main.y);

        const gap = @max(y -| 1, main.y);
        return .{
            .t = t,
            .tabs = tabs_row,
            .main = main,
            .side_w = side_w,
            .messages = .{ .x = main.x + 3, .y = main.y, .w = main.w -| 5, .h = gap - main.y },
            .status = .{ .x = main.x + 3, .y = gap, .w = main.w -| 5, .h = 1 },
            .prompt = .{ .x = x, .y = y, .w = w, .h = @min(PROMPT_H, main.h) },
            .hint = .{ .x = x, .y = y + PROMPT_H, .w = w, .h = 1 },
            .home_top = home_top,
            .home_prompt_offset = offset,
        };
    }
};

/// Perkiraan jumlah token seluruh percakapan (4 karakter per token).
pub fn approxTokens(app: anytype) usize {
    var total: usize = 0;
    for (app.messages.items) |*m| {
        total += countChars(m.content.items());
    }
    return total / 4;
}

fn countChars(text: []const u8) usize {
    var it = anim.Utf8Iter{ .s = text };
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

/// Gambar seluruh layar; mengembalikan posisi kursor kalau ada yang minta.
pub fn draw(s: *Screen, app: anytype) ?screen_mod.Cursor {
    const area = s.area();
    const logo_h = anim.logoHeight(s.a);
    const layout = Layout.compute(area, app.slide, logo_h);
    app.tab_area = layout.tabs;

    anim.backdrop(s, app.tick);
    tabs.draw(s, layout.tabs, app);
    var cursor: ?screen_mod.Cursor = null;
    if (app.messages.len() == 0) {
        anim.sparkles(s, area, app.tick, 1.0 - layout.t);
        home.draw(s, app, &layout, 1.0 - layout.t, logo_h);
    }
    chat(s, layout.messages, app);
    status(s, layout.status, app);
    if (prompt.draw(s, app, &layout, area)) |pos| cursor = pos;
    dropdown.draw(s, app, &layout);
    if (layout.side_w > 0) {
        const side = Rect{ .x = layout.main.right(), .y = layout.main.y, .w = layout.side_w, .h = layout.main.h };
        sidebar.draw(s, side, app);
    }
    if (popup.draw(s, app, area)) |pos| cursor = pos;
    return cursor;
}

fn chat(s: *Screen, area: Rect, app: anytype) void {
    if (app.messages.len() == 0 or area.h == 0) {
        app.scroll = 0;
        return;
    }
    const a = app.frameAlloc();
    var lines = markdown.Lines.init();
    messages.build(a, app, area.w, &lines) catch return;
    const height: usize = area.h;
    app.scroll = @min(app.scroll, lines.len() -| height);
    messages.draw(s, area, lines.items, app.scroll);
}

/// Baris tepat di atas prompt: notifikasi, scanner saat menunggu balasan, atau petunjuk gulir.
fn status(s: *Screen, area: Rect, app: anytype) void {
    if (area.h == 0) return;
    var x = area.x;
    const max_x = area.right();
    if (app.notice) |notice| {
        switch (notice) {
            .err => |e| {
                x = s.text(x, area.y, "✖ ", theme.ERR, s.bgAt(x, area.y), max_x);
                _ = s.text(x, area.y, e, theme.ERR, s.bgAt(x, area.y), max_x);
            },
            .info => |i| {
                x = s.text(x, area.y, "✦ ", theme.HEAD, s.bgAt(x, area.y), max_x);
                _ = s.text(x, area.y, i, theme.HEAD, s.bgAt(x, area.y), max_x);
            },
        }
        return;
    }
    if (app.streaming) {
        x = anim.cycle(s, x, area.y, 12, app.tick, max_x);
        x = s.text(x, area.y, " ", theme.DIM, s.bgAt(x, area.y), max_x);
        const text = std.fmt.allocPrint(s.a, "{s} lagi nulis", .{app.cfg.name}) catch "";
        x = anim.shimmer(s, x, area.y, text, app.tick, theme.DIM, max_x);
        x = s.text(x, area.y, anim.dots(app.tick), theme.DIM, s.bgAt(x, area.y), max_x);
        _ = s.text(x, area.y, " esc batal", theme.DIM, s.bgAt(x, area.y), max_x);
        return;
    }
    if (app.scroll > 0) {
        _ = s.text(area.x, area.y, "↓ End: balik ke bawah", theme.DIM, s.bgAt(area.x, area.y), max_x);
        return;
    }
    if (app.attachments.len() > 0) {
        x = s.text(x, area.y, "◈ ", theme.HEAD, s.bgAt(x, area.y), max_x);
        for (app.attachments.items, 0..) |att, i| {
            if (i > 0) x = s.text(x, area.y, "  ", theme.DIM, s.bgAt(x, area.y), max_x);
            x = s.text(x, area.y, att.label, theme.FG, s.bgAt(x, area.y), max_x);
        }
        _ = s.text(x, area.y, "   ctrl+x lepas", theme.DIM, s.bgAt(x, area.y), max_x);
    }
}
