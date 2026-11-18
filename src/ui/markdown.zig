//! Markdown ringan untuk terminal: heading, bullet, **tebal**, `kode`, blok kode, dan tabel.
//! Port 1:1 dari src/ui/markdown.rs.

const std = @import("std");
const theme = @import("theme.zig");
const util = @import("../util.zig");
const width = @import("../width.zig");

pub const Color = theme.Color;

pub const Style = struct {
    fg: Color,
    bg: Color = theme.PANEL,
    bold: bool = false,
};

pub const Span = struct {
    text: []const u8,
    style: Style,
};

pub const Line = struct {
    spans: util.List(Span) = .{},
};

pub const Lines = util.List(Line);

/// Penanda di awal tiap baris (garis kiri pesan user); `null` = tanpa penanda.
pub const Bar = struct {
    text: []const u8,
    fg: Color,
    bg: Color = theme.PANEL,
};

pub fn render(a: std.mem.Allocator, text: []const u8, w: usize, bar: ?Bar, out: *Lines) !void {
    const row = struct {
        fn make(al: std.mem.Allocator, b: ?Bar, spans: []const Span) !Line {
            var line = Line{};
            if (b) |bb| try line.spans.append(al, .{ .text = bb.text, .style = .{ .fg = bb.fg, .bg = bb.bg } });
            try line.spans.appendSlice(al, spans);
            return line;
        }
    }.make;

    var in_code = false;
    var lines_it = std.mem.splitScalar(u8, text, '\n');
    var all = util.List([]const u8).init();
    while (lines_it.next()) |l| try all.append(a, l);

    var i: usize = 0;
    while (i < all.len()) {
        const raw = all.items[i];
        const trimmed = std.mem.trimStart(u8, raw, " \t");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            in_code = !in_code;
            const lang = std.mem.trim(u8, trimmed[3..], " \t");
            const label = if (in_code)
                (if (lang.len == 0) "╭─ kode" else try std.fmt.allocPrint(a, "╭─ {s}", .{lang}))
            else
                "╰─";
            try out.append(a, try row(a, bar, &.{.{ .text = label, .style = .{ .fg = theme.DIM } }}));
        } else if (in_code) {
            const style = Style{ .fg = theme.CODE_FG };
            const replaced = try replaceTabs(a, raw);
            const pieces = try hardWrap(a, replaced, if (w >= 2) w - 2 else 4);
            for (pieces) |piece| {
                const shown = try std.fmt.allocPrint(a, " {s} ", .{piece});
                try out.append(a, try row(a, bar, &.{.{ .text = shown, .style = style }}));
            }
        } else if (isTableLine(raw)) {
            var end = i;
            while (end < all.len() and isTableLine(all.items[end])) end += 1;
            var parsed = util.List([]const []const u8).init();
            for (all.items[i..end]) |l| try parsed.append(a, try splitRow(a, l));
            const has_header = parsed.len() > 1 and isSeparator(parsed.items[1]);
            var body = util.List([]const []const u8).init();
            for (parsed.items) |r| {
                if (!isSeparator(r)) try body.append(a, r);
            }
            if (body.len() > 0 and try renderTable(a, body.items, has_header, w, bar, out)) {
                i = end;
                continue;
            }
            const pieces = try wrap(a, raw, w);
            for (pieces) |piece| {
                try out.append(a, try row(a, bar, try inlineSpans(a, piece, .{ .fg = theme.FG })));
            }
        } else {
            const cls = try classify(a, raw, trimmed);
            const pieces = try wrap(a, cls.text, w);
            for (pieces) |piece| {
                try out.append(a, try row(a, bar, try inlineSpans(a, piece, cls.style)));
            }
        }
        i += 1;
    }
}

fn replaceTabs(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '\t') == null) return text;
    var s = util.Str.init();
    for (text) |c| {
        if (c == '\t') {
            try s.append(a, "    ");
        } else {
            try s.appendByte(a, c);
        }
    }
    return s.items();
}

fn isTableLine(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t");
    return t.len > 1 and t[0] == '|';
}

fn splitRow(a: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var t = std.mem.trim(u8, line, " \t");
    if (t.len > 0 and t[0] == '|') t = t[1..];
    if (t.len > 0 and t[t.len - 1] == '|') t = t[0 .. t.len - 1];
    var cells = util.List([]const u8).init();
    var it = std.mem.splitScalar(u8, t, '|');
    while (it.next()) |cell| try cells.append(a, std.mem.trim(u8, cell, " \t"));
    return cells.items;
}

/// Baris pemisah header, mis. `| --- | :---: |`.
fn isSeparator(cells: []const []const u8) bool {
    if (cells.len == 0) return false;
    for (cells) |c| {
        if (c.len == 0) return false;
        for (c) |ch| {
            if (ch != '-' and ch != ':') return false;
        }
    }
    return true;
}

/// Lebar tampil teks tanpa penanda `**` dan `` ` ``.
fn plainWidth(a: std.mem.Allocator, text: []const u8) usize {
    const cleaned = stripMarks(a, text) catch return width.strWidth(text);
    return width.strWidth(cleaned);
}

fn stripMarks(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var s = util.Str.init();
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '`') continue;
        if (text[i] == '*' and i + 1 < text.len and text[i + 1] == '*') {
            i += 1;
            continue;
        }
        try s.appendByte(a, text[i]);
    }
    return s.items();
}

fn renderTable(
    a: std.mem.Allocator,
    rows: []const []const []const u8,
    has_header: bool,
    w: usize,
    bar: ?Bar,
    out: *Lines,
) !bool {
    var cols: usize = 0;
    for (rows) |r| cols = @max(cols, r.len);
    if (cols == 0 or w < 3 * cols + 1 + 3 * cols) return false;
    const avail = w - (3 * cols + 1);
    const widths = try a.alloc(usize, cols);
    for (0..cols) |c| {
        var mx: usize = 1;
        for (rows) |r| {
            if (c < r.len) mx = @max(mx, plainWidth(a, r[c]));
        }
        widths[c] = @max(mx, 1);
    }
    var sum: usize = 0;
    for (widths) |x| sum += x;
    while (sum > avail) {
        var widest: usize = 0;
        for (0..cols) |c| {
            if (widths[c] > widths[widest]) widest = c;
        }
        if (widths[widest] <= 3) return false;
        widths[widest] -= 1;
        sum -= 1;
    }

    const line_style = Style{ .fg = theme.mix(theme.BG, theme.DIM, 0.55) };
    const rule = struct {
        fn make(al: std.mem.Allocator, left: []const u8, mid: []const u8, right: []const u8, ws: []const usize, b: ?Bar) !Line {
            var s = util.Str.init();
            try s.append(al, left);
            for (ws, 0..) |cw, c| {
                var k: usize = 0;
                while (k < cw + 2) : (k += 1) try s.append(al, "─");
                try s.append(al, if (c + 1 == ws.len) right else mid);
            }
            var line = Line{};
            if (b) |bb| try line.spans.append(al, .{ .text = bb.text, .style = .{ .fg = bb.fg, .bg = bb.bg } });
            try line.spans.append(al, .{ .text = s.items(), .style = Style{ .fg = theme.mix(theme.BG, theme.DIM, 0.55) } });
            return line;
        }
    }.make;

    try out.append(a, try rule(a, "╭", "┬", "╮", widths, bar));
    for (rows, 0..) |cells_row, r| {
        const base = if (has_header and r == 0) Style{ .fg = theme.FG, .bold = true } else Style{ .fg = theme.FG };
        const cells = try a.alloc([]const []const u8, cols);
        for (0..cols) |c| {
            const raw = if (c < cells_row.len) cells_row[c] else "";
            cells[c] = try wrap(a, raw, widths[c]);
        }
        var height: usize = 1;
        for (cells) |cell| height = @max(height, cell.len);
        var line_no: usize = 0;
        while (line_no < height) : (line_no += 1) {
            var line = Line{};
            if (bar) |bb| try line.spans.append(a, .{ .text = bb.text, .style = .{ .fg = bb.fg, .bg = bb.bg } });
            try line.spans.append(a, .{ .text = "│", .style = line_style });
            for (0..cols) |c| {
                const piece = if (line_no < cells[c].len) cells[c][line_no] else "";
                try line.spans.append(a, .{ .text = " ", .style = Style{ .fg = theme.FG } });
                try line.spans.appendSlice(a, try inlineSpans(a, piece, base));
                const pad = widths[c] - plainWidth(a, piece);
                var k: usize = 0;
                while (k < pad + 1) : (k += 1) try line.spans.append(a, .{ .text = " ", .style = Style{ .fg = theme.FG } });
                try line.spans.append(a, .{ .text = "│", .style = line_style });
            }
            try out.append(a, line);
        }
        if (r + 1 == rows.len) {
            try out.append(a, try rule(a, "╰", "┴", "╯", widths, bar));
        } else {
            try out.append(a, try rule(a, "├", "┼", "┤", widths, bar));
        }
    }
    return true;
}

const Classified = struct { text: []const u8, style: Style };

/// Tentukan teks dan gaya dasar sebuah baris biasa.
fn classify(a: std.mem.Allocator, raw: []const u8, trimmed: []const u8) !Classified {
    if (trimmed.len > 0 and trimmed[0] == '#') {
        const body = std.mem.trimStart(u8, std.mem.trimStart(u8, trimmed, "#"), " \t");
        return .{ .text = body, .style = .{ .fg = theme.HEAD, .bold = true } };
    }
    if (std.mem.startsWith(u8, trimmed, "- ")) {
        return .{ .text = try std.fmt.allocPrint(a, "• {s}", .{trimmed[2..]}), .style = .{ .fg = theme.FG } };
    }
    if (std.mem.startsWith(u8, trimmed, "* ")) {
        return .{ .text = try std.fmt.allocPrint(a, "• {s}", .{trimmed[2..]}), .style = .{ .fg = theme.FG } };
    }
    return .{ .text = raw, .style = .{ .fg = theme.FG } };
}

/// Gaya inline: `kode`, **tebal**.
fn inlineSpans(a: std.mem.Allocator, piece: []const u8, base: Style) ![]const Span {
    var spans = util.List(Span).init();
    var buf = util.Str.init();
    var is_bold = false;
    var is_code = false;
    const style_of = struct {
        fn f(bold: bool, code: bool, bs: Style) Style {
            if (code) return .{ .fg = theme.CODE_FG, .bg = bs.bg };
            if (bold) return .{ .fg = theme.HEAD, .bg = bs.bg, .bold = true };
            return bs;
        }
    }.f;

    const flush = struct {
        fn f(al: std.mem.Allocator, list: *util.List(Span), b: *util.Str, st: Style) !void {
            if (b.len() > 0) {
                try list.append(al, .{ .text = try b.dupe(al), .style = st });
                b.clear();
            }
        }
    }.f;

    var i: usize = 0;
    while (i < piece.len) : (i += 1) {
        const c = piece[i];
        const double_star = c == '*' and !is_code and i + 1 < piece.len and piece[i + 1] == '*';
        if (c == '`' or double_star) {
            try flush(a, &spans, &buf, style_of(is_bold, is_code, base));
            if (c == '`') {
                is_code = !is_code;
            } else {
                i += 1;
                is_bold = !is_bold;
            }
            continue;
        }
        // Salin byte; codepoint lebar tetap utuh karena kita menyalin per byte.
        try buf.appendByte(a, c);
    }
    try flush(a, &spans, &buf, style_of(is_bold, is_code, base));
    return spans.items;
}

/// Bungkus per kata; kata yang lebih panjang dari `width` dipotong paksa.
pub fn wrap(a: std.mem.Allocator, text: []const u8, w_in: usize) ![]const []const u8 {
    const w = @max(w_in, 1);
    var lines = util.List([]const u8).init();
    var cur = util.Str.init();
    var cur_w: usize = 0;
    var it = std.mem.splitScalar(u8, text, ' ');
    while (it.next()) |word| {
        const ww = width.strWidth(word);
        if (cur_w > 0 and cur_w + 1 + ww > w) {
            try lines.append(a, try cur.dupe(a));
            cur.clear();
            cur_w = 0;
        }
        if (ww > w) {
            const pieces = try hardWrap(a, word, w);
            for (pieces) |piece| {
                if (cur_w > 0) {
                    try lines.append(a, try cur.dupe(a));
                    cur.clear();
                }
                cur_w = width.strWidth(piece);
                try cur.append(a, piece);
            }
            continue;
        }
        if (cur_w > 0) {
            try cur.appendByte(a, ' ');
            cur_w += 1;
        }
        try cur.append(a, word);
        cur_w += ww;
    }
    try lines.append(a, try cur.dupe(a));
    return lines.items;
}

/// Potong per karakter tanpa menyentuh spasi (untuk blok kode).
fn hardWrap(a: std.mem.Allocator, text: []const u8, w_in: usize) ![]const []const u8 {
    const w = @max(w_in, 1);
    var lines = util.List([]const u8).init();
    var cur = util.Str.init();
    var cur_w: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const take = @min(n, text.len - i);
        const cp = std.unicode.utf8Decode(text[i .. i + take]) catch 0xFFFD;
        const cw = width.charWidth(cp);
        if (cur_w + cw > w and cur_w > 0) {
            try lines.append(a, try cur.dupe(a));
            cur.clear();
            cur_w = 0;
        }
        try cur.append(a, text[i .. i + take]);
        cur_w += cw;
        i += take;
    }
    try lines.append(a, try cur.dupe(a));
    return lines.items;
}

test "wraps on word boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try wrap(a, "halo dunia semua", 10);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("halo dunia", got[0]);
    try std.testing.expectEqualStrings("semua", got[1]);
}

test "splits overlong words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try wrap(a, "abcdefgh", 3);
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings("gh", got[2]);
}

test "renders a table with borders" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out = Lines.init();
    try render(a, "| a | b |\n| --- | --- |\n| 1 | 2 |", 30, null, &out);
    try std.testing.expect(out.len() > 0);
    try std.testing.expectEqualStrings("╭───┬───╮", out.items[0].spans.items[0].text);
    try std.testing.expectEqualStrings("╰───┴───╯", out.items[out.len() - 1].spans.items[0].text);
}
