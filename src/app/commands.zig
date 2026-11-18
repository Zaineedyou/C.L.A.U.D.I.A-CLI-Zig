//! Perintah slash: daftar, filter, dan eksekusi. Port 1:1 dari src/app/commands.rs.

const std = @import("std");
const util = @import("../util.zig");
const app_mod = @import("../app.zig");
const files = @import("../files.zig");
const provider = @import("../provider.zig");
const tools = @import("../tools.zig");
const fsx = @import("../fsx.zig");

const App = app_mod.App;

const HELP = "Ketik / buat daftar perintah · Ctrl+P palet perintah · Ctrl+O model · /connect buat isi API key";

/// Perintah slash, dipakai dropdown "/" dan palet perintah (Ctrl+P).
pub const Cmd = struct {
    name: []const u8,
    desc: []const u8,
    /// Perintah yang butuh argumen: dilengkapi dulu, tidak langsung dijalankan.
    arg: bool,
};

pub const COMMANDS = [_]Cmd{
    .{ .name = "connect", .desc = "Hubungkan provider dan masukin API key", .arg = false },
    .{ .name = "provider", .desc = "Ganti provider", .arg = false },
    .{ .name = "model", .desc = "Ganti model", .arg = false },
    .{ .name = "system", .desc = "Edit system prompt", .arg = false },
    .{ .name = "files", .desc = "Jelajahi file di perangkat dan lampirkan", .arg = false },
    .{ .name = "attach", .desc = "Lampirkan file/folder: /attach <path>", .arg = true },
    .{ .name = "akses", .desc = "Akses file buat model: auto / on / off", .arg = true },
    .{ .name = "detach", .desc = "Lepas semua lampiran", .arg = false },
    .{ .name = "new", .desc = "Sesi baru", .arg = false },
    .{ .name = "close", .desc = "Tutup sesi ini", .arg = false },
    .{ .name = "clear", .desc = "Bersihkan sesi ini", .arg = false },
    .{ .name = "tab", .desc = "Pindah ke tab nomor ...", .arg = true },
    .{ .name = "key", .desc = "Isi API key provider ini", .arg = true },
    .{ .name = "disconnect", .desc = "Hapus API key provider ini", .arg = false },
    .{ .name = "help", .desc = "Bantuan", .arg = false },
    .{ .name = "exit", .desc = "Keluar", .arg = false },
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

/// Perintah yang cocok dengan `query` (tanpa "/"): yang diawali query dulu, lalu urut abjad.
pub fn filter(a: std.mem.Allocator, query: []const u8, out: *util.List(*const Cmd)) void {
    _ = a;
    for (&COMMANDS) |*c| {
        if (containsIgnoreCase(c.name, query) or containsIgnoreCase(c.desc, query)) {
            // Urutkan: yang namanya diawali query di depan, lalu abjad.
            var idx: usize = 0;
            const prefixed = startsWithIgnoreCase(c.name, query);
            while (idx < out.len()) : (idx += 1) {
                const other = out.items[idx];
                const other_prefixed = startsWithIgnoreCase(other.name, query);
                if (prefixed and !other_prefixed) break;
                if (prefixed == other_prefixed and std.mem.order(u8, c.name, other.name) == .lt) break;
            }
            out.insert(std.heap.c_allocator, idx, c) catch {};
        }
    }
}

pub fn run(self: *App, line_in: []const u8) void {
    const line = std.mem.trim(u8, line_in, " \t\r\n");
    var cmd = line;
    var arg: []const u8 = "";
    if (std.mem.indexOfScalar(u8, line, ' ')) |sp| {
        cmd = line[0..sp];
        arg = std.mem.trim(u8, line[sp + 1 ..], " \t");
    }

    const a = self.a;
    const is = struct {
        fn f(x: []const u8, y: []const u8) bool {
            return std.mem.eql(u8, x, y);
        }
    }.f;

    if (is(cmd, "/exit") or is(cmd, "/quit")) {
        self.quit = true;
    } else if (is(cmd, "/clear")) {
        self.clear();
    } else if (is(cmd, "/help")) {
        self.info(HELP);
    } else if (is(cmd, "/provider") and arg.len == 0) {
        self.openProviders();
    } else if (is(cmd, "/provider")) {
        if (provider.find(arg)) |i| {
            self.setProvider(i);
        } else {
            self.err(std.fmt.allocPrint(a, "provider '{s}' nggak ada (Ctrl+P buat daftar)", .{arg}) catch "provider nggak ada");
        }
    } else if ((is(cmd, "/model") or is(cmd, "/models")) and arg.len == 0) {
        self.openModels();
    } else if (is(cmd, "/model") or is(cmd, "/models")) {
        self.setModel(arg);
    } else if (is(cmd, "/connect") and arg.len == 0) {
        self.openConnect();
    } else if (is(cmd, "/connect")) {
        if (provider.find(arg)) |i| {
            self.beginConnect(i);
        } else {
            self.err(std.fmt.allocPrint(a, "provider '{s}' nggak ada (ketik /connect buat daftar)", .{arg}) catch "provider nggak ada");
        }
    } else if (is(cmd, "/key") and arg.len == 0) {
        self.err("pakai: /key <api-key> (atau /connect buat dialognya)");
    } else if (is(cmd, "/key")) {
        const p = self.cfg.current();
        self.cfg.setKey(p.id, arg);
        self.info(std.fmt.allocPrint(a, "API key {s} disimpan", .{p.name}) catch "API key disimpan");
    } else if (is(cmd, "/disconnect")) {
        const p = self.cfg.current();
        self.cfg.forgetKey(p.id);
        self.info(std.fmt.allocPrint(a, "API key {s} dihapus", .{p.name}) catch "API key dihapus");
    } else if ((is(cmd, "/system") or is(cmd, "/prompt")) and arg.len == 0) {
        self.openSystemEditor();
    } else if ((is(cmd, "/system") or is(cmd, "/prompt")) and is(arg, "reset")) {
        self.cfg.resetSystem();
        self.info("system prompt dikembalikan ke bawaan");
    } else if (is(cmd, "/system") or is(cmd, "/prompt")) {
        self.cfg.setSystem(arg);
        self.info("system prompt disimpan, berlaku mulai pesan berikutnya");
    } else if (((is(cmd, "/files") or is(cmd, "/ls")) and arg.len == 0) or (is(cmd, "/attach") and arg.len == 0)) {
        self.openFiles(null);
    } else if (is(cmd, "/files") or is(cmd, "/ls")) {
        const dir = files.expand(a, arg);
        if (fsx.statOrNull(dir)) |st| {
            if (st.is_dir) {
                self.openFiles(dir);
            } else {
                self.err(std.fmt.allocPrint(a, "{s} bukan folder", .{dir}) catch "bukan folder");
            }
        } else {
            self.err(std.fmt.allocPrint(a, "{s} bukan folder", .{dir}) catch "bukan folder");
        }
    } else if (is(cmd, "/attach")) {
        _ = self.attach(files.expand(a, arg));
    } else if (is(cmd, "/akses") and arg.len == 0) {
        self.info(std.fmt.allocPrint(a, "akses file model: {s} (ubah: /akses auto|on|off)", .{self.access.label()}) catch "akses file model");
    } else if (is(cmd, "/akses")) {
        if (tools.Access.parse(arg)) |access| {
            self.access = access;
            self.info(std.fmt.allocPrint(a, "akses file model: {s}", .{access.label()}) catch "akses file model");
        } else {
            self.err("pakai: /akses auto|on|off");
        }
    } else if (is(cmd, "/detach")) {
        self.attachments.clearRetainingCapacity();
        self.info("lampiran dilepas");
    } else if (is(cmd, "/new")) {
        self.newTab();
    } else if (is(cmd, "/close")) {
        self.closeTab();
    } else if (is(cmd, "/tab")) {
        const n = std.fmt.parseInt(usize, arg, 10) catch 0;
        if (n >= 1 and n <= self.tabs.len()) {
            self.switchTab(n - 1);
        } else {
            self.err("pakai: /tab <nomor>");
        }
    } else {
        self.err(std.fmt.allocPrint(a, "perintah nggak dikenal: {s}", .{cmd}) catch "perintah nggak dikenal");
    }
}
