//! Konfigurasi: provider terpilih, system prompt, API key, dan model per provider.
//! Port 1:1 dari src/config.rs.

const std = @import("std");
const fsx = @import("fsx.zig");
const provider = @import("provider.zig");
const util = @import("util.zig");

pub const Config = struct {
    a: std.mem.Allocator,
    selected: usize = 0,
    name: []const u8 = "Claudia",
    system: []const u8 = "",
    /// API key per provider (dari env var atau `/key`).
    keys: std.StringHashMap([]const u8),
    /// Key yang diisi lewat /connect, disimpan di ~/.config/claudia/keys (izin 600).
    stored: std.StringHashMap([]const u8),
    /// Model pilihan per provider, disimpan di file state.
    models: std.StringHashMap([]const u8),

    fn configDir(a: std.mem.Allocator) ?[]const u8 {
        if (fsx.envNonEmpty(a, "XDG_CONFIG_HOME")) |base| {
            return std.fs.path.join(a, &.{ base, "claudia" }) catch null;
        }
        if (fsx.envAlloc(a, "HOME")) |home| {
            return std.fs.path.join(a, &.{ home, ".config", "claudia" }) catch null;
        }
        return null;
    }

    fn pathOf(a: std.mem.Allocator, leaf: []const u8) ?[]const u8 {
        const dir = configDir(a) orelse return null;
        return std.fs.path.join(a, &.{ dir, leaf }) catch null;
    }

    fn keysPath(a: std.mem.Allocator) ?[]const u8 {
        return pathOf(a, "keys");
    }
    fn statePath(a: std.mem.Allocator) ?[]const u8 {
        return pathOf(a, "state");
    }
    fn systemPath(a: std.mem.Allocator) ?[]const u8 {
        return pathOf(a, "system");
    }

    pub fn defaultSystem(a: std.mem.Allocator, name: []const u8) []const u8 {
        return std.fmt.allocPrint(a, "Kamu adalah {s} (C.L.A.U.D.I.A), teman ngobrol yang santai, hangat, dan nyambung. " ++
            "Balas dalam bahasa yang dipakai lawan bicara (default Indonesia santai). " ++
            "Jawab ringkas kecuali diminta detail.", .{name}) catch "Kamu adalah Claudia.";
    }

    pub fn load(a: std.mem.Allocator) Config {
        var cfg = Config{
            .a = a,
            .keys = std.StringHashMap([]const u8).init(a),
            .stored = std.StringHashMap([]const u8).init(a),
            .models = std.StringHashMap([]const u8).init(a),
        };

        // Key dari environment.
        for (provider.ALL) |p| {
            if (p.key_env.len == 0) continue;
            if (fsx.envNonEmpty(a, p.key_env)) |key| cfg.keys.put(p.id, key) catch {};
        }
        // Key hasil /connect.
        if (keysPath(a)) |path| {
            if (fsx.readFileAllocOrNull(a, path, 1_000_000)) |text| {
                var lines = std.mem.splitScalar(u8, text, '\n');
                while (lines.next()) |line| {
                    const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
                    const id = std.mem.trim(u8, line[0..eq], " \t\r");
                    const key = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
                    if (key.len == 0) continue;
                    const idx = provider.find(id) orelse continue;
                    cfg.stored.put(provider.ALL[idx].id, key) catch {};
                }
            }
        }
        var it = cfg.stored.iterator();
        while (it.next()) |e| {
            if (!cfg.keys.contains(e.key_ptr.*)) cfg.keys.put(e.key_ptr.*, e.value_ptr.*) catch {};
        }

        if (fsx.envNonEmpty(a, "CLAUDIA_NAME")) |n| cfg.name = n;

        // Prioritas: hasil edit (/system) > env CLAUDIA_SYSTEM > bawaan.
        var saved: ?[]const u8 = null;
        if (systemPath(a)) |path| {
            if (fsx.readFileAllocOrNull(a, path, 1_000_000)) |text| {
                if (std.mem.trim(u8, text, " \t\r\n").len > 0) saved = text;
            }
        }
        cfg.system = saved orelse (fsx.envNonEmpty(a, "CLAUDIA_SYSTEM") orelse defaultSystem(a, cfg.name));

        const from_state = cfg.loadState();
        const from_env = if (fsx.envNonEmpty(a, "CLAUDIA_PROVIDER")) |s| provider.find(s) else null;
        cfg.selected = from_env orelse (from_state orelse (firstWithKey(&cfg) orelse 0));

        if (fsx.envNonEmpty(a, "CLAUDIA_MODEL")) |m| cfg.setModel(m);
        return cfg;
    }

    fn firstWithKey(cfg: *Config) ?usize {
        for (provider.ALL, 0..) |p, i| {
            if (cfg.keys.contains(p.id)) return i;
        }
        return null;
    }

    fn writeKeys(self: *Config) void {
        const path = keysPath(self.a) orelse return;
        if (self.stored.count() == 0) {
            fsx.removeFile(path);
            return;
        }
        if (std.fs.path.dirname(path)) |dir| fsx.makePath(dir);
        var out = util.Str.init();
        var it = self.stored.iterator();
        while (it.next()) |e| {
            out.appendFmt(self.a, "{s}={s}\n", .{ e.key_ptr.*, e.value_ptr.* }) catch {};
        }
        fsx.writePrivate(path, out.items()) catch {};
    }

    pub fn setKey(self: *Config, id: []const u8, key: []const u8) void {
        self.keys.put(id, key) catch {};
        self.stored.put(id, key) catch {};
        self.writeKeys();
    }

    pub fn forgetKey(self: *Config, id: []const u8) void {
        _ = self.keys.remove(id);
        _ = self.stored.remove(id);
        self.writeKeys();
    }

    /// Ganti system prompt dan simpan ke disk.
    pub fn setSystem(self: *Config, text: []const u8) void {
        self.system = text;
        const path = systemPath(self.a) orelse return;
        if (std.fs.path.dirname(path)) |dir| fsx.makePath(dir);
        fsx.writeFile(path, self.system) catch {};
    }

    pub fn resetSystem(self: *Config) void {
        self.system = defaultSystem(self.a, self.name);
        if (systemPath(self.a)) |path| fsx.removeFile(path);
    }

    pub fn current(self: *const Config) *const provider.Provider {
        return &provider.ALL[self.selected];
    }

    fn modelOf(self: *const Config, p: *const provider.Provider) []const u8 {
        if (self.models.get(p.id)) |m| return m;
        if (p.isSpace()) {
            if (fsx.envNonEmpty(self.a, "HF_SPACE")) |s| return s;
        }
        return p.default_model;
    }

    pub fn model(self: *const Config) []const u8 {
        return self.modelOf(self.current());
    }

    pub fn setModel(self: *Config, name: []const u8) void {
        const id = self.current().id;
        self.models.put(id, name) catch {};
    }

    pub fn baseUrl(self: *const Config) []const u8 {
        const p = self.current();
        if (p.isCustom()) {
            const url = fsx.envNonEmpty(self.a, "CLAUDIA_BASE_URL") orelse "";
            return std.mem.trimEnd(u8, url, "/");
        }
        return p.base_url;
    }

    pub fn isReady(self: *const Config, p: *const provider.Provider) bool {
        if (p.isCustom()) return fsx.envNonEmpty(self.a, "CLAUDIA_BASE_URL") != null;
        if (p.isSpace()) return self.keys.contains(p.id) and self.modelOf(p).len > 0;
        return p.key_env.len == 0 or self.keys.contains(p.id);
    }

    fn loadState(self: *Config) ?usize {
        const path = statePath(self.a) orelse return null;
        const text = fsx.readFileAllocOrNull(self.a, path, 1_000_000) orelse return null;
        var selected: ?usize = null;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = line[0..eq];
            const value = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
            if (std.mem.eql(u8, key, "provider")) {
                selected = provider.find(value);
            } else if (std.mem.startsWith(u8, key, "model.")) {
                if (provider.find(key["model.".len..])) |i| {
                    self.models.put(provider.ALL[i].id, value) catch {};
                }
            }
        }
        return selected;
    }

    /// Simpan provider terakhir dan model per provider.
    pub fn save(self: *Config) void {
        const path = statePath(self.a) orelse return;
        if (std.fs.path.dirname(path)) |dir| fsx.makePath(dir);
        var out = util.Str.init();
        out.appendFmt(self.a, "provider={s}\n", .{self.current().id}) catch {};
        var it = self.models.iterator();
        while (it.next()) |e| {
            out.appendFmt(self.a, "model.{s}={s}\n", .{ e.key_ptr.*, e.value_ptr.* }) catch {};
        }
        fsx.writeFile(path, out.items()) catch {};
    }
};

/// Direktori kerja untuk footer, `$HOME` diringkas jadi `~`.
pub fn displayCwd(a: std.mem.Allocator) []const u8 {
    const cwd = fsx.cwdAlloc(a);
    if (fsx.envAlloc(a, "HOME")) |home| {
        if (home.len > 0 and std.mem.startsWith(u8, cwd, home)) {
            return std.fmt.allocPrint(a, "~{s}", .{cwd[home.len..]}) catch cwd;
        }
    }
    return cwd;
}
