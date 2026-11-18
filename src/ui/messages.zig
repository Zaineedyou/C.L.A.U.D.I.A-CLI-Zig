//! Percakapan sebagai baris yang sudah di-wrap: kartu user bergaris kiri, balasan dengan indentasi.
//! Port 1:1 dari src/ui/messages.rs.

const std = @import("std");
const util = @import("../util.zig");
const theme = @import("theme.zig");
const anim = @import("anim.zig");
const markdown = @import("markdown.zig");
const screen_mod = @import("screen.zig");

const Screen = screen_mod.Screen;
const Rect = screen_mod.Rect;
const Line = markdown.Line;
const Lines = markdown.Lines;
const Span = markdown.Span;

const USER = theme.USER;
const HEAD = theme.HEAD;
const DIM = theme.DIM;
const AI = theme.AI;

/// Seluruh percakapan sebagai baris yang sudah di-wrap untuk lebar `width`.
pub fn build(a: std.mem.Allocator, app: anytype, w: usize, out: *Lines) !void {
    const last = app.messages.len() -| 1;
    for (app.messages.items, 0..) |*msg, i| {
        switch (msg.role) {
            .user => try user(a, msg, w, out),
            else => try assistant(a, app, msg, i == last, w, out),
        }
        try out.append(a, .{});
    }
}

/// Pesan user: kartu dengan garis kiri yang membulat di ujungnya (╭ │ ╰).
fn user(a: std.mem.Allocator, msg: anytype, w: usize, out: *Lines) !void {
    const bar = markdown.Bar{ .text = "│ ", .fg = USER };
    var first = Line{};
    try first.spans.append(a, .{ .text = "╭", .style = .{ .fg = USER } });
    try out.append(a, first);
    try markdown.render(a, msg.content.items(), w -| 2, bar, out);
    for (msg.files.items) |label| {
        var line = Line{};
        try line.spans.append(a, .{ .text = bar.text, .style = .{ .fg = bar.fg } });
        try line.spans.append(a, .{ .text = try std.fmt.allocPrint(a, "◈ {s}", .{label}), .style = .{ .fg = HEAD } });
        try out.append(a, line);
    }
    var last_line = Line{};
    try last_line.spans.append(a, .{ .text = "╰", .style = .{ .fg = USER } });
    try out.append(a, last_line);
}

fn assistant(a: std.mem.Allocator, app: anytype, msg: anytype, last: bool, w: usize, out: *Lines) !void {
    const indent = Span{ .text = "  ", .style = .{ .fg = theme.FG } };
    const streaming = app.streaming and last;

    // Alat file yang dipakai model, supaya user selalu tahu file apa yang dibuka.
    for (msg.tools.items) |label| {
        var line = Line{};
        try line.spans.append(a, indent);
        try line.spans.append(a, .{ .text = try std.fmt.allocPrint(a, "◈ {s}", .{label}), .style = .{ .fg = HEAD } });
        try out.append(a, line);
    }

    if (streaming and msg.content.len() == 0) {
        var line = Line{};
        try line.spans.append(a, indent);
        var i: usize = 0;
        while (i < 10) : (i += 1) {
            try line.spans.append(a, .{ .text = anim.cycleGlyph(i, app.tick), .style = .{ .fg = anim.cycleColor(i, 10, app.tick) } });
        }
        try line.spans.append(a, .{ .text = " ", .style = .{ .fg = DIM } });
        try appendShimmer(a, &line, try std.fmt.allocPrint(a, "{s} lagi mikir", .{app.cfg.name}), app.tick, DIM);
        try line.spans.append(a, .{ .text = anim.dots(app.tick), .style = .{ .fg = DIM } });
        try out.append(a, line);
        return;
    }

    const start = out.len();
    const bar = markdown.Bar{ .text = "  ", .fg = theme.FG };
    try markdown.render(a, msg.content.items(), w -| 2, bar, out);
    if (streaming and out.len() > start) {
        const color = theme.mix(DIM, theme.ACCENT_B, theme.pulse(app.tick, 12.0));
        if (out.last()) |line| try line.spans.append(a, .{ .text = "▌", .style = .{ .fg = color } });
    }
    if (!streaming) {
        // "Claudia · model · 12s · 54.3 tok/s": nama berwarna, sisanya redup (seperti OpenCode).
        const tag = msg.tag;
        var name = tag;
        var rest: []const u8 = "";
        if (std.mem.indexOf(u8, tag, " · ")) |sep| {
            name = tag[0..sep];
            rest = try std.fmt.allocPrint(a, " · {s}", .{tag[sep + 3 ..]});
        }
        var line = Line{};
        try line.spans.append(a, indent);
        try line.spans.append(a, .{ .text = name, .style = .{ .fg = AI } });
        try line.spans.append(a, .{ .text = rest, .style = .{ .fg = DIM } });
        try out.append(a, line);
    }
}

fn appendShimmer(a: std.mem.Allocator, line: *Line, text: []const u8, tick: usize, base: theme.Color) !void {
    const n: f32 = @floatFromInt(@max(anim.countChars(text), 1));
    const center = @mod(@as(f32, @floatFromInt(tick)) * 0.012, 1.6) - 0.3;
    var it = anim.Utf8Iter{ .s = text };
    var i: usize = 0;
    while (it.next()) |cp| : (i += 1) {
        const glow = @max(0.0, 1.0 - @abs(@as(f32, @floatFromInt(i)) / n - center) / 0.25);
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch continue;
        try line.spans.append(a, .{
            .text = try a.dupe(u8, buf[0..len]),
            .style = .{ .fg = theme.mix(base, theme.FG, glow) },
        });
    }
}

/// Gambar baris ke area, hanya bagian yang terlihat (dengan gulir dari bawah).
pub fn draw(s: *Screen, area: Rect, lines: []const Line, scroll: usize) void {
    if (area.h == 0 or lines.len == 0) return;
    const height: usize = area.h;
    const end = lines.len - @min(scroll, lines.len);
    const start = end -| height;
    var y: u16 = area.y;
    var i = start;
    while (i < end and y < area.bottom()) : (i += 1) {
        var x = area.x;
        for (lines[i].spans.items) |span| {
            x = s.textBold(x, y, span.text, span.style.fg, span.style.bg, span.style.bold, area.right());
            if (x >= area.right()) break;
        }
        y += 1;
    }
}
