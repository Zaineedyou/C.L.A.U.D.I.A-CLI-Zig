//! Dropdown perintah "/" di atas prompt, seperti OpenCode: baris terpilih berlatar ungu, deskripsi redup.
//! Port 1:1 dari src/ui/dropdown.rs.

const std = @import("std");
const util = @import("../util.zig");
const theme = @import("theme.zig");
const anim = @import("anim.zig");
const screen_mod = @import("screen.zig");
const commands = @import("../app/commands.zig");

const Screen = screen_mod.Screen;
const Rect = screen_mod.Rect;

const MAX_ROWS: usize = 10;

pub fn draw(s: *Screen, app: anytype, layout: anytype) void {
    var matches = util.List(*const commands.Cmd).init();
    defer matches.deinit(std.heap.c_allocator);
    app.commandMatches(&matches);
    if (matches.len() == 0 or layout.prompt.w < 12) return;
    const rows: u16 = @intCast(@min(@min(matches.len(), MAX_ROWS), layout.prompt.y -| layout.main.y));
    if (rows == 0) return;
    const area = Rect{ .x = layout.prompt.x, .y = layout.prompt.y - rows, .w = layout.prompt.w, .h = rows };
    const room: usize = @as(usize, area.w) -| 1;
    const sel = @min(app.cmd_sel, matches.len() - 1);
    const top = (sel + 1) -| @as(usize, rows);
    var name_w: usize = 0;
    for (matches.items) |c| name_w = @max(name_w, c.name.len + 1);
    name_w += 2;

    anim.frost(s, area, 0.72);

    const a = app.frameAlloc();
    var y = area.y;
    var i: usize = top;
    while (i < matches.len() and y < area.bottom()) : (i += 1) {
        const cmd = matches.items[i];
        const selected = i == sel;
        const name_color = if (selected) theme.WHITE else theme.FG;
        const desc_color = if (selected) theme.WHITE else theme.DIM;
        const bg = if (selected) theme.AI else theme.BG;

        var x = s.text(area.x, y, "│", theme.mix(theme.BG, theme.DIM, 0.5), bg, area.right());
        // Nama perintah, di-pad sampai name_w.
        const name_text = std.fmt.allocPrint(a, "/{s}", .{cmd.name}) catch cmd.name;
        x = s.textBold(x, y, name_text, name_color, bg, selected, area.right());
        var pad = name_w -| @min(name_w, name_text.len);
        while (pad > 0 and x < area.right()) : (pad -= 1) {
            x = s.text(x, y, " ", name_color, bg, area.right());
        }
        const used: usize = @as(usize, x - area.x);
        const desc_room = room -| used;
        x = s.text(x, y, cmd.desc[0..@min(cmd.desc.len, desc_room)], desc_color, bg, area.right());
        // Sisa baris diisi latar terpilih.
        while (x < area.right()) : (x += 1) {
            s.setBg(x, y, bg);
        }
        y += 1;
    }
}
