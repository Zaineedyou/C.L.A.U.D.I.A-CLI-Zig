//! Terminal mentah: mode raw, ukuran layar, dan pembacaan tombol/mouse.
//! Pengganti crossterm + ratatui::init/restore.

const std = @import("std");
const key = @import("key.zig");

const posix = std.posix;

var orig: posix.termios = undefined;
var have_orig = false;

pub fn enableRaw() void {
    orig = posix.tcgetattr(0) catch return;
    have_orig = true;
    var t = orig;
    t.iflag.BRKINT = false;
    t.iflag.ICRNL = false;
    t.iflag.INPCK = false;
    t.iflag.ISTRIP = false;
    t.iflag.IXON = false;
    t.oflag.OPOST = false;
    t.cflag.CSIZE = .CS8;
    t.cflag.PARENB = false;
    t.lflag.ECHO = false;
    t.lflag.ICANON = false;
    t.lflag.IEXTEN = false;
    t.lflag.ISIG = false;
    t.cc[@intFromEnum(posix.V.MIN)] = 1;
    t.cc[@intFromEnum(posix.V.TIME)] = 0;
    posix.tcsetattr(0, .NOW, t) catch {};
}

pub fn disableRaw() void {
    if (have_orig) posix.tcsetattr(0, .NOW, orig) catch {};
    have_orig = false;
}

pub fn enterAltScreen() void {
    writeAll("\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1006h\x1b[0m\x1b[2J\x1b[H");
}

pub fn leaveAltScreen() void {
    writeAll("\x1b[?1006l\x1b[?1000l\x1b[?25h\x1b[0m\x1b[?1049l");
}

pub fn writeAll(bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(1, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

pub const Size = struct { w: u16, h: u16 };

pub fn size() Size {
    var ws: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const rc = std.os.linux.ioctl(1, posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc == 0 and ws.col > 0 and ws.row > 0) {
        return .{ .w = ws.col, .h = ws.row };
    }
    return .{ .w = 100, .h = 30 };
}

pub const Event = union(enum) {
    key: key.Key,
    mouse: key.Mouse,
};

/// Byte yang sudah dibaca tapi belum diurai (satu pembacaan bisa berisi beberapa tombol).
var pending: [1024]u8 = undefined;
var pending_len: usize = 0;

/// Tunggu sampai ada input atau `timeout_ms` habis. `null` = tidak ada apa-apa (tick).
pub fn pollEvent(timeout_ms: i32) ?Event {
    if (pending_len > 0) {
        if (nextPending()) |ev| return ev;
    }
    var fds = [_]posix.pollfd{.{ .fd = 0, .events = posix.POLL.IN, .revents = 0 }};
    const n = posix.poll(&fds, timeout_ms) catch return null;
    if (n == 0) return null;
    const got = posix.read(0, pending[0..]) catch return null;
    if (got == 0) return null;
    pending_len = got;
    // Urutan escape bisa terpotong; tunggu sebentar sampai lengkap.
    var tries: usize = 0;
    while (incomplete(pending[0..pending_len]) and pending_len < pending.len and tries < 4) : (tries += 1) {
        var more = [_]posix.pollfd{.{ .fd = 0, .events = posix.POLL.IN, .revents = 0 }};
        const m = posix.poll(&more, 10) catch break;
        if (m == 0) break;
        const extra = posix.read(0, pending[pending_len..]) catch break;
        if (extra == 0) break;
        pending_len += extra;
    }
    return nextPending();
}

/// Ambil satu event dari antrean byte yang sudah dibaca.
fn nextPending() ?Event {
    if (pending_len == 0) return null;
    const used = eventLen(pending[0..pending_len]);
    if (used == 0) {
        pending_len = 0;
        return null;
    }
    const ev = parse(pending[0..used]);
    const rest = pending_len - used;
    std.mem.copyForwards(u8, pending[0..rest], pending[used..pending_len]);
    pending_len = rest;
    return ev;
}

/// Panjang satu urutan tombol; 0 kalau byte pertama tidak dikenal.
pub fn eventLen(b: []const u8) usize {
    if (b.len == 0) return 0;
    if (b[0] != 0x1b) {
        if (b[0] < 0x20 or b[0] == 0x7f) return 1;
        const n = std.unicode.utf8ByteSequenceLength(b[0]) catch return 1;
        return @min(n, b.len);
    }
    if (b.len == 1) return 1;
    if (b[1] == '[' or b[1] == 'O') {
        var i: usize = 2;
        while (i < b.len) : (i += 1) {
            if (b[i] >= 0x40 and b[i] <= 0x7e) return i + 1;
        }
        return b.len;
    }
    const n = std.unicode.utf8ByteSequenceLength(b[1]) catch return b.len;
    return @min(1 + n, b.len);
}

fn incomplete(b: []const u8) bool {
    if (b.len == 0) return false;
    if (b[0] != 0x1b) {
        if (b[0] < 0x20 or b[0] == 0x7f) return false;
        const n = std.unicode.utf8ByteSequenceLength(b[0]) catch return false;
        return b.len < n;
    }
    if (b.len == 1) return true;
    if (b[1] != '[' and b[1] != 'O') return false;
    var i: usize = 2;
    while (i < b.len) : (i += 1) {
        if (b[i] >= 0x40 and b[i] <= 0x7e) return false;
    }
    return true;
}

/// Urai satu urutan tombol; `null` kalau bukan tombol yang dipakai (mis. fokus masuk/keluar).
pub fn parse(bytes: []const u8) ?Event {
    if (bytes.len == 0) return null;
    if (bytes[0] == 0x1b) {
        if (bytes.len == 1) return .{ .key = .{ .code = .esc } };
        if (bytes[1] == '[' or bytes[1] == 'O') return parseCsi(bytes);
        if (bytes[1] == 0x1b) return .{ .key = .{ .code = .esc } };
        // Alt + karakter.
        const rest = bytes[1..];
        if (std.unicode.utf8ByteSequenceLength(rest[0])) |n| {
            if (rest.len >= n) {
                const cp = std.unicode.utf8Decode(rest[0..n]) catch return null;
                return .{ .key = .{ .code = .{ .char = cp }, .mods = .{ .alt = true } } };
            }
        } else |_| {}
        return null;
    }
    if (bytes[0] < 0x20 or bytes[0] == 0x7f) {
        const code: key.Code = switch (bytes[0]) {
            0x0d, 0x0a => .enter,
            0x09 => .tab,
            0x7f, 0x08 => return .{ .key = .{ .code = .backspace } },
            else => .{ .char = @intCast(bytes[0] + 0x60) },
        };
        // Ctrl+huruf datang sebagai byte 1..26 (a=1, z=26).
        return .{ .key = .{ .code = code, .mods = .{ .ctrl = true } } };
    }
    const n = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return null;
    if (bytes.len < n) return null;
    const cp = std.unicode.utf8Decode(bytes[0..n]) catch return null;
    return .{ .key = .{ .code = .{ .char = cp } } };
}

fn modOf(param: []const u8) key.Mods {
    var mods = key.Mods{};
    const n = std.fmt.parseInt(u8, param, 10) catch return mods;
    const m = n -| 1;
    if (m & 1 != 0) mods.shift = true;
    if (m & 2 != 0) mods.alt = true;
    if (m & 4 != 0) mods.ctrl = true;
    return mods;
}

fn parseCsi(bytes: []const u8) ?Event {
    // ESC [ < b ; x ; y M  → mouse SGR
    if (bytes.len > 3 and bytes[2] == '<') {
        var it = std.mem.splitScalar(u8, bytes[3..], ';');
        const b = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        const x = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        const ypart = it.next() orelse return null;
        const y = std.fmt.parseInt(u32, std.mem.trimEnd(u8, ypart, "Mms"), 10) catch return null;
        const press = std.mem.indexOfAny(u8, ypart, "M") != null;
        const col: u16 = @intCast(@max(x, 1) - 1);
        const row: u16 = @intCast(@max(y, 1) - 1);
        const kind: key.MouseKind = if (b & 64 != 0)
            (if (b & 1 != 0) key.MouseKind.scroll_down else key.MouseKind.scroll_up)
        else if (b & 32 != 0)
            key.MouseKind.moved
        else if (press)
            (if (b & 2 != 0) key.MouseKind{ .drag = .right } else if (b & 1 != 0) key.MouseKind{ .drag = .middle } else key.MouseKind{ .down = .left })
        else
            (if (b & 2 != 0) key.MouseKind{ .up = .right } else if (b & 1 != 0) key.MouseKind{ .up = .middle } else key.MouseKind{ .up = .left });
        return .{ .mouse = .{ .kind = kind, .column = col, .row = row } };
    }

    // ESC [ 1;5A  → Ctrl+Up, dst.
    var body = bytes[2..];
    var final: u8 = 0;
    if (body.len > 0) {
        final = body[body.len - 1];
        if (final >= '0' and final <= '9') return null;
        body = body[0 .. body.len - 1];
    }
    var mods = key.Mods{};
    var first: []const u8 = body;
    if (std.mem.indexOfScalar(u8, body, ';')) |semi| {
        first = body[0..semi];
        mods = modOf(body[semi + 1 ..]);
    }
    const code: key.Code = switch (final) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        'Z' => .back_tab,
        '~' => blk: {
            const n = std.fmt.parseInt(u16, first, 10) catch break :blk .other;
            break :blk switch (n) {
                1, 7 => .home,
                2 => .insert,
                3 => .delete,
                4, 8 => .end,
                5 => .page_up,
                6 => .page_down,
                11 => .{ .f = 1 },
                12 => .{ .f = 2 },
                13 => .{ .f = 3 },
                14 => .{ .f = 4 },
                15 => .{ .f = 5 },
                17 => .{ .f = 6 },
                18 => .{ .f = 7 },
                19 => .{ .f = 8 },
                20 => .{ .f = 9 },
                21 => .{ .f = 10 },
                23 => .{ .f = 11 },
                24 => .{ .f = 12 },
                else => .other,
            };
        },
        'P', 'Q', 'R', 'S' => .other,
        else => return null,
    };
    return .{ .key = .{ .code = code, .mods = mods } };
}

test "parse arrows and letters" {
    const up = parse("\x1b[A").?;
    try std.testing.expect(up.key.is(.up));
    const ch = parse("a").?;
    try std.testing.expect(ch.key.is(.{ .char = 'a' }));
    const ctrl = parse("\x1b[1;5C").?;
    try std.testing.expect(ctrl.key.is(.right));
    try std.testing.expect(ctrl.key.mods.ctrl);
}

test "parse ctrl letters" {
    const p = parse("\x10").?; // Ctrl+P
    try std.testing.expect(p.key.is(.{ .char = 'p' }));
    try std.testing.expect(p.key.mods.ctrl);
    const o = parse("\x0f").?; // Ctrl+O
    try std.testing.expect(o.key.is(.{ .char = 'o' }));
    try std.testing.expect(o.key.mods.ctrl);
    const n = parse("\x0e").?; // Ctrl+N
    try std.testing.expect(n.key.is(.{ .char = 'n' }));
    try std.testing.expect(n.key.mods.ctrl);
}
