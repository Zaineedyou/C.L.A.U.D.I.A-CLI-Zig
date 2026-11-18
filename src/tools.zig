//! Alat baca file untuk model (read-only). Port 1:1 dari src/tools.rs.
//! Alat cuma ditawarkan ke model pada giliran yang user minta secara eksplisit.

const std = @import("std");
const util = @import("util.zig");
const fsx = @import("fsx.zig");
const files = @import("files.zig");

const READ_CAP: u64 = 2_000_000;
const MAX_OUT: usize = 60_000;
const MAX_LIST: usize = 300;
const MAX_HITS: usize = 100;
const MAX_VISITED: usize = 20_000;
const MAX_DEPTH: usize = 8;
const SKIP_DIRS = [_][]const u8{ ".git", "node_modules" };

/// Ditambahkan ke system prompt hanya pada giliran yang alat file ditawarkan.
pub const TOOL_PROMPT =
    "\n\nKamu punya akses baca (read-only) ke file di perangkat user lewat alat list_dir, read_file, " ++
    "find_files, dan grep. Pakai alat itu HANYA kalau user secara eksplisit menyuruhmu melihat, membaca, atau " ++
    "mencari file/folder di pesan terbarunya. Jangan menjelajah sendiri, jangan membuka file yang tidak disebut atau " ++
    "tidak perlu, dan kalau user belum menyebut lokasinya, tanya dulu. Baca seperlunya saja.";

/// Seberapa bebas model boleh membaca file.
pub const Access = enum {
    /// Alat ditawarkan hanya kalau pesan user jelas meminta soal file.
    auto,
    /// Alat selalu ditawarkan (model tetap diminta menunggu perintah user).
    always,
    /// Alat tidak pernah ditawarkan.
    never,

    pub fn parse(text: []const u8) ?Access {
        const t = std.mem.trim(u8, text, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(t, "auto") or std.ascii.eqlIgnoreCase(t, "otomatis")) return .auto;
        if (std.ascii.eqlIgnoreCase(t, "on") or std.ascii.eqlIgnoreCase(t, "selalu") or std.ascii.eqlIgnoreCase(t, "always")) return .always;
        if (std.ascii.eqlIgnoreCase(t, "off") or std.ascii.eqlIgnoreCase(t, "mati") or std.ascii.eqlIgnoreCase(t, "never")) return .never;
        return null;
    }

    pub fn label(self: Access) []const u8 {
        return switch (self) {
            .auto => "otomatis (kalau diminta)",
            .always => "selalu tersedia",
            .never => "mati",
        };
    }
};

const ACTIONS = [_][]const u8{
    "baca",  "bacain",  "lihat", "liat",  "buka", "cek",    "periksa", "cari",   "temuin",   "temukan", "tampilkan",
    "list",  "show",    "read",  "open",  "find", "search", "cat",     "ls",     "grep",     "scan",    "telusuri",
};
const OBJECTS = [_][]const u8{
    "file", "folder", "direktori", "directory", "dir",  "isi",     "path",   "storage", "sdcard",
    "repo", "kode",   "code",      "proyek",    "project", "script", "log", "dokumen", "catatan",
};
const STRONG_OBJECTS = [_][]const u8{ "folder", "direktori", "directory", "sdcard", "storage" };

fn inList(list: []const []const u8, word: []const u8) bool {
    for (list) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

/// Apakah pesan ini jelas meminta sesuatu soal file/folder?
pub fn asksForFiles(text: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |raw| {
        const w = std.mem.trim(u8, raw, "\"'`,.?!:;()");
        if (w.len > 1 and w[0] == '@') return true;
        if (w.len > 1 and w[0] == '/') return true;
        if (std.mem.startsWith(u8, w, "~/")) return true;
        if (std.mem.startsWith(u8, w, "./")) return true;
        if (std.mem.startsWith(u8, w, "../")) return true;
    }

    var has_action = false;
    var has_object = false;
    var has_strong = false;
    var i: usize = 0;
    const lower_buf = text;
    while (i < lower_buf.len) {
        while (i < lower_buf.len and !isWordChar(lower_buf[i])) i += 1;
        const start = i;
        while (i < lower_buf.len and isWordChar(lower_buf[i])) i += 1;
        if (i == start) break;
        var word_buf: [128]u8 = undefined;
        const word = lower_buf[start..i];
        if (word.len > word_buf.len) continue;
        const w = std.ascii.lowerString(word_buf[0..word.len], word);
        if (inList(&ACTIONS, w)) has_action = true;
        if (inList(&OBJECTS, w)) has_object = true;
        if (inList(&STRONG_OBJECTS, w)) has_strong = true;
    }
    return (has_action and has_object) or has_strong;
}

/// Definisi alat dalam format function-calling OpenAI (JSON siap pakai).
pub const DEFINITIONS =
    \\[
    \\{"type":"function","function":{"name":"list_dir","description":"Daftar isi sebuah folder di perangkat user (nama, tipe, ukuran). Hanya dipakai kalau user menyuruh.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Path folder; mendukung ~ dan path relatif."},"show_hidden":{"type":"boolean","description":"Sertakan file tersembunyi (diawali titik)."}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"read_file","description":"Baca file teks. Untuk file besar pakai start_line dan max_lines. Hanya dipakai kalau user menyuruh.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Path file."},"start_line":{"type":"integer","description":"Mulai dari baris ke-n (default 1)."},"max_lines":{"type":"integer","description":"Jumlah baris maksimal (default 400)."}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"find_files","description":"Cari file atau folder yang namanya mengandung teks tertentu di bawah sebuah folder (.git dan node_modules dilewati).","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Folder awal pencarian."},"name":{"type":"string","description":"Teks yang harus ada di nama (tidak peka huruf besar/kecil)."}},"required":["path","name"]}}},
    \\{"type":"function","function":{"name":"grep","description":"Cari teks di dalam file teks, di satu file atau di bawah sebuah folder (.git dan node_modules dilewati).","parameters":{"type":"object","properties":{"path":{"type":"string","description":"File atau folder yang dicari."},"query":{"type":"string","description":"Teks yang dicari (tidak peka huruf besar/kecil)."}},"required":["path","query"]}}}
    \\]
;

/// Argumen yang sudah diurai dari JSON model.
pub const Args = struct {
    path: []const u8 = "?",
    name: []const u8 = "?",
    query: []const u8 = "?",
    start_line: u64 = 1,
    max_lines: u64 = 400,
    show_hidden: bool = false,
};

/// Teks pendek buat ditampilkan ke user setiap kali model memakai alat.
pub fn label(a: std.mem.Allocator, name: []const u8, args: Args) []const u8 {
    if (std.mem.eql(u8, name, "list_dir")) return std.fmt.allocPrint(a, "lihat folder {s}", .{args.path}) catch name;
    if (std.mem.eql(u8, name, "read_file")) return std.fmt.allocPrint(a, "baca {s}", .{args.path}) catch name;
    if (std.mem.eql(u8, name, "find_files")) return std.fmt.allocPrint(a, "cari nama '{s}' di {s}", .{ args.name, args.path }) catch name;
    if (std.mem.eql(u8, name, "grep")) return std.fmt.allocPrint(a, "cari teks '{s}' di {s}", .{ args.query, args.path }) catch name;
    return name;
}

fn cap(a: std.mem.Allocator, text_in: []const u8) []const u8 {
    if (text_in.len <= MAX_OUT) return text_in;
    // Potong di batas karakter UTF-8.
    var cut = MAX_OUT;
    while (cut > 0 and (text_in[cut] & 0xC0) == 0x80) cut -= 1;
    return std.fmt.allocPrint(a, "{s}\n... (dipotong)", .{text_in[0..cut]}) catch text_in[0..cut];
}

/// Jalankan alat. Kesalahan dikembalikan sebagai teks "Error: ..." supaya model bisa menyesuaikan diri.
pub fn run(a: std.mem.Allocator, name: []const u8, args: Args) []const u8 {
    const result = if (std.mem.eql(u8, name, "list_dir"))
        listDir(a, args)
    else if (std.mem.eql(u8, name, "read_file"))
        readFile(a, args)
    else if (std.mem.eql(u8, name, "find_files"))
        findFiles(a, args)
    else if (std.mem.eql(u8, name, "grep"))
        grep(a, args)
    else
        std.fmt.allocPrint(a, "Error: alat '{s}' nggak dikenal", .{name}) catch "Error";
    return cap(a, result);
}

fn listDir(a: std.mem.Allocator, args: Args) []const u8 {
    const path = files.expand(a, args.path);
    const entries = fsx.listDir(a, path, 5000) catch
        return std.fmt.allocPrint(a, "Error: {s}: tidak bisa dibaca", .{path}) catch "Error";

    const Row = struct { is_dir: bool, name: []const u8, size: u64 };
    var rows = util.List(Row).init();
    for (entries) |e| {
        if (!args.show_hidden and std.mem.startsWith(u8, e.name, ".")) continue;
        rows.append(a, .{ .is_dir = e.is_dir, .name = e.name, .size = e.size }) catch {};
    }
    const S = struct {
        fn lessThan(_: void, x: Row, y: Row) bool {
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
    std.mem.sort(Row, rows.items, {}, S.lessThan);

    var out = util.Str.init();
    out.appendFmt(a, "{s} ({d} item):\n", .{ path, rows.len() }) catch {};
    for (rows.items[0..@min(rows.len(), MAX_LIST)]) |r| {
        if (r.is_dir) {
            out.appendFmt(a, "{s}/\n", .{r.name}) catch {};
        } else {
            out.appendFmt(a, "{s}  ({s})\n", .{ r.name, files.humanSize(a, r.size) }) catch {};
        }
    }
    if (rows.len() > MAX_LIST) out.appendFmt(a, "... ({d} lainnya)\n", .{rows.len() - MAX_LIST}) catch {};
    return out.dupe(a) catch "Error";
}

fn readFile(a: std.mem.Allocator, args: Args) []const u8 {
    const path = files.expand(a, args.path);
    const st = fsx.stat(path) catch
        return std.fmt.allocPrint(a, "Error: {s}: tidak bisa dibaca", .{path}) catch "Error";
    if (st.is_dir) return std.fmt.allocPrint(a, "Error: {s} adalah folder, pakai list_dir", .{path}) catch "Error";

    const bytes = fsx.readFileAlloc(a, path, READ_CAP) catch
        return std.fmt.allocPrint(a, "Error: {s}: tidak bisa dibaca", .{path}) catch "Error";
    const head = bytes[0..@min(bytes.len, 8000)];
    if (std.mem.indexOfScalar(u8, head, 0) != null)
        return std.fmt.allocPrint(a, "Error: {s} bukan file teks (biner)", .{path}) catch "Error";

    const text = bytes;
    var total: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |_| total += 1;

    const start: usize = @intCast(@max(args.start_line, 1));
    const max_lines: usize = @intCast(std.math.clamp(args.max_lines, 1, 2000));

    var body = util.Str.init();
    var last = start -| 1;
    var line_no: usize = 1;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| : (line_no += 1) {
        if (line_no < start) continue;
        if (line_no >= start + max_lines) break;
        if (body.len() + line.len > MAX_OUT) break;
        body.appendFmt(a, "{d}: {s}\n", .{ line_no, line }) catch {};
        last = line_no;
    }

    var out = util.Str.init();
    out.appendFmt(a, "{s} ({s}, {d} baris, tampil {d}-{d}):\n", .{ path, files.humanSize(a, st.size), total, start, last }) catch {};
    out.append(a, body.items()) catch {};
    if (last < total) out.appendFmt(a, "... (masih ada; lanjut dengan start_line={d})\n", .{last + 1}) catch {};
    if (st.size > READ_CAP) out.append(a, "(file lebih besar dari 2 MB, hanya bagian awal yang dibaca)\n") catch {};
    return out.dupe(a) catch "Error";
}

fn skipDir(name: []const u8) bool {
    for (SKIP_DIRS) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

fn findFiles(a: std.mem.Allocator, args: Args) []const u8 {
    const root = files.expand(a, args.path);
    var hits = util.List([]const u8).init();
    var visited: usize = 0;

    var stack = util.List(struct { path: []const u8, depth: usize }).init();
    stack.append(a, .{ .path = root, .depth = 0 }) catch {};
    outer: while (stack.pop()) |dir| {
        const entries = fsx.listDir(a, dir.path, 5000) catch continue;
        for (entries) |e| {
            visited += 1;
            const full = std.fs.path.join(a, &.{ dir.path, e.name }) catch continue;
            if (std.mem.indexOf(u8, e.name, args.name) != null or asciiContainsIgnoreCase(e.name, args.name)) {
                const line = if (e.is_dir) std.fmt.allocPrint(a, "{s}/", .{full}) catch full else full;
                hits.append(a, line) catch {};
            }
            if (hits.len() >= MAX_HITS or visited >= MAX_VISITED) break :outer;
            if (e.is_dir and dir.depth < MAX_DEPTH and !skipDir(e.name)) {
                stack.append(a, .{ .path = full, .depth = dir.depth + 1 }) catch {};
            }
        }
    }

    if (hits.len() == 0) return std.fmt.allocPrint(a, "Tidak ada nama yang mengandung '{s}' di {s}", .{ args.name, root }) catch "Tidak ada";
    var out = util.Str.init();
    for (hits.items, 0..) |h, i| {
        if (i > 0) out.append(a, "\n") catch {};
        out.append(a, h) catch {};
    }
    return out.dupe(a) catch "Tidak ada";
}

fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn grepFile(a: std.mem.Allocator, path: []const u8, needle: []const u8, hits: *util.List([]const u8)) void {
    const st = fsx.statOrNull(path) orelse return;
    if (st.is_dir or st.size > 1_000_000) return;
    const bytes = fsx.readFileAlloc(a, path, 1_000_000) catch return;
    const head = bytes[0..@min(bytes.len, 4000)];
    if (std.mem.indexOfScalar(u8, head, 0) != null) return;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var i: usize = 0;
    while (lines.next()) |line| : (i += 1) {
        if (asciiContainsIgnoreCase(line, needle)) {
            const shown = std.mem.trim(u8, line, " \t\r\n");
            const cut = @min(shown.len, 200);
            hits.append(a, std.fmt.allocPrint(a, "{s}:{d}: {s}", .{ path, i + 1, shown[0..cut] }) catch path) catch {};
            if (hits.len() >= MAX_HITS) return;
        }
    }
}

fn grep(a: std.mem.Allocator, args: Args) []const u8 {
    const root = files.expand(a, args.path);
    var hits = util.List([]const u8).init();

    const st = fsx.stat(root) catch
        return std.fmt.allocPrint(a, "Error: {s}: tidak bisa dibaca", .{root}) catch "Error";

    if (!st.is_dir) {
        grepFile(a, root, args.query, &hits);
    } else {
        var scanned: usize = 0;
        var stack = util.List(struct { path: []const u8, depth: usize }).init();
        stack.append(a, .{ .path = root, .depth = 0 }) catch {};
        outer: while (stack.pop()) |dir| {
            const entries = fsx.listDir(a, dir.path, 5000) catch continue;
            for (entries) |e| {
                const full = std.fs.path.join(a, &.{ dir.path, e.name }) catch continue;
                if (e.is_dir) {
                    if (dir.depth < MAX_DEPTH and !skipDir(e.name)) stack.append(a, .{ .path = full, .depth = dir.depth + 1 }) catch {};
                } else {
                    scanned += 1;
                    grepFile(a, full, args.query, &hits);
                }
                if (scanned >= 5000 or hits.len() >= MAX_HITS) break :outer;
            }
        }
    }

    if (hits.len() == 0) return std.fmt.allocPrint(a, "Tidak ketemu '{s}' di {s}", .{ args.query, root }) catch "Tidak ketemu";
    var out = util.Str.init();
    for (hits.items, 0..) |h, i| {
        if (i > 0) out.append(a, "\n") catch {};
        out.append(a, h) catch {};
    }
    return out.dupe(a) catch "Tidak ketemu";
}

test "only explicit file requests enable tools" {
    try std.testing.expect(asksForFiles("tolong baca file ~/catatan.txt"));
    try std.testing.expect(asksForFiles("lihat isi folder download"));
    try std.testing.expect(asksForFiles("jelasin /sdcard/Download/a.txt"));
    try std.testing.expect(!asksForFiles("halo apa kabar"));
    try std.testing.expect(!asksForFiles("jelasin cara kerja rust ownership"));
}

test "access modes parse" {
    try std.testing.expectEqual(@as(?Access, .always), Access.parse("ON"));
    try std.testing.expectEqual(@as(?Access, .never), Access.parse("mati"));
    try std.testing.expectEqual(@as(?Access, null), Access.parse("entah"));
}
