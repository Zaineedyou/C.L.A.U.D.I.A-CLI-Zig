//! Pembungkus operasi file kecil di atas std.Io, supaya kalau API std berubah cukup
//! satu berkas ini yang disesuaikan.

const std = @import("std");

pub const max_read: usize = 2_000_000;

/// Instance I/O proses (diisi main). Semua operasi file memakai ini.
pub var io: std.Io = undefined;
var threaded_storage: std.Io.Threaded = undefined;
var io_ready = false;

pub fn init(gpa: std.mem.Allocator) void {
    if (io_ready) return;
    threaded_storage = std.Io.Threaded.init(gpa, .{});
    io = threaded_storage.io();
    io_ready = true;
}

fn dir() std.Io.Dir {
    return std.Io.Dir.cwd();
}

pub fn readFileAlloc(a: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    const buf = try a.alloc(u8, max);
    errdefer a.free(buf);
    const got = try dir().readFile(io, path, buf);
    if (got.len < max) {
        const trimmed = try a.realloc(buf, got.len);
        return trimmed;
    }
    return buf;
}

pub fn readFileAllocOrNull(a: std.mem.Allocator, path: []const u8, max: usize) ?[]u8 {
    return readFileAlloc(a, path, max) catch null;
}

pub fn writeFile(path: []const u8, data: []const u8) !void {
    try dir().writeFile(io, .{ .sub_path = path, .data = data });
}

/// Tulis dengan izin 0600 (API key).
pub fn writePrivate(path: []const u8, data: []const u8) !void {
    const file = try dir().createFile(io, path, .{ .truncate = true, .permissions = @enumFromInt(0o600) });
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}

pub fn makePath(path: []const u8) void {
    dir().createDirPath(io, path) catch {};
}

pub fn removeFile(path: []const u8) void {
    dir().deleteFile(io, path) catch {};
}

pub fn exists(path: []const u8) bool {
    dir().access(io, path, .{}) catch return false;
    return true;
}

pub const Stat = struct { is_dir: bool, size: u64 };

pub fn stat(path: []const u8) !Stat {
    const st = try dir().statFile(io, path, .{});
    return .{ .is_dir = st.kind == .directory, .size = st.size };
}

pub fn statOrNull(path: []const u8) ?Stat {
    return stat(path) catch null;
}

pub const DirEntry = struct { name: []const u8, is_dir: bool, size: u64 };

/// Baca isi folder (nama, jenis, ukuran); pemanggil memiliki `name`.
pub fn listDir(a: std.mem.Allocator, path: []const u8, max: usize) ![]DirEntry {
    var d = try dir().openDir(io, path, .{ .iterate = true });
    defer d.close(io);
    var out = std.ArrayListUnmanaged(DirEntry).empty;
    errdefer out.deinit(a);
    var it = d.iterate();
    while (try it.next(io)) |e| {
        if (out.items.len >= max) break;
        const st = statOrNullJoin(a, path, e.name);
        try out.append(a, .{
            .name = try a.dupe(u8, e.name),
            .is_dir = e.kind == .directory,
            .size = if (st) |s| s.size else 0,
        });
    }
    return out.toOwnedSlice(a);
}

fn statOrNullJoin(a: std.mem.Allocator, base: []const u8, name: []const u8) ?Stat {
    const full = std.fs.path.join(a, &.{ base, name }) catch return null;
    defer a.free(full);
    return statOrNull(full);
}

pub fn cwdAlloc(a: std.mem.Allocator) []const u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = dir().realPath(io, &buf) catch return a.dupe(u8, "/") catch "/";
    return a.dupe(u8, buf[0..n]) catch "/";
}

pub fn envAlloc(a: std.mem.Allocator, name: []const u8) ?[]u8 {
    const z = a.dupeSentinel(u8, name, 0) catch return null;
    defer a.free(z);
    const value = std.c.getenv(z.ptr) orelse return null;
    return a.dupe(u8, std.mem.span(value)) catch null;
}

pub fn envNonEmpty(a: std.mem.Allocator, name: []const u8) ?[]u8 {
    const v = envAlloc(a, name) orelse return null;
    if (v.len == 0) {
        a.free(v);
        return null;
    }
    return v;
}

pub fn homeAlloc(a: std.mem.Allocator) []const u8 {
    return envAlloc(a, "HOME") orelse (a.dupe(u8, "/") catch "/");
}
