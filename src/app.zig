//! Keadaan aplikasi: percakapan, tab, popup, dan reaksi terhadap event.
//! Port 1:1 dari src/app/mod.rs (+ commands.rs dan keys.rs).

const std = @import("std");
const util = @import("util.zig");
const chat = @import("chat.zig");
const config = @import("config.zig");
const input_mod = @import("input.zig");
const picker_mod = @import("picker.zig");
const editor_mod = @import("editor.zig");
const keyentry_mod = @import("keyentry.zig");
const files = @import("files.zig");
const tools = @import("tools.zig");
const provider = @import("provider.zig");
const event = @import("event.zig");
const api = @import("api.zig");
const fsx = @import("fsx.zig");
const key = @import("key.zig");
const screen_mod = @import("ui/screen.zig");
const commands = @import("app/commands.zig");
const keys = @import("app/keys.zig");

const Message = chat.Message;
const Role = chat.Role;

/// Jumlah pesan terakhir yang dikirim sebagai konteks.
const HISTORY_LIMIT: usize = 40;

/// Jumlah tick transisi dari layar awal ke layar sesi.
pub const SLIDE_FRAMES: u8 = 16;

/// Satu sesi. Sesi yang sedang aktif hidup di `App.messages`; isi tab-nya di sini basi.
pub const Tab = struct {
    messages: util.List(Message) = .{},
    scroll: usize = 0,
};

pub const Notice = union(enum) {
    info: []const u8,
    err: []const u8,
};

pub const App = struct {
    a: std.mem.Allocator,
    cfg: config.Config,
    messages: util.List(Message) = .{},
    input: input_mod.Input = .{},
    picker: ?picker_mod.Picker = null,
    editor: ?editor_mod.Editor = null,
    keyentry: ?keyentry_mod.KeyEntry = null,
    browser: ?files.Browser = null,
    access: tools.Access = .auto,
    attachments: util.List(files.Attachment) = .{},
    cmd_sel: usize = 0,
    tabs: util.List(Tab) = .{},
    active: usize = 0,
    tab_area: screen_mod.Rect = .{},
    notice: ?Notice = null,
    scroll: usize = 0,
    tick: usize = 0,
    slide: u8 = 0,
    cwd: []const u8 = "",
    streaming: bool = false,
    quit: bool = false,
    started: ?i128 = null,
    /// Penanda balasan yang sedang jalan; dinaikkan saat dibatalkan supaya potongan lama dibuang.
    stream_id: u64 = 0,
    /// Semua string frame UI dialokasikan di sini lalu dibuang tiap kali menggambar.
    arena: std.heap.ArenaAllocator,
    models_cache: std.StringHashMap([]const event.Model),

    pub fn init(a: std.mem.Allocator, cfg: config.Config) !App {
        var app = App{
            .a = a,
            .cfg = cfg,
            .arena = std.heap.ArenaAllocator.init(a),
            .models_cache = std.StringHashMap([]const event.Model).init(a),
            .cwd = config.displayCwd(a),
        };
        try app.tabs.append(a, .{});
        if (fsx.envNonEmpty(a, "CLAUDIA_FILES")) |v| {
            if (tools.Access.parse(v)) |acc| app.access = acc;
        }
        return app;
    }

    pub fn frameAlloc(self: *App) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn resetFrame(self: *App) void {
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn onEvent(self: *App, ev: event.Ev) void {
        switch (ev) {
            .tick => self.onTick(),
            .key => |k| keys.onKey(self, k),
            .mouse => |m| keys.onMouse(self, m),
            .tool => |label| {
                if (self.streaming) {
                    if (self.messages.last()) |msg| msg.pushTool(self.a, label) catch {};
                }
            },
            .chunk => |text| {
                if (self.streaming) {
                    if (self.messages.last()) |msg| msg.pushContent(self.a, text) catch {};
                }
            },
            .done => self.finishStream(),
            .failed => |e| {
                self.finishStream();
                self.err(e);
            },
            .models => |m| self.onModels(m.provider, m.ok, m.err),
        }
    }

    pub fn onTick(self: *App) void {
        self.tick +%= 1;
        self.slide = if (self.messages.len() == 0)
            self.slide -| 2
        else
            @min(self.slide + 1, SLIDE_FRAMES);
        if (self.picker) |*p| p.age = @min(p.age + 1, picker_mod.POPUP_FRAMES);
        if (self.editor) |*e| e.age = @min(e.age + 1, picker_mod.POPUP_FRAMES);
        if (self.keyentry) |*k| k.age = @min(k.age + 1, picker_mod.POPUP_FRAMES);
        if (self.browser) |*b| b.age = @min(b.age + 1, picker_mod.POPUP_FRAMES);
    }

    pub fn info(self: *App, text: []const u8) void {
        self.notice = .{ .info = text };
    }

    pub fn err(self: *App, text: []const u8) void {
        self.notice = .{ .err = text };
    }

    pub fn target(self: *App) api.Target {
        const p = self.cfg.current();
        return .{
            .id = p.id,
            .base_url = self.cfg.baseUrl(),
            .key = self.cfg.keys.get(p.id),
            .model = self.cfg.model(),
            .tools = false,
        };
    }

    // ── chat ──────────────────────────────────────────────

    pub fn submit(self: *App) void {
        const raw_text = self.input.text(self.a) catch return;
        const text_trimmed = std.mem.trim(u8, raw_text, " \t\r\n");
        if (text_trimmed.len == 0 and self.attachments.len() == 0) return;
        if (std.mem.startsWith(u8, text_trimmed, "/")) {
            self.input.clear();
            commands.run(self, text_trimmed);
            return;
        }
        if (self.streaming) return;
        const p = self.cfg.current();
        if (!self.cfg.isReady(p)) {
            self.err(std.fmt.allocPrint(self.a, "{s} belum siap: set {s} (atau /key <kunci>)", .{ p.name, p.requirement() }) catch "belum siap");
            return;
        }

        // @path di teks: file/folder yang disebut user sendiri ikut dilampirkan.
        var text = text_trimmed;
        var mentions = util.List([]const u8).init();
        var wit = std.mem.tokenizeAny(u8, text_trimmed, " \t\r\n");
        while (wit.next()) |tok| {
            if (tok.len > 1 and tok[0] == '@') {
                const expanded = files.expand(self.a, tok[1..]);
                if (fsx.exists(expanded)) mentions.append(self.a, expanded) catch {};
            }
        }
        for (mentions.items) |path| {
            var already = false;
            for (self.attachments.items) |att| {
                if (std.mem.eql(u8, att.path, path)) already = true;
            }
            if (!already and !self.attach(path)) return;
        }
        if (text.len == 0) text = "Tolong baca lampiran ini.";

        self.input.clear();
        self.notice = null;
        self.scroll = 0;

        var labels = util.List([]const u8).init();
        var context = util.Str.init();
        for (self.attachments.items) |att| {
            labels.append(self.a, att.label) catch {};
            context.append(self.a, att.block) catch {};
        }
        self.attachments.clearRetainingCapacity();

        var user_msg = Message.new(self.a, .user, text) catch return;
        user_msg.files = labels;
        user_msg.context = context.dupe(self.a) catch "";
        self.messages.append(self.a, user_msg) catch return;

        const is_space = p.isSpace();
        const tools_on = !is_space and switch (self.access) {
            .always => true,
            .never => false,
            .auto => tools.asksForFiles(self.messages.items[self.messages.len() - 1].content.items()),
        };
        var system = util.Str.init();
        system.append(self.a, self.cfg.system) catch {};
        if (tools_on) system.append(self.a, tools.TOOL_PROMPT) catch {};

        var history = util.List(api.Hist).init();
        history.append(self.a, .{ .role = "system", .content = system.dupe(self.a) catch "" }) catch {};
        const start = self.messages.len() -| HISTORY_LIMIT;
        for (self.messages.items[start..]) |*m| {
            history.append(self.a, .{ .role = m.role.asStr(), .content = m.full(self.a) catch "" }) catch {};
        }

        const tag = std.fmt.allocPrint(self.a, "{s} · {s}", .{ self.cfg.name, self.cfg.model() }) catch "";
        var reply = Message.new(self.a, .assistant, "") catch return;
        reply.tag = tag;
        self.messages.append(self.a, reply) catch return;

        self.streaming = true;
        self.started = nowNs();
        self.stream_id +%= 1;
        var t = self.target();
        t.tools = tools_on;
        api.spawnChat(t, history.items);
    }

    pub fn finishStream(self: *App) void {
        self.streaming = false;
        if (self.started) |start| {
            const elapsed_ns = nowNs() - start;
            const secs = @max(@as(f32, @floatFromInt(elapsed_ns)) / 1e9, 0.1);
            if (self.messages.last()) |msg| {
                if (msg.role == .assistant and msg.content.len() > 0) {
                    const chars = countChars(msg.content.items());
                    const tokens = @max(@as(f32, @floatFromInt(chars)) / 4.0, 1.0);
                    msg.tag = std.fmt.allocPrint(self.a, "{s} · {s} · {d:.1} tok/s", .{
                        msg.tag, formatDuration(self.a, secs), tokens / secs,
                    }) catch msg.tag;
                }
            }
            self.started = null;
        }
        self.dropEmptyReply();
    }

    pub fn cancel(self: *App) void {
        // Request yang masih jalan akan diabaikan karena `streaming` sudah false.
        self.finishStream();
    }

    pub fn clear(self: *App) void {
        self.cancel();
        self.messages.clearRetainingCapacity();
        self.notice = null;
        self.scroll = 0;
    }

    // ── tab sesi ──────────────────────────────────────────

    /// Judul tab: baris pertama pesan user pertama; `null` untuk sesi kosong.
    pub fn tabTitle(self: *const App, i: usize) ?[]const u8 {
        const messages = if (i == self.active) &self.messages else blk: {
            if (i >= self.tabs.len()) return null;
            break :blk &self.tabs.items[i].messages;
        };
        for (messages.items) |*m| {
            if (m.role == .user) {
                const content = m.content.items();
                const nl = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
                return std.mem.trim(u8, content[0..nl], " \t\r");
            }
        }
        return null;
    }

    pub fn switchTab(self: *App, slot: usize) void {
        if (slot >= self.tabs.len() or slot == self.active) return;
        self.cancel();
        self.tabs.items[self.active] = .{ .messages = self.messages, .scroll = self.scroll };
        const next = self.tabs.items[slot];
        self.tabs.items[slot] = .{};
        self.messages = next.messages;
        self.scroll = next.scroll;
        self.active = slot;
        self.notice = null;
    }

    pub fn stepTab(self: *App, delta: isize) void {
        const count: isize = @intCast(self.tabs.len());
        if (count == 0) return;
        const slot: usize = @intCast(@mod(@as(isize, @intCast(self.active)) + delta, count));
        self.switchTab(slot);
    }

    pub fn newTab(self: *App) void {
        if (self.messages.len() == 0) return;
        for (0..self.tabs.len()) |i| {
            if (i != self.active and self.tabTitle(i) == null) {
                self.switchTab(i);
                return;
            }
        }
        self.cancel();
        self.tabs.items[self.active] = .{ .messages = self.messages, .scroll = self.scroll };
        self.tabs.append(self.a, .{}) catch return;
        self.active = self.tabs.len() - 1;
        self.messages = .{};
        self.scroll = 0;
        self.notice = null;
    }

    pub fn closeTab(self: *App) void {
        self.cancel();
        if (self.tabs.len() <= 1) {
            self.messages.clearRetainingCapacity();
            self.scroll = 0;
            return;
        }
        _ = self.tabs.remove(self.active);
        const next = @min(self.active, self.tabs.len() - 1);
        const tab = self.tabs.items[next];
        self.tabs.items[next] = .{};
        self.messages = tab.messages;
        self.scroll = tab.scroll;
        self.active = next;
        self.notice = null;
    }

    // ── system prompt ─────────────────────────────────────

    pub fn openSystemEditor(self: *App) void {
        self.editor = editor_mod.Editor.init(self.a, self.cfg.system) catch null;
    }

    pub fn saveSystem(self: *App) void {
        const editor = self.editor orelse return;
        self.editor = null;
        const raw = editor.text(self.a) catch return;
        const text = std.mem.trim(u8, raw, " \t\r\n");
        if (text.len == 0) {
            self.cfg.resetSystem();
            self.info("system prompt dikembalikan ke bawaan");
        } else {
            self.cfg.setSystem(text);
            self.info("system prompt disimpan, berlaku mulai pesan berikutnya");
        }
    }

    pub fn dropEmptyReply(self: *App) void {
        if (self.messages.last()) |m| {
            if (m.role == .assistant and m.content.len() == 0) _ = self.messages.pop();
        }
    }

    // ── perintah, connect, API key ────────────────────────

    /// Perintah yang cocok dengan ketikan sekarang ("/mo" → /model); kosong kalau input bukan perintah.
    pub fn commandMatches(self: *App, out: *util.List(*const commands.Cmd)) void {
        out.clearRetainingCapacity();
        if (self.picker != null or self.editor != null or self.keyentry != null or self.browser != null) return;
        const text = self.input.text(self.a) catch return;
        if (text.len == 0 or text[0] != '/') return;
        if (std.mem.indexOfScalar(u8, text, ' ') != null) return;
        commands.filter(self.a, text[1..], out);
    }

    pub fn completeCommand(self: *App, cmd: *const commands.Cmd) void {
        self.input.clear();
        self.cmd_sel = 0;
        const text = if (cmd.arg)
            std.fmt.allocPrint(self.a, "/{s} ", .{cmd.name}) catch return
        else
            std.fmt.allocPrint(self.a, "/{s}", .{cmd.name}) catch return;
        for (text) |c| self.input.insert(self.a, c);
    }

    // ── file (hanya atas perintah user) ───────────────────

    pub fn openFiles(self: *App, dir: ?[]const u8) void {
        const d = dir orelse self.cwd;
        self.browser = files.Browser.init(self.a, d);
    }

    /// Lampirkan file/folder yang dipilih user; `false` kalau gagal (pesan error sudah ditampilkan).
    pub fn attach(self: *App, path: []const u8) bool {
        const att = files.readAttachment(self.a, path) catch |e| {
            self.err(switch (e) {
                error.Binary => std.fmt.allocPrint(self.a, "{s}: bukan file teks (biner)", .{path}) catch "gagal",
                else => std.fmt.allocPrint(self.a, "{s}: nggak bisa dibaca", .{path}) catch "gagal",
            });
            return false;
        };
        var total: usize = att.size;
        for (self.attachments.items) |x| total += x.size;
        if (total > files.MAX_TOTAL) {
            self.err(std.fmt.allocPrint(self.a, "lampiran kebanyakan (maks {s} per pesan), lepas dulu dengan /detach", .{files.humanSize(self.a, files.MAX_TOTAL)}) catch "lampiran kebanyakan");
            return false;
        }
        self.info(std.fmt.allocPrint(self.a, "dilampirkan: {s}", .{att.label}) catch "dilampirkan");
        self.attachments.append(self.a, att) catch return false;
        return true;
    }

    pub fn openCommands(self: *App) void {
        const a = self.a;
        var items = util.List(picker_mod.Item).init();
        for (commands.COMMANDS) |c| {
            items.append(a, .{
                .id = c.name,
                .label = std.fmt.allocPrint(a, "/{s}", .{c.name}) catch c.name,
                .hint = c.desc,
                .current = false,
            }) catch {};
        }
        self.picker = picker_mod.Picker.init(.command, a, items.items, false) catch null;
    }

    pub fn openConnect(self: *App) void {
        const a = self.a;
        var items = util.List(picker_mod.Item).init();
        for (provider.ALL, 0..) |p, i| {
            const hint = if (p.key_env.len == 0 and !p.isCustom())
                "lokal"
            else if (self.cfg.isReady(&p))
                "terhubung"
            else
                "belum";
            items.append(a, .{ .id = p.id, .label = p.name, .hint = hint, .current = i == self.cfg.selected }) catch {};
        }
        self.picker = picker_mod.Picker.init(.connect, a, items.items, false) catch null;
    }

    /// Provider berkunci langsung ke dialog API key; provider lokal/custom cukup dipilih.
    pub fn beginConnect(self: *App, index: usize) void {
        const p = &provider.ALL[index];
        if (p.key_env.len == 0 or p.isCustom()) {
            self.setProvider(index);
        } else {
            self.keyentry = keyentry_mod.KeyEntry.init(index);
        }
    }

    pub fn saveKey(self: *App) void {
        const entry = self.keyentry orelse return;
        const raw = entry.input.text(self.a) catch return;
        const key_text = std.mem.trim(u8, raw, " \t\r\n");
        if (key_text.len == 0) {
            if (self.keyentry) |*e| e.err = "isi API key dulu";
            return;
        }
        const index = entry.provider;
        self.keyentry = null;
        const p = &provider.ALL[index];
        self.cfg.setKey(p.id, key_text);
        self.setProvider(index);
        self.info(std.fmt.allocPrint(self.a, "{s} terhubung, pilih model", .{p.name}) catch "terhubung");
        self.openModels();
    }

    // ── provider & model ──────────────────────────────────

    pub fn setProvider(self: *App, index: usize) void {
        self.cancel();
        self.cfg.selected = index;
        self.cfg.save();
        const p = self.cfg.current();
        if (self.cfg.isReady(p)) {
            self.info(std.fmt.allocPrint(self.a, "{s} · {s}", .{ p.name, self.cfg.model() }) catch "siap");
        } else {
            self.err(std.fmt.allocPrint(self.a, "{s} belum siap: set {s} (atau /key <kunci>)", .{ p.name, p.requirement() }) catch "belum siap");
        }
    }

    pub fn setModel(self: *App, model: []const u8) void {
        self.cfg.setModel(model);
        self.cfg.save();
        self.info(std.fmt.allocPrint(self.a, "model: {s}", .{self.cfg.model()}) catch "model diganti");
    }

    pub fn openProviders(self: *App) void {
        const a = self.a;
        var items = util.List(picker_mod.Item).init();
        for (provider.ALL, 0..) |p, i| {
            const hint = if (self.cfg.isReady(&p))
                "siap"
            else
                std.fmt.allocPrint(a, "butuh {s}", .{p.requirement()}) catch "belum";
            items.append(a, .{ .id = p.id, .label = p.name, .hint = hint, .current = i == self.cfg.selected }) catch {};
        }
        self.picker = picker_mod.Picker.init(.provider, a, items.items, false) catch null;
    }

    pub fn openModels(self: *App) void {
        const p = self.cfg.current();
        const cached = p.isSpace() or self.models_cache.contains(p.id);
        const items = self.modelItems();
        self.picker = picker_mod.Picker.init(.model, self.a, items, !cached) catch null;
        if (!cached) api.spawnModels(self.target());
    }

    /// Daftar asli dari API kalau sudah ada, kalau belum pakai daftar bawaan.
    pub fn modelItems(self: *App) []const picker_mod.Item {
        const a = self.a;
        const p = self.cfg.current();
        const current = self.cfg.model();
        var models = util.List(event.Model).init();
        if (self.models_cache.get(p.id)) |list| {
            models.appendSlice(a, list) catch {};
        } else {
            for (p.fallback_models) |m| models.append(a, .{ .id = m, .name = "" }) catch {};
        }
        var has_current = false;
        for (models.items) |m| {
            if (std.mem.eql(u8, m.id, current)) has_current = true;
        }
        if (current.len > 0 and !has_current) models.insert(a, 0, .{ .id = current, .name = "" }) catch {};

        var items = util.List(picker_mod.Item).init();
        for (models.items) |m| {
            items.append(a, .{
                .id = m.id,
                .label = m.id,
                .hint = m.name,
                .current = std.mem.eql(u8, m.id, current),
            }) catch {};
        }
        return items.items;
    }

    pub fn onModels(self: *App, provider_id: []const u8, ok: ?[]const event.Model, err_msg: []const u8) void {
        if (ok) |list| {
            self.models_cache.put(provider_id, list) catch {};
        } else if (err_msg.len > 0) {
            self.err(std.fmt.allocPrint(self.a, "daftar model: {s}", .{err_msg}) catch "daftar model gagal");
        }
        if (std.mem.eql(u8, self.cfg.current().id, provider_id)) {
            if (self.picker) |*p| {
                if (p.kind == .model) {
                    const items = self.modelItems();
                    p.setItems(self.a, items);
                }
            }
        }
    }

    pub fn confirmPick(self: *App) void {
        const picker = self.picker orelse return;
        const typed = std.mem.trim(u8, picker.filter.items(), " \t\r\n");
        const sel = picker.selectedItem();
        if (picker.kind == .model and sel == null and typed.len > 0 and self.models_cache.contains(self.cfg.current().id)) {
            self.err(std.fmt.allocPrint(self.a, "model '{s}' nggak ada di daftar. Cari pakai kata lain, atau /model {s} buat memaksa", .{ typed, typed }) catch "model nggak ada");
            return;
        }
        const choice: []const u8 = blk: {
            if (sel) |item| break :blk item.id;
            if (picker.kind == .model and typed.len > 0) break :blk typed;
            return;
        };
        const kind = picker.kind;
        self.picker = null;
        switch (kind) {
            .provider => {
                if (provider.find(choice)) |i| self.setProvider(i);
            },
            .model => self.setModel(choice),
            .connect => {
                if (provider.find(choice)) |i| self.beginConnect(i);
            },
            .command => {
                for (&commands.COMMANDS) |*cmd| {
                    if (std.mem.eql(u8, cmd.name, choice)) {
                        if (cmd.arg) {
                            self.completeCommand(cmd);
                        } else {
                            const line = std.fmt.allocPrint(self.a, "/{s}", .{cmd.name}) catch return;
                            commands.run(self, line);
                        }
                        break;
                    }
                }
            },
        }
    }
};

/// "45s" atau "1m 14s".
fn formatDuration(a: std.mem.Allocator, secs: f32) []const u8 {
    const total: u64 = @intFromFloat(@round(secs));
    if (total >= 60) {
        return std.fmt.allocPrint(a, "{d}m {d}s", .{ total / 60, total % 60 }) catch "?";
    }
    return std.fmt.allocPrint(a, "{d}s", .{total}) catch "?";
}

/// Jam monotonik dalam nanodetik.
fn nowNs() i128 {
    return @as(i128, std.Io.Clock.now(.awake, fsx.io).nanoseconds);
}

fn countChars(text: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        i += @min(len, text.len - i);
        n += 1;
    }
    return n;
}
