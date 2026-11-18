//! Bicara ke provider: streaming chat (dialek OpenAI), daftar model, dan Hugging Face Space (Gradio).
//! Port 1:1 dari src/api.rs, tapi pakai std.http.Client (tanpa reqwest).

const std = @import("std");
const util = @import("util.zig");
const event = @import("event.zig");
const tools = @import("tools.zig");
const fsx = @import("fsx.zig");

pub const Target = struct {
    id: []const u8,
    base_url: []const u8,
    key: ?[]const u8 = null,
    model: []const u8,
    /// Tawarkan alat baca file ke model pada permintaan ini.
    tools: bool = false,
};

/// Satu pesan yang dikirim ke model.
pub const Hist = struct {
    role: []const u8,
    content: []const u8,
};

var shared_client: std.http.Client = undefined;
var client_ready = false;
var shared_io: std.Io = undefined;

/// Dipanggil sekali dari main sebelum thread jaringan dibuat.
pub fn initIo(io: std.Io) void {
    shared_io = io;
    if (!client_ready) {
        shared_client = .{ .allocator = std.heap.c_allocator, .io = shared_io };
        client_ready = true;
    }
}

fn client() *std.http.Client {
    return &shared_client;
}

threadlocal var err_buf: [1024]u8 = undefined;
threadlocal var err_len: usize = 0;

fn fail(comptime fmt: []const u8, args: anytype) error{ApiFailed} {
    err_len = 0;
    const text = std.fmt.bufPrint(&err_buf, fmt, args) catch "error";
    err_len = text.len;
    return error.ApiFailed;
}

fn errText() []const u8 {
    if (err_len == 0) return "gagal";
    return err_buf[0..err_len];
}

pub fn spawnChat(t: Target, history: []const Hist) void {
    const th = std.Thread.spawn(.{}, chatWorker, .{ t, history }) catch {
        event.push(.{ .failed = "gagal bikin thread" });
        return;
    };
    th.detach();
}

fn chatWorker(t: Target, history: []const Hist) void {
    streamChat(&t, history) catch |e| {
        if (e == error.Cancelled) return;
        const msg = if (e == error.ApiFailed) errText() else @errorName(e);
        event.push(.{ .failed = msg });
        return;
    };
    event.push(.done);
}

pub fn spawnModels(t: Target) void {
    const th = std.Thread.spawn(.{}, modelsWorker, .{t}) catch {
        event.push(.{ .models = .{ .provider = t.id, .err = "gagal bikin thread" } });
        return;
    };
    th.detach();
}

fn modelsWorker(t: Target) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    if (fetchModels(arena.allocator(), &t)) |list| {
        event.push(.{ .models = .{ .provider = t.id, .ok = list } });
    } else |e| {
        const msg = if (e == error.ApiFailed) errText() else @errorName(e);
        event.push(.{ .models = .{ .provider = t.id, .err = msg } });
    }
}

// ── HTTP ─────────────────────────────────────────────────

const Header = std.http.Header;

fn authHeaders(a: std.mem.Allocator, t: *const Target) ![]const Header {
    var list = util.List(Header).init();
    if (t.key) |key| {
        if (std.mem.eql(u8, t.id, "anthropic")) {
            try list.append(a, .{ .name = "x-api-key", .value = key });
            try list.append(a, .{ .name = "anthropic-version", .value = "2023-06-01" });
            try list.append(a, .{ .name = "authorization", .value = try std.fmt.allocPrint(a, "Bearer {s}", .{key}) });
        } else {
            try list.append(a, .{ .name = "authorization", .value = try std.fmt.allocPrint(a, "Bearer {s}", .{key}) });
        }
    }
    return list.items;
}

const Response = struct {
    status: std.http.Status,
    body: []u8,
};

/// Kirim satu permintaan dan kumpulkan seluruh badan jawaban.
fn requestAll(a: std.mem.Allocator, t: *const Target, method: std.http.Method, url: []const u8, payload: ?[]const u8) !Response {
    var writer: std.Io.Writer.Allocating = .init(a);
    errdefer writer.deinit();
    const headers = try authHeaders(a, t);
    const result = client().fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .response_writer = &writer.writer,
        .privileged_headers = headers,
        .extra_headers = headers,
    }) catch |e| return fail("gagal konek: {s}", .{@errorName(e)});
    return .{ .status = result.status, .body = writer.written() };
}

fn isOk(status: std.http.Status) bool {
    return @intFromEnum(status) >= 200 and @intFromEnum(status) < 300;
}

fn ensureOk(status: std.http.Status, body: []const u8) !void {
    if (isOk(status)) return;
    const cut = @min(body.len, 160);
    return fail("{d}: {s}", .{ @intFromEnum(status), body[0..cut] });
}

const LineCtx = struct {
    buf: util.Str = .{},
    a: std.mem.Allocator,
};

/// Buka koneksi streaming dan panggil `on_line` untuk tiap baris jawaban.
fn streamLines(
    a: std.mem.Allocator,
    t: *const Target,
    method: std.http.Method,
    url: []const u8,
    payload: ?[]const u8,
    ctx: anytype,
    comptime onLine: fn (@TypeOf(ctx), []const u8) anyerror!bool,
) !void {
    const c = client();
    const uri = std.Uri.parse(url) catch return fail("URL nggak valid: {s}", .{url});
    const headers = try authHeaders(a, t);
    var req = c.request(method, uri, .{
        .extra_headers = headers,
        .privileged_headers = headers,
    }) catch |e| return fail("gagal konek: {s}", .{@errorName(e)});
    defer req.deinit();

    if (payload) |p| {
        req.sendBodyComplete(@constCast(p)) catch |e| return fail("gagal kirim: {s}", .{@errorName(e)});
    } else {
        req.sendBodiless() catch |e| return fail("gagal kirim: {s}", .{@errorName(e)});
    }
    var redirect_buf: [8192]u8 = undefined;
    var res = req.receiveHead(&redirect_buf) catch |e| return fail("gagal baca jawaban: {s}", .{@errorName(e)});
    const status = res.head.status;
    if (!isOk(status)) {
        var tmp: [4096]u8 = undefined;
        var body = util.Str.init();
        const rd = res.reader(&tmp);
        while (true) {
            var chunk: [2048]u8 = undefined;
            const n = rd.readSliceShort(&chunk) catch break;
            if (n == 0) break;
            body.append(a, chunk[0..n]) catch break;
        }
        const cut = @min(body.len(), 160);
        return fail("{d}: {s}", .{ @intFromEnum(status), body.items()[0..cut] });
    }

    var transfer_buf: [8192]u8 = undefined;
    const reader = res.reader(&transfer_buf);
    var line = util.Str.init();
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = reader.readSliceShort(&chunk) catch |e| return fail("koneksi putus: {s}", .{@errorName(e)});
        if (n == 0) break;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (chunk[i] == '\n') {
                const keep = try onLine(ctx, line.items());
                line.clear();
                if (!keep) return;
            } else {
                try line.append(a, chunk[i .. i + 1]);
            }
        }
    }
    if (line.len() > 0) _ = try onLine(ctx, line.items());
}

// ── JSON bantu ───────────────────────────────────────────

fn appendJsonString(out: *util.Str, a: std.mem.Allocator, s: []const u8) !void {
    try out.appendByte(a, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.append(a, "\\\""),
            '\\' => try out.append(a, "\\\\"),
            '\n' => try out.append(a, "\\n"),
            '\r' => try out.append(a, "\\r"),
            '\t' => try out.append(a, "\\t"),
            0x08 => try out.append(a, "\\b"),
            0x0c => try out.append(a, "\\f"),
            else => {
                if (c < 0x20) {
                    try out.appendFmt(a, "\\u{X:0>4}", .{c});
                } else {
                    try out.appendByte(a, c);
                }
            },
        }
    }
    try out.appendByte(a, '"');
}

// ── chat ─────────────────────────────────────────────────

const MAX_ROUNDS: usize = 8;

const ToolCall = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    args: []const u8 = "",
};

const StreamCtx = struct {
    a: std.mem.Allocator,
    text: util.Str = .{},
    calls: util.List(ToolCall) = .{},
    /// Penanda kalau server mengirim [DONE].
    done: bool = false,
};

fn streamChat(t: *const Target, history: []const Hist) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    if (std.mem.eql(u8, t.id, "hfspace")) return streamSpace(a, t, history);

    var messages = util.List([]const u8).init();
    for (history) |m| try messages.append(a, try messageJson(a, m.role, m.content));
    var use_tools = t.tools;
    const url = try std.fmt.allocPrint(a, "{s}/chat/completions", .{t.base_url});

    var round: usize = 0;
    while (round < MAX_ROUNDS) : (round += 1) {
        var body = util.Str.init();
        try body.append(a, "{\"model\":");
        try appendJsonString(&body, a, t.model);
        try body.append(a, ",\"messages\":[");
        for (messages.items, 0..) |m, i| {
            if (i > 0) try body.appendByte(a, ',');
            try body.append(a, m);
        }
        try body.append(a, "],\"stream\":true");
        if (use_tools) {
            try body.append(a, ",\"tools\":");
            try body.append(a, tools.DEFINITIONS);
        }
        try body.appendByte(a, '}');

        var ctx = StreamCtx{ .a = a };
        streamLines(a, t, .POST, url, body.items(), &ctx, lineHandler) catch |e| {
            if (e == error.ApiFailed and use_tools and isToolRejection(errText())) {
                use_tools = false;
                event.push(.{ .tool = "model ini nggak mendukung alat file, lanjut tanpa baca file" });
                continue;
            }
            return e;
        };

        if (ctx.calls.len() == 0) return;

        // Simpan balasan alat lalu jalankan alatnya satu per satu.
        var calls_json = util.Str.init();
        for (ctx.calls.items, 0..) |c, i| {
            if (i > 0) try calls_json.appendByte(a, ',');
            try calls_json.appendFmt(a, "{{\"id\":", .{});
            try appendJsonString(&calls_json, a, c.id);
            try calls_json.append(a, ",\"type\":\"function\",\"function\":{\"name\":");
            try appendJsonString(&calls_json, a, c.name);
            try calls_json.append(a, ",\"arguments\":");
            try appendJsonString(&calls_json, a, c.args);
            try calls_json.append(a, "}}");
        }
        var assistant = util.Str.init();
        try assistant.append(a, "{\"role\":\"assistant\",\"content\":");
        if (ctx.text.len() == 0) {
            try assistant.append(a, "null");
        } else {
            try appendJsonString(&assistant, a, ctx.text.items());
        }
        try assistant.append(a, ",\"tool_calls\":[");
        try assistant.append(a, calls_json.items());
        try assistant.append(a, "]}");
        try messages.append(a, try assistant.dupe(a));

        for (ctx.calls.items) |call| {
            const args = parseArgs(call.args);
            event.push(.{ .tool = tools.label(std.heap.c_allocator, call.name, args) });
            const result = tools.run(std.heap.c_allocator, call.name, args);
            var msg = util.Str.init();
            try msg.append(a, "{\"role\":\"tool\",\"tool_call_id\":");
            try appendJsonString(&msg, a, call.id);
            try msg.append(a, ",\"content\":");
            try appendJsonString(&msg, a, result);
            try msg.appendByte(a, '}');
            try messages.append(a, try msg.dupe(a));
        }
    }
    event.push(.{ .chunk = "\n\n(berhenti: terlalu banyak langkah baca file)" });
}

fn isToolRejection(msg: []const u8) bool {
    // "400: ...tool..." atau "422: ...function..."
    var status: usize = 0;
    while (status < msg.len and msg[status] >= '0' and msg[status] <= '9') status += 1;
    if (status == 0) return false;
    const code = std.fmt.parseInt(u16, msg[0..status], 10) catch return false;
    if (code != 400 and code != 404 and code != 422) return false;
    const lower_body = msg[status..];
    var lower_buf: [512]u8 = undefined;
    const n = @min(lower_body.len, lower_buf.len);
    const lower = std.ascii.lowerString(lower_buf[0..n], lower_body[0..n]);
    return std.mem.indexOf(u8, lower, "tool") != null or std.mem.indexOf(u8, lower, "function") != null;
}

fn messageJson(a: std.mem.Allocator, role: []const u8, content: []const u8) ![]const u8 {
    var s = util.Str.init();
    try s.append(a, "{\"role\":");
    try appendJsonString(&s, a, role);
    try s.append(a, ",\"content\":");
    try appendJsonString(&s, a, content);
    try s.appendByte(a, '}');
    return s.dupe(a);
}

fn lineHandler(ctx: *StreamCtx, raw: []const u8) anyerror!bool {
    const line = std.mem.trim(u8, raw, " \t\r");
    const data = if (std.mem.startsWith(u8, line, "data:"))
        std.mem.trim(u8, line[5..], " \t")
    else
        return true;
    if (std.mem.eql(u8, data, "[DONE]")) {
        ctx.done = true;
        return false;
    }
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, ctx.a, data, .{}) catch return true;
    const choices = switch (parsed) {
        .object => |o| o.get("choices") orelse return true,
        else => return true,
    };
    const first = switch (choices) {
        .array => |arr| if (arr.items.len > 0) arr.items[0] else return true,
        else => return true,
    };
    const delta = switch (first) {
        .object => |o| o.get("delta") orelse return true,
        else => return true,
    };
    if (delta == .object) {
        if (delta.object.get("content")) |c| {
            if (c == .string and c.string.len > 0) {
                try ctx.text.append(ctx.a, c.string);
                event.push(.{ .chunk = c.string });
            }
        }
        if (delta.object.get("tool_calls")) |tc| {
            if (tc == .array) {
                for (tc.array.items) |item| {
                    if (item != .object) continue;
                    const has_id = if (item.object.get("id")) |idv| idv == .string and idv.string.len > 0 else false;
                    var index: usize = 0;
                    if (item.object.get("index")) |iv| {
                        if (iv == .integer and iv.integer >= 0) index = @intCast(iv.integer);
                    } else if (has_id) {
                        index = ctx.calls.len();
                    } else {
                        index = if (ctx.calls.len() == 0) 0 else ctx.calls.len() - 1;
                    }
                    while (ctx.calls.len() <= index) try ctx.calls.append(ctx.a, .{});
                    const call = &ctx.calls.items[index];
                    if (item.object.get("id")) |idv| {
                        if (idv == .string and idv.string.len > 0) call.id = try ctx.a.dupe(u8, idv.string);
                    }
                    if (item.object.get("function")) |fnv| {
                        if (fnv == .object) {
                            if (fnv.object.get("name")) |nv| {
                                if (nv == .string and nv.string.len > 0) call.name = try ctx.a.dupe(u8, nv.string);
                            }
                            if (fnv.object.get("arguments")) |av| {
                                if (av == .string) {
                                    call.args = if (call.args.len == 0)
                                        try ctx.a.dupe(u8, av.string)
                                    else
                                        try std.fmt.allocPrint(ctx.a, "{s}{s}", .{ call.args, av.string });
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    return true;
}

fn parseArgs(raw: []const u8) tools.Args {
    var out = tools.Args{};
    if (raw.len == 0) return out;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, std.heap.c_allocator, raw, .{}) catch return out;
    if (parsed != .object) return out;
    const o = parsed.object;
    if (o.get("path")) |v| {
        if (v == .string) out.path = v.string;
    }
    if (o.get("name")) |v| {
        if (v == .string) out.name = v.string;
    }
    if (o.get("query")) |v| {
        if (v == .string) out.query = v.string;
    }
    if (o.get("start_line")) |v| {
        if (v == .integer and v.integer > 0) out.start_line = @intCast(v.integer);
    }
    if (o.get("max_lines")) |v| {
        if (v == .integer and v.integer > 0) out.max_lines = @intCast(v.integer);
    }
    if (o.get("show_hidden")) |v| {
        if (v == .bool) out.show_hidden = v.bool;
    }
    return out;
}

// ── daftar model ─────────────────────────────────────────

pub const ModelPair = event.Model;

const NON_CHAT = [_][]const u8{ "embed", "whisper", "tts", "dall-e", "moderation", "rerank", "guard", "transcri" };

fn isChatModel(id: []const u8) bool {
    var buf: [512]u8 = undefined;
    const n = @min(id.len, buf.len);
    const lower = std.ascii.lowerString(buf[0..n], id[0..n]);
    for (NON_CHAT) |k| {
        if (std.mem.indexOf(u8, lower, k) != null) return false;
    }
    return true;
}

fn lessPair(_: void, x: ModelPair, y: ModelPair) bool {
    return std.mem.lessThan(u8, x.id, y.id);
}

fn fetchModels(a: std.mem.Allocator, t: *const Target) ![]const ModelPair {
    const url = try std.fmt.allocPrint(a, "{s}/models", .{t.base_url});
    const res = try requestAll(a, t, .GET, url, null);
    try ensureOk(res.status, res.body);
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, res.body, .{}) catch
        return fail("format daftar model nggak dikenal", .{});
    if (parsed != .object) return fail("format daftar model nggak dikenal", .{});
    var arr: ?std.json.Array = null;
    if (parsed.object.get("data")) |d| {
        if (d == .array) arr = d.array;
    }
    if (arr == null) {
        if (parsed.object.get("models")) |d| {
            if (d == .array) arr = d.array;
        }
    }
    const list = arr orelse return fail("format daftar model nggak dikenal", .{});
    var models = util.List(ModelPair).init();
    for (list.items) |m| {
        if (m != .object) continue;
        var id: []const u8 = "";
        if (m.object.get("id")) |v| {
            if (v == .string) id = v.string;
        } else if (m.object.get("name")) |v| {
            if (v == .string) id = v.string;
        }
        id = std.mem.trim(u8, id, " \t\r\n");
        if (std.mem.startsWith(u8, id, "models/")) id = id["models/".len..];
        if (id.len == 0 or !isChatModel(id)) continue;
        var name: []const u8 = "";
        if (m.object.get("name")) |v| {
            if (v == .string and !std.mem.eql(u8, v.string, id)) name = v.string;
        }
        try models.append(a, .{ .id = try a.dupe(u8, id), .name = try a.dupe(u8, name) });
    }
    std.mem.sort(ModelPair, models.items, {}, lessPair);
    // Buang duplikat id yang bersebelahan.
    var out = util.List(ModelPair).init();
    for (models.items) |m| {
        if (out.len() > 0 and std.mem.eql(u8, out.items[out.len() - 1].id, m.id)) continue;
        try out.append(a, m);
    }
    return out.items;
}

// ── Hugging Face Space (Gradio) ───────────────────────────

/// "owner/nama" jadi https://owner-nama.hf.space; URL lengkap dipakai apa adanya.
fn spaceBase(a: std.mem.Allocator, space_in: []const u8) ![]const u8 {
    const space = std.mem.trimEnd(u8, std.mem.trim(u8, space_in, " \t"), "/");
    if (std.mem.startsWith(u8, space, "http")) return a.dupe(u8, space);
    var slug = util.Str.init();
    for (space) |c| {
        const ch: u8 = if (c == '/' or c == '_' or c == '.') '-' else std.ascii.toLower(c);
        try slug.appendByte(a, ch);
    }
    return std.fmt.allocPrint(a, "https://{s}.hf.space", .{slug.items()});
}

/// Space chat lewat API stateless, jadi riwayat dilipat jadi satu pesan kalau sudah lebih dari satu giliran.
fn spacePrompt(a: std.mem.Allocator, history: []const Hist) ![]const u8 {
    var turns = util.List(Hist).init();
    for (history) |m| {
        if (std.mem.eql(u8, m.role, "system")) continue;
        if (std.mem.trim(u8, m.content, " \t\r\n").len == 0) continue;
        try turns.append(a, m);
    }
    if (turns.len() == 0) return "";
    if (turns.len() == 1) return turns.items[0].content;
    var out = util.Str.init();
    try out.append(a, "Riwayat percakapan sejauh ini:\n\n");
    for (turns.items[0 .. turns.len() - 1]) |m| {
        const who = if (std.mem.eql(u8, m.role, "user")) "User" else "Asisten";
        try out.appendFmt(a, "{s}: {s}\n\n", .{ who, std.mem.trim(u8, m.content, " \t\r\n") });
    }
    try out.appendFmt(a, "Pesan terbaru dari user (jawab yang ini):\n{s}", .{std.mem.trim(u8, turns.items[turns.len() - 1].content, " \t\r\n")});
    return out.items();
}

/// Teks dari output Gradio: string, `{content}`/`{value}`, atau elemen terakhir sebuah list.
fn gradioText(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        .array => |arr| if (arr.items.len > 0) gradioText(arr.items[arr.items.len - 1]) else null,
        .object => |o| if (o.get("content")) |c| gradioText(c) else if (o.get("value")) |c| gradioText(c) else null,
        else => null,
    };
}

const SpaceInfo = struct { prefix: []const u8, info: std.json.Value };

fn spaceInfo(a: std.mem.Allocator, t: *const Target, base: []const u8) ?SpaceInfo {
    const prefixes = [_][]const u8{ "gradio_api", "" };
    for (prefixes) |prefix| {
        const url = if (prefix.len == 0)
            std.fmt.allocPrint(a, "{s}/info", .{base}) catch continue
        else
            std.fmt.allocPrint(a, "{s}/{s}/info", .{ base, prefix }) catch continue;
        const res = requestAll(a, t, .GET, url, null) catch continue;
        if (!isOk(res.status)) continue;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, res.body, .{}) catch continue;
        return .{ .prefix = prefix, .info = parsed };
    }
    return null;
}

const SpaceCtx = struct {
    a: std.mem.Allocator,
    event: util.Str = .{},
    shown: util.Str = .{},
    complete: bool = false,
    failed: ?[]const u8 = null,
};

fn spaceLine(ctx: *SpaceCtx, raw: []const u8) anyerror!bool {
    const line = std.mem.trim(u8, raw, " \t\r");
    if (std.mem.startsWith(u8, line, "event:")) {
        const name = std.mem.trim(u8, line["event:".len..], " \t");
        ctx.event.clear();
        try ctx.event.append(ctx.a, name);
        return true;
    }
    const payload = if (std.mem.startsWith(u8, line, "data:"))
        std.mem.trim(u8, line["data:".len..], " \t")
    else
        return true;
    const ev = ctx.event.items();
    if (std.mem.eql(u8, ev, "generating") or std.mem.eql(u8, ev, "complete")) {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, ctx.a, payload, .{}) catch return true;
        if (gradioText(parsed)) |text| {
            if (std.mem.startsWith(u8, text, ctx.shown.items())) {
                const rest = text[ctx.shown.len()..];
                if (rest.len > 0) {
                    event.push(.{ .chunk = rest });
                    try ctx.shown.append(ctx.a, rest);
                }
            } else {
                event.push(.{ .chunk = text });
                try ctx.shown.append(ctx.a, text);
            }
        }
        if (std.mem.eql(u8, ev, "complete")) {
            ctx.complete = true;
            return false;
        }
    } else if (std.mem.eql(u8, ev, "error")) {
        const cut = @min(payload.len, 160);
        ctx.failed = std.fmt.allocPrint(ctx.a, "Space error: {s}", .{payload[0..cut]}) catch "Space error";
        return false;
    }
    return true;
}

fn streamSpace(a: std.mem.Allocator, t: *const Target, history: []const Hist) !void {
    const model = std.mem.trim(u8, t.model, " \t");
    if (model.len == 0) return fail("belum ada Space: isi id-nya lewat /model owner/nama (atau env HF_SPACE)", .{});
    const base = try spaceBase(a, model);
    var api: ?[]const u8 = null;
    if (fsx.envNonEmpty(a, "HF_SPACE_API")) |raw| {
        const v = std.mem.trim(u8, raw, " \t/");
        if (v.len > 0) api = v;
    }

    var data = util.List([]const u8).init();
    try data.append(a, try jsonQuoted(a, try spacePrompt(a, history)));
    var prefix: []const u8 = "gradio_api";
    if (spaceInfo(a, t, base)) |found| {
        prefix = found.prefix;
        if (found.info == .object) {
            if (found.info.object.get("named_endpoints")) |ep| {
                if (ep == .object) {
                    const wanted = try std.fmt.allocPrint(a, "/{s}", .{api orelse "chat"});
                    var key: ?[]const u8 = null;
                    if (ep.object.get(wanted) != null) {
                        key = wanted;
                    } else if (ep.object.count() > 0) {
                        key = ep.object.keys()[0];
                    }
                    if (key) |k| {
                        api = std.mem.trimStart(u8, k, "/");
                        const endpoint = ep.object.get(k).?;
                        if (endpoint == .object) {
                            if (endpoint.object.get("parameters")) |params| {
                                if (params == .array) {
                                    const items = params.array.items;
                                    var i: usize = 1;
                                    while (i < items.len) : (i += 1) {
                                        const p = items[i];
                                        var has_default = false;
                                        var def: []const u8 = "null";
                                        if (p == .object) {
                                            if (p.object.get("parameter_has_default")) |hv| {
                                                if (hv == .bool) has_default = hv.bool;
                                            }
                                            if (p.object.get("parameter_default")) |dv| {
                                                def = try jsonValue(a, dv);
                                            }
                                        }
                                        try data.append(a, if (has_default) def else "null");
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    if (fsx.envNonEmpty(a, "HF_SPACE_ARGS")) |raw| {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{}) catch null;
        if (parsed) |p| {
            if (p == .array) {
                data.items = data.items[0..1];
                for (p.array.items) |item| try data.append(a, try jsonValue(a, item));
            }
        }
    }
    const api_name = api orelse "chat";
    const call = if (prefix.len == 0)
        try std.fmt.allocPrint(a, "{s}/call/{s}", .{ base, api_name })
    else
        try std.fmt.allocPrint(a, "{s}/{s}/call/{s}", .{ base, prefix, api_name });

    var body = util.Str.init();
    try body.append(a, "{\"data\":[");
    for (data.items, 0..) |item, i| {
        if (i > 0) try body.appendByte(a, ',');
        try body.append(a, item);
    }
    try body.append(a, "]}");

    const res = try requestAll(a, t, .POST, call, body.items());
    if (res.status == .not_found) {
        return fail("Space atau endpoint /{s} nggak ketemu (cek id Space, atau set HF_SPACE_API)", .{api_name});
    }
    try ensureOk(res.status, res.body);
    const started = std.json.parseFromSliceLeaky(std.json.Value, a, res.body, .{}) catch
        return fail("Space nggak ngasih event_id", .{});
    var event_id: ?[]const u8 = null;
    if (started == .object) {
        if (started.object.get("event_id")) |v| {
            if (v == .string) event_id = v.string;
        }
    }
    const eid = event_id orelse return fail("Space nggak ngasih event_id", .{});

    const url = try std.fmt.allocPrint(a, "{s}/{s}", .{ call, eid });
    var ctx = SpaceCtx{ .a = a };
    try streamLines(a, t, .GET, url, null, &ctx, spaceLine);
    if (ctx.failed) |f| return fail("{s}", .{f});
}

/// Nilai JSON apa adanya (untuk parameter bawaan Space).
fn jsonValue(a: std.mem.Allocator, v: std.json.Value) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, v, .{});
}

fn jsonQuoted(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = util.Str.init();
    try appendJsonString(&out, a, s);
    return out.dupe(a);
}
