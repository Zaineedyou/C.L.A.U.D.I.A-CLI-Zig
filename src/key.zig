//! Tombol dan event terminal. Pengganti tipe KeyCode/KeyEvent/MouseEvent dari crossterm.

const std = @import("std");

pub const Mods = struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
};

pub const Code = union(enum) {
    char: u21,
    enter,
    esc,
    tab,
    back_tab,
    backspace,
    delete,
    insert,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    f: u8,
    other,
};

pub const Kind = enum { press, release, repeat };

pub const Key = struct {
    code: Code,
    mods: Mods = .{},
    kind: Kind = .press,

    pub fn is(self: Key, code: Code) bool {
        return std.meta.eql(self.code, code);
    }
};

pub const MouseButton = enum { left, right, middle, none };

pub const MouseKind = union(enum) {
    down: MouseButton,
    up: MouseButton,
    drag: MouseButton,
    moved,
    scroll_up,
    scroll_down,
    scroll_left,
    scroll_right,
};

pub const Mouse = struct {
    kind: MouseKind,
    /// 0-based.
    column: u16,
    /// 0-based.
    row: u16,
};
