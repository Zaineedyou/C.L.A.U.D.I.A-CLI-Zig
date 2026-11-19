//! Layar awal ala OpenCode: logo ASCII di tengah, prompt di bawahnya, versi di pojok kanan bawah.
//! Port dari src/ui/home.rs.

const std = @import("std");
const theme = @import("theme.zig");
const anim = @import("anim.zig");
const screen_mod = @import("screen.zig");

const Screen = screen_mod.Screen;

/// Versi aplikasi, sama dengan Cargo.toml aslinya.
pub const VERSION = "0.4.2";

pub fn draw(s: *Screen, app: anytype, layout: anytype, alpha: f32, logo_h: u16) void {
    _ = logo_h;
    const area = layout.main;
    const logo_w = anim.logoWidth();
    const logo_x = area.x + (area.w -| logo_w) / 2;
    if (area.w >= logo_w + 2) {
        anim.logo(s, logo_x, layout.home_top, app.tick, alpha);
    }

    if (s.w < 44 or s.h < 8) return;
    const w: u16 = @intCast(VERSION.len);
    const x = s.w -| (w + 2);
    const y = s.h - 1;
    const faded = theme.mix(theme.BG, theme.DIM, alpha);
    _ = s.textBold(x, y, VERSION, faded, s.bgAt(x, y), false, s.w);
}
