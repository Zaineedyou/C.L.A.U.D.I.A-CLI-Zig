//! Akses file atas perintah user: browser file, lampiran (`/attach`, `@path`). Tidak ada baca otomatis.
//! Port 1:1 dari src/files.rs.

const std = @import("std");
const util = @import("util.zig");
const fsx = @import("fsx.zig");
const key = @import("key.zig");
const picker = @import("picker.zig");

/// Batas baca satu file dan total lampiran per pesan (teks saja).
pub const MAX_FILE: usize = 100_000;
pub const MAX_TOTAL: usize = 300_000;
const MAX_ENTRIES: usize = 5_000;
const MAX_LISTING: usize = 300;

/// File atau folder yang dilampirkan user ke pesan berikutnya.
pub const Attachment = struct {
    path: []const u8,
    /// Teks pendek di layar, mis. "main.rs (12.3 KB)".
    label: []const u8,
    /// Blok yang disambung ke pesan user waktu dikirim ke model.
    block: []const u8,
    size: usize,
};

/// "~" dan "~/x" jadi folder home; jalur relatif dihitung dari folder kerja.
pub fn expand(a: std.mem.Allocator, raw_in: []const u8) []const u8 {
    const raw = std.mem.trim(u8, raw_in, " \t\r\n\"'");
    const home = fsx.homeAlloc(a);
    if (std.mem.eql(u8, raw, "~")) return home;
    if (std.mem.startsWith(u8, raw, "~/")) {
        return std.fs.path.join(a, &.{ home, raw[2..] }) catch home;
    }
    if (std.fs.path.isAbsolute(raw)) return a.dupe(u8, raw) catch raw;
    const cwd = fsx.cwdAlloc(a);
    return std.fs.path.join(a, &.{ cwd, raw }) catch raw;
}

pub fn humanSize(a: std.mem.Allocator, bytes: u64) []const u8 {
    const UNITS = [_][]const u8{ "B", "KB", "MB", "GB" };
    var value: f64 = @floatFromInt(bytes);
    var unit: usize = 0;
    while (value >= 1024.0 and unit < UNITS.len - 1) {
        value /= 1024.0;
        unit += 1;
    }
    if (unit == 0) return std.fmt.allocPrint(a, "{d} B", .{bytes}) catch "?";
    return std.fmt.allocPrint(a, "{d:.1} {s}", .{ value, UNITS[unit] }) catch "?";
}

fn basename(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

/// Baca file teks (atau daftar isi folder) jadi lampiran. File biner ditolak.
pub fn readAttachment(a: std.mem.Allocator, path: []const u8) !Attachment {
    const shown = path;
    const st = fsx.stat(path) catch return error.CannotRead;
    const name = basename(path);

    if (st.is_dir) {
        const entries = try fsx.listDir(a, path, MAX_ENTRIES);
        var names = util.List([]const u8).init();
        for (entries) |e| {
            const line = if (e.is_dir)
                try std.fmt.allocPrint(a, "{s}/", .{e.name})
            else
                try a.dupe(u8, e.name);
            try names.append(a, line);
        }
        std.mem.sort([]const u8, names.items, {}, lessThanStr);
        const total = names.items.len;
        const shown_n = @min(total, MAX_LISTING);

        var listing = util.Str.init();
        for (names.items[0..shown_n], 0..) |n, i| {
            if (i > 0) try listing.append(a, "\n");
            try listing.append(a, n);
        }
        if (total > MAX_LISTING) {
            try listing.appendFmt(a, "\n... ({d} lainnya)", .{total - MAX_LISTING});
        }
        const block = try std.fmt.allocPrint(a, "\n\n[Lampiran dari user: isi folder {s}]\n```\n{s}\n```", .{ shown, listing.items() });
        return .{
            .path = try a.dupe(u8, path),
            .label = try std.fmt.allocPrint(a, "{s}/ ({d} item)", .{ name, total }),
            .size = block.len,
            .block = block,
        };
    }

    const bytes = fsx.readFileAlloc(a, path, MAX_FILE + 1) catch return error.CannotRead;
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.Binary;
    const truncated = bytes.len > MAX_FILE;
    const text = if (truncated) bytes[0..MAX_FILE] else bytes;
    const note = if (truncated)
        try std.fmt.allocPrint(a, " (dipotong: {s} pertama dari {s})", .{ humanSize(a, MAX_FILE), humanSize(a, st.size) })
    else
        "";
    const block = try std.fmt.allocPrint(a, "\n\n[Lampiran dari user: {s}{s}]\n```\n{s}\n```", .{ shown, note, text });
    return .{
        .path = try a.dupe(u8, path),
        .label = try std.fmt.allocPrint(a, "{s} ({s})", .{ name, humanSize(a, st.size) }),
        .size = block.len,
        .block = block,
    };
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub const Entry = struct {
    name: []const u8,
    is_dir: bool,
    size: u64,
};

/// Hasil menekan tombol di browser.
pub const Action = union(enum) {
    none,
    close,
    /// Lampirkan `path`; `stay` = browser tetap terbuka buat memilih lagi.
    attach: struct { path: []const u8, stay: bool },
};

/// Browser file satu folder, dengan filter ketik-langsung.
pub const Browser = struct {
    dir: []const u8,
    entries: util.List(Entry) = .{},
    filter: util.Str = .{},
    selected: usize = 0,
    show_hidden: bool = false,
    err: ?[]const u8 = null,
    /// Umur popup dalam tick, untuk animasi buka.
    age: u8 = 0,

    pub fn init(a: std.mem.Allocator, dir: []const u8) Browser {
        var b = Browser{ .dir = a.dupe(u8, dir) catch dir };
        b.reload(a);
        return b;
    }

    fn reload(self: *Browser, a: std.mem.Allocator) void {
        self.selected = 0;
        self.filter.clear();
        const listed = fsx.listDir(a, self.dir, MAX_ENTRIES) catch |e| {
            self.entries.clearRetainingCapacity();
            self.err = std.fmt.allocPrint(a, "{s}: {s}", .{ self.dir, @errorName(e) }) catch "tidak bisa dibaca";
            return;
        };
        self.entries.clearRetainingCapacity();
        for (listed) |entry| self.entries.append(a, .{ .name = entry.name, .is_dir = entry.is_dir, .size = entry.size }) catch {};
        sortEntries(self.entries.items);
    }

    fn sortEntries(items: []Entry) void {
        const S = struct {
            fn lessThan(_: void, x: Entry, y: Entry) bool {
                if (x.is_dir != y.is_dir) return x.is_dir;
                var i: usize = 0;
                while (i < x.name.len and i < y.name.len) : (i += 1) {
                    const cx = std.ascii.toLower(x.name[i]);
                    const cy = std.ascii.toLower(y.name[i]);
                    if (cx != cy) return cx < cy;
                }
                return x.name.len < y.name.len;
            }
        };
        std.mem.sort(Entry, items, {}, S.lessThan);
    }

    /// Pindah folder; kalau folder tujuan tidak bisa dibaca, tetap di sini dan tampilkan alasannya.
    fn goTo(self: *Browser, a: std.mem.Allocator, dir: []const u8) void {
        const st = fsx.stat(dir) catch |e| {
            self.err = std.fmt.allocPrint(a, "{s}: {s}", .{ dir, @errorName(e) }) catch "tidak bisa dibuka";
            return;
        };
        if (!st.is_dir) {
            self.err = std.fmt.allocPrint(a, "{s}: bukan folder", .{dir}) catch "tidak bisa dibuka";
            return;
        }
        self.dir = a.dupe(u8, dir) catch dir;
        self.err = null;
        self.reload(a);
    }

    fn goUp(self: *Browser, a: std.mem.Allocator) void {
        if (std.fs.path.dirname(self.dir)) |parent| self.goTo(a, parent);
    }

    pub fn matches(self: *const Browser, e: Entry) bool {
        if (!self.show_hidden and std.mem.startsWith(u8, e.name, ".")) return false;
        const q = self.filter.items();
        if (q.len == 0) return true;
        return picker.containsIgnoreCase(e.name, q);
    }

    /// Entri yang lolos filter dan aturan file tersembunyi.
    pub fn visibleCount(self: *const Browser) usize {
        var n: usize = 0;
        for (self.entries.items) |e| {
            if (self.matches(e)) n += 1;
        }
        return n;
    }

    pub fn visibleAt(self: *const Browser, index: usize) ?*const Entry {
        var n: usize = 0;
        for (self.entries.items) |*e| {
            if (self.matches(e.*)) {
                if (n == index) return e;
                n += 1;
            }
        }
        return null;
    }

    fn current(self: *const Browser) ?*const Entry {
        return self.visibleAt(self.selected);
    }

    fn moveBy(self: *Browser, delta: isize) void {
        const count = self.visibleCount();
        const last: isize = @intCast(if (count == 0) 0 else count - 1);
        const next = @as(isize, @intCast(self.selected)) + delta;
        self.selected = @intCast(std.math.clamp(next, 0, last));
    }

    pub fn handle(self: *Browser, a: std.mem.Allocator, code: key.Code, ctrl: bool) Action {
        switch (code) {
            .esc => return .close,
            .up => self.moveBy(-1),
            .down => self.moveBy(1),
            .page_up => self.moveBy(-10),
            .page_down => self.moveBy(10),
            .left => self.goUp(a),
            .backspace => {
                if (self.filter.len() > 0) {
                    self.filter.len_ -= 1;
                    self.selected = 0;
                } else self.goUp(a);
            },
            .enter, .right => {
                if (self.current()) |e| {
                    if (e.is_dir) {
                        const next = std.fs.path.join(a, &.{ self.dir, e.name }) catch return .none;
                        self.goTo(a, next);
                    } else if (code == .enter) {
                        return .{ .attach = .{ .path = std.fs.path.join(a, &.{ self.dir, e.name }) catch self.dir, .stay = false } };
                    }
                }
            },
            .tab => {
                if (self.current()) |e| {
                    return .{ .attach = .{ .path = std.fs.path.join(a, &.{ self.dir, e.name }) catch self.dir, .stay = true } };
                }
            },
            .char => |c| {
                if (ctrl) {
                    switch (c) {
                        'a' => return .{ .attach = .{ .path = self.dir, .stay = true } },
                        't' => {
                            self.show_hidden = !self.show_hidden;
                            self.selected = 0;
                        },
                        'g' => self.goTo(a, fsx.homeAlloc(a)),
                        'r' => self.goTo(a, "/"),
                        else => {},
                    }
                } else {
                    var tmp: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(c, &tmp) catch 0;
                    self.filter.append(a, tmp[0..n]) catch {};
                    self.selected = 0;
                }
            },
            else => {},
        }
        return .none;
    }
};

test "human size picks a unit" {
    var a = std.testing.allocator;
    const s1 = humanSize(a, 512);
    defer a.free(s1);
    try std.testing.expectEqualStrings("512 B", s1);
    const s2 = humanSize(a, 2048);
    defer a.free(s2);
    try std.testing.expectEqualStrings("2.0 KB", s2);
}
