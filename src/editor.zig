//! Editor teks banyak baris untuk popup (dipakai edit system prompt). Port 1:1 dari src/editor.rs.

const std = @import("std");
const util = @import("util.zig");
const key = @import("key.zig");
const width = @import("width.zig");

pub const Editor = struct {
    lines: util.List(util.List(u21)) = .{},
    row: usize = 0,
    col: usize = 0,
    /// Umur popup dalam tick, untuk animasi buka.
    age: u8 = 0,

    pub fn init(a: std.mem.Allocator, raw: []const u8) !Editor {
        var e = Editor{};
        var it = std.mem.splitScalar(u8, raw, '\n');
        while (it.next()) |line| {
            var chars = util.List(u21).init();
            var view = std.unicode.Utf8View.init(line) catch {
                for (line) |b| try chars.append(a, b);
                try e.lines.append(a, chars);
                continue;
            };
            var vi = view.iterator();
            while (vi.nextCodepoint()) |cp| try chars.append(a, cp);
            try e.lines.append(a, chars);
        }
        if (e.lines.len() == 0) try e.lines.append(a, util.List(u21).init());
        e.row = e.lines.len() - 1;
        e.col = e.lines.items[e.row].len();
        return e;
    }

    pub fn writeText(self: *const Editor, a: std.mem.Allocator, out: *util.Str) !void {
        out.clear();
        for (self.lines.items, 0..) |line, i| {
            if (i > 0) try out.append(a, "\n");
            for (line.items) |cp| {
                var tmp: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &tmp) catch 0;
                try out.append(a, tmp[0..n]);
            }
        }
    }

    pub fn text(self: *const Editor, a: std.mem.Allocator) ![]u8 {
        var out = util.Str.init();
        defer out.deinit(a);
        try self.writeText(a, &out);
        return out.dupe(a);
    }

    pub fn deinit(self: *Editor, a: std.mem.Allocator) void {
        for (self.lines.items) |*line| line.deinit(a);
        self.lines.deinit(a);
    }

    pub fn handle(self: *Editor, a: std.mem.Allocator, code: key.Code) void {
        switch (code) {
            .char => |c| {
                self.lines.items[self.row].insert(a, self.col, c) catch return;
                self.col += 1;
            },
            .enter => {
                var rest = util.List(u21).init();
                const line = &self.lines.items[self.row];
                if (self.col < line.len()) {
                    rest.appendSlice(a, line.items[self.col..]) catch {};
                }
                line.items = line.items[0..self.col];
                self.row += 1;
                self.lines.insert(a, self.row, rest) catch return;
                self.col = 0;
            },
            .backspace => {
                if (self.col > 0) {
                    self.col -= 1;
                    _ = self.lines.items[self.row].remove(self.col);
                } else if (self.row > 0) {
                    var cur = self.lines.remove(self.row);
                    self.row -= 1;
                    self.col = self.lines.items[self.row].len();
                    self.lines.items[self.row].appendSlice(a, cur.items) catch {};
                    cur.deinit(a);
                }
            },
            .delete => {
                const line = &self.lines.items[self.row];
                if (self.col < line.len()) {
                    _ = line.remove(self.col);
                } else if (self.row + 1 < self.lines.len()) {
                    var next = self.lines.remove(self.row + 1);
                    self.lines.items[self.row].appendSlice(a, next.items) catch {};
                    next.deinit(a);
                }
            },
            .left => {
                if (self.col > 0) {
                    self.col -= 1;
                } else if (self.row > 0) {
                    self.row -= 1;
                    self.col = self.lines.items[self.row].len();
                }
            },
            .right => {
                if (self.col < self.lines.items[self.row].len()) {
                    self.col += 1;
                } else if (self.row + 1 < self.lines.len()) {
                    self.row += 1;
                    self.col = 0;
                }
            },
            .up => {
                if (self.row > 0) {
                    self.row -= 1;
                    self.col = @min(self.col, self.lines.items[self.row].len());
                }
            },
            .down => {
                if (self.row + 1 < self.lines.len()) {
                    self.row += 1;
                    self.col = @min(self.col, self.lines.items[self.row].len());
                }
            },
            .home => self.col = 0,
            .end => self.col = self.lines.items[self.row].len(),
            else => {},
        }
    }

    pub const Layout = struct { rows: []util.Str, cx: usize, cy: usize };

    /// Baris tampilan (di-wrap per karakter sesuai `width`) dan posisi kursor (x, y) di dalamnya.
    pub fn layout(self: *const Editor, a: std.mem.Allocator, w: usize) !Layout {
        const cols = @max(w, 2);
        var rows = util.List(util.Str).init();
        var cx: usize = 0;
        var cy: usize = 0;
        for (self.lines.items, 0..) |line, r| {
            var cur = util.Str.init();
            var cur_w: usize = 0;
            for (line.items, 0..) |cp, i| {
                const cw = width.charWidth(cp);
                if (cur_w + cw > cols and cur_w > 0) {
                    try rows.append(a, cur);
                    cur = util.Str.init();
                    cur_w = 0;
                }
                if (r == self.row and i == self.col) {
                    cx = cur_w;
                    cy = rows.len();
                }
                var tmp: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &tmp) catch 0;
                try cur.append(a, tmp[0..n]);
                cur_w += cw;
            }
            if (r == self.row and self.col >= line.len()) {
                if (cur_w >= cols) {
                    try rows.append(a, cur);
                    cur = util.Str.init();
                    cur_w = 0;
                }
                cx = cur_w;
                cy = rows.len();
            }
            try rows.append(a, cur);
        }
        return .{ .rows = rows.items, .cx = cx, .cy = cy };
    }
};

test "enter and backspace round trip" {
    var a = std.testing.allocator;
    var e = try Editor.init(a, "ab");
    defer e.deinit(a);
    e.handle(a, .left);
    e.handle(a, .enter);
    const t = try e.text(a);
    defer a.free(t);
    try std.testing.expectEqualStrings("a\nb", t);
}
