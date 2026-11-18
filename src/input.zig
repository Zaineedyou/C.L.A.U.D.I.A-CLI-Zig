//! Satu baris input dengan kursor (indeks dalam karakter). Port 1:1 dari src/input.rs.

const std = @import("std");
const util = @import("util.zig");
const width = @import("width.zig");

pub const Input = struct {
    chars: util.List(u21) = .{},
    cursor: usize = 0,

    pub fn init() Input {
        return .{};
    }

    pub fn isEmpty(self: *const Input) bool {
        return self.chars.len() == 0;
    }

    /// Tulis teks ke `out` (dikosongkan dulu).
    pub fn writeText(self: *const Input, a: std.mem.Allocator, out: *util.Str) !void {
        out.clear();
        for (self.chars.items) |cp| {
            var tmp: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &tmp) catch 0;
            try out.append(a, tmp[0..n]);
        }
    }

    pub fn text(self: *const Input, a: std.mem.Allocator) ![]u8 {
        var out = util.Str.init();
        defer out.deinit(a);
        try self.writeText(a, &out);
        return out.dupe(a);
    }

    pub fn clear(self: *Input) void {
        self.chars.clearRetainingCapacity();
        self.cursor = 0;
    }

    pub fn insert(self: *Input, a: std.mem.Allocator, c: u21) void {
        self.chars.insert(a, self.cursor, c) catch return;
        self.cursor += 1;
    }

    pub fn backspace(self: *Input) void {
        if (self.cursor > 0) {
            self.cursor -= 1;
            _ = self.chars.remove(self.cursor);
        }
    }

    pub fn delete(self: *Input) void {
        if (self.cursor < self.chars.len()) {
            _ = self.chars.remove(self.cursor);
        }
    }

    pub fn left(self: *Input) void {
        if (self.cursor > 0) self.cursor -= 1;
    }

    pub fn right(self: *Input) void {
        self.cursor = @min(self.cursor + 1, self.chars.len());
    }

    pub fn home(self: *Input) void {
        self.cursor = 0;
    }

    pub fn end(self: *Input) void {
        self.cursor = self.chars.len();
    }

    pub const Window = struct { visible: []u8, col: usize };

    /// Potongan teks yang muat di `width` kolom (minimal 1) dan kolom kursor di dalamnya.
    pub fn window(self: *const Input, a: std.mem.Allocator, w: usize) !Window {
        const width_cols = @max(w, 1);
        const first = (self.cursor + 1) -| width_cols;
        const last = @min(first + width_cols, self.chars.len());

        var vis = util.Str.init();
        defer vis.deinit(a);
        for (self.chars.items[first..last]) |cp| {
            var tmp: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &tmp) catch 0;
            try vis.append(a, tmp[0..n]);
        }

        var col: usize = 0;
        for (self.chars.items[first..self.cursor]) |cp| col += width.charWidth(cp);
        return .{ .visible = try vis.dupe(a), .col = col };
    }
};

test "typing and window" {
    var a = std.testing.allocator;
    var in = Input.init();
    defer in.chars.deinit(a);
    in.insert(a, 'h');
    in.insert(a, 'a');
    in.insert(a, 'i');
    const t = try in.text(a);
    defer a.free(t);
    try std.testing.expectEqualStrings("hai", t);
    const win = try in.window(a, 2);
    defer a.free(win.visible);
    try std.testing.expectEqualStrings("i", win.visible);
    try std.testing.expectEqual(@as(usize, 1), win.col);
}
