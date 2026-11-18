//! Titik masuk: siapkan terminal mentah, muat config, lalu jalankan loop gambar + event.
//! Port 1:1 dari src/main.rs (tanpa tokio: input dibaca langsung, jaringan di thread sendiri).

const std = @import("std");

const app_mod = @import("app.zig");
const config = @import("config.zig");
const event = @import("event.zig");
const fsx = @import("fsx.zig");
const key = @import("key.zig");
const term = @import("term.zig");
const api = @import("api.zig");
const ui = @import("ui.zig");
const screen_mod = @import("ui/screen.zig");

pub fn main() !void {
    const gpa = std.heap.c_allocator;
    fsx.init(gpa);
    api.initIo(fsx.io);

    const cfg = config.Config.load(gpa);
    var app = try app_mod.App.init(gpa, cfg);

    term.enableRaw();
    term.enterAltScreen();

    const first = term.size();
    var scr = try screen_mod.Screen.init(gpa, first.w, first.h);

    while (!app.quit) {
        const sz = term.size();
        if (sz.w != scr.w or sz.h != scr.h) {
            scr.resize(sz.w, sz.h) catch {};
        }
        const cursor = ui.draw(&scr, &app);
        scr.flush(cursor);

        // Tunggu satu event terminal atau tick 50 ms, lalu sedot antrean dari thread jaringan.
        if (term.pollEvent(50)) |ev| {
            app.onEvent(switch (ev) {
                .key => |k| .{ .key = k },
                .mouse => |m| .{ .mouse = m },
            });
        } else {
            app.onEvent(.tick);
        }
        while (event.pop()) |ev| app.onEvent(ev);
    }

    scr.flush(null);
    term.leaveAltScreen();
    term.disableRaw();
}

test {
    _ = @import("util.zig");
    _ = @import("width.zig");
    _ = @import("provider.zig");
    _ = @import("chat.zig");
    _ = @import("input.zig");
    _ = @import("editor.zig");
    _ = @import("picker.zig");
    _ = @import("files.zig");
    _ = @import("tools.zig");
    _ = @import("config.zig");
    _ = @import("key.zig");
    _ = @import("ui/theme.zig");
    _ = @import("ui/markdown.zig");
    _ = @import("term.zig");
    _ = @import("logo.zig");
    _ = @import("app/commands.zig");
}

test "screen keeps glyph bytes" {
    var s = try screen_mod.Screen.init(std.testing.allocator, 4, 1);
    defer std.testing.allocator.free(s.cells);
    defer std.testing.allocator.free(s.prev);
    s.put(0, 0, "▀", @import("ui/theme.zig").FG, @import("ui/theme.zig").BG);
    try std.testing.expectEqual(@as(u8, 3), s.cells[0].len);
    try std.testing.expectEqualStrings("▀", s.cells[0].ch());
}

test "first frame has readable text and photo cells" {
    const ai = std.heap.c_allocator;
    fsx.init(ai);
    api.initIo(fsx.io);
    const cfg = config.Config.load(ai);
    var app = try app_mod.App.init(ai, cfg);
    var s = try screen_mod.Screen.init(ai, 80, 24);
    _ = ui.draw(&s, &app);
    var out = @import("util.zig").Str.init();
    defer out.deinit(ai);
    s.render(&out, null);
    // ANSI menyisipkan escape di antara sel, jadi teks dicek dari buffer sel.
    var text = @import("util.zig").Str.init();
    defer text.deinit(ai);
    for (s.cells) |*cell| text.append(ai, cell.ch()) catch {};
    try std.testing.expect(std.mem.indexOf(u8, text.items(), "New session") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items(), "▀") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items(), "Tanya apa aja") != null);
}

test "user message shows in chat area" {
    const ai = std.heap.c_allocator;
    fsx.init(ai);
    api.initIo(fsx.io);
    const cfg = config.Config.load(ai);
    var app = try app_mod.App.init(ai, cfg);
    const chat_mod = @import("chat.zig");
    try app.messages.append(ai, try chat_mod.Message.new(ai, .user, "halo dunia"));
    app.slide = 16;
    var s = try screen_mod.Screen.init(ai, 100, 30);
    _ = ui.draw(&s, &app);
    var out = @import("util.zig").Str.init();
    defer out.deinit(ai);
    s.render(&out, null);
    const body = out.items();
    if (std.mem.indexOf(u8, body, "halo") == null) {
        std.debug.print("\nNO MSG. first 600:\n{s}\n", .{body[0..@min(body.len, 600)]});
        return error.Missing;
    }
}


test "slash dropdown draws command list" {
    const ai = std.heap.c_allocator;
    fsx.init(ai);
    api.initIo(fsx.io);
    const cfg = config.Config.load(ai);
    var app = try app_mod.App.init(ai, cfg);
    for ("/pro") |c| app.input.insert(ai, c);
    var matches = @import("util.zig").List(*const @import("app/commands.zig").Cmd).init();
    defer matches.deinit(ai);
    app.commandMatches(&matches);
    try std.testing.expect(matches.len() > 0);
    var s = try screen_mod.Screen.init(ai, 120, 40);
    _ = ui.draw(&s, &app);
    var text = @import("util.zig").Str.init();
    defer text.deinit(ai);
    for (s.cells) |*cell| text.append(ai, cell.ch()) catch {};
    try std.testing.expect(std.mem.indexOf(u8, text.items(), "provider") != null);
}
