//! Popup pilihan dengan filter ketik-langsung. Port 1:1 dari src/picker.rs.

const std = @import("std");
const util = @import("util.zig");
const key = @import("key.zig");

/// Jumlah tick animasi membuka popup.
pub const POPUP_FRAMES: u8 = 6;

pub const Kind = enum {
    provider,
    model,
    /// Pilih provider yang mau dihubungkan (lanjut ke dialog API key).
    connect,
    /// Palet perintah (Ctrl+P).
    command,
};

pub const Item = struct {
    id: []const u8,
    label: []const u8,
    hint: []const u8,
    current: bool,
};

pub const Picker = struct {
    kind: Kind,
    items: util.List(Item) = .{},
    filter: util.Str = .{},
    selected: usize = 0,
    loading: bool = false,
    /// Umur popup dalam tick, untuk animasi buka.
    age: u8 = 0,

    pub fn init(kind: Kind, a: std.mem.Allocator, items: []const Item, loading: bool) !Picker {
        var p = Picker{ .kind = kind, .loading = loading };
        try p.items.appendSlice(a, items);
        p.selected = p.firstCurrent();
        return p;
    }

    fn firstCurrent(self: *const Picker) usize {
        for (self.items.items, 0..) |it, i| {
            if (it.current) return i;
        }
        return 0;
    }

    fn matches(self: *const Picker, it: Item) bool {
        const q = self.filter.items();
        if (q.len == 0) return true;
        return containsIgnoreCase(it.label, q) or containsIgnoreCase(it.id, q) or containsIgnoreCase(it.hint, q);
    }

    /// Item yang lolos filter.
    pub fn visible(self: *const Picker, a: std.mem.Allocator) !util.List(*const Item) {
        var out = util.List(*const Item).init();
        for (self.items.items) |*it| {
            if (self.matches(it.*)) try out.append(a, it);
        }
        return out;
    }

    pub fn visibleCount(self: *const Picker) usize {
        var n: usize = 0;
        for (self.items.items) |it| {
            if (self.matches(it)) n += 1;
        }
        return n;
    }

    pub fn visibleAt(self: *const Picker, index: usize) ?*const Item {
        var n: usize = 0;
        for (self.items.items) |*it| {
            if (self.matches(it.*)) {
                if (n == index) return it;
                n += 1;
            }
        }
        return null;
    }

    pub fn selectedItem(self: *const Picker) ?*const Item {
        return self.visibleAt(self.selected);
    }

    pub fn setItems(self: *Picker, a: std.mem.Allocator, items: []const Item) void {
        self.items.clearRetainingCapacity();
        self.items.appendSlice(a, items) catch {};
        self.loading = false;
        self.selected = if (self.filter.len() == 0) self.firstCurrent() else 0;
    }

    pub fn handle(self: *Picker, a: std.mem.Allocator, code: key.Code) void {
        switch (code) {
            .up => self.moveBy(-1),
            .down => self.moveBy(1),
            .page_up => self.moveBy(-10),
            .page_down => self.moveBy(10),
            .backspace => {
                if (self.filter.len() > 0) self.filter.len_ -= 1;
                self.selected = 0;
            },
            .char => |c| {
                var tmp: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &tmp) catch 0;
                self.filter.append(a, tmp[0..n]) catch {};
                self.selected = 0;
            },
            else => {},
        }
    }

    fn moveBy(self: *Picker, delta: isize) void {
        const count = self.visibleCount();
        const last: isize = @as(isize, @intCast(if (count == 0) 0 else count - 1));
        const next = @as(isize, @intCast(self.selected)) + delta;
        self.selected = @intCast(std.math.clamp(next, 0, last));
    }
};

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

test "filter is case insensitive" {
    const a = std.testing.allocator;
    const items = [_]Item{
        .{ .id = "Groq", .label = "Groq", .hint = "", .current = false },
        .{ .id = "openai", .label = "OpenAI", .hint = "", .current = false },
    };
    var p = try Picker.init(.provider, a, &items, false);
    defer p.items.deinit(a);
    defer p.filter.deinit(a);
    p.handle(a, .{ .char = 'O' });
    p.handle(a, .{ .char = 'p' });
    try std.testing.expectEqual(@as(usize, 1), p.visibleCount());
    try std.testing.expectEqualStrings("openai", p.selectedItem().?.id);
}
