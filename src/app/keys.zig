//! Penanganan tombol dan mouse. Port 1:1 dari src/app/keys.rs.

const std = @import("std");
const util = @import("../util.zig");
const key = @import("../key.zig");
const app_mod = @import("../app.zig");
const editor_mod = @import("../editor.zig");
const files = @import("../files.zig");
const picker_mod = @import("../picker.zig");
const tabs = @import("../ui/tabs.zig");
const commands = @import("../app/commands.zig");
const config = @import("../config.zig");

const App = app_mod.App;

pub fn onKey(self: *App, k: key.Key) void {
    const ctrl = k.mods.ctrl;
    const alt = k.mods.alt;
    if (ctrl and k.is(.{ .char = 'c' })) {
        self.quit = true;
    } else if (self.editor != null) {
        editorKey(self, k.code, ctrl);
    } else if (self.browser != null) {
        browserKey(self, k.code, ctrl);
    } else if (self.keyentry != null) {
        keyentryKey(self, k.code, ctrl);
    } else if (self.picker != null) {
        pickerKey(self, k.code, ctrl);
    } else if (alt and tabKey(self, k.code)) {
        // Alt+panah / Alt+angka sudah ditangani sebagai pindah tab.
    } else {
        chatKey(self, k.code, ctrl);
    }
}

/// Klik kiri pada tab atau "+" di baris sesi; roda/geser menggulir percakapan.
pub fn onMouse(self: *App, m: key.Mouse) void {
    switch (m.kind) {
        .down => |btn| {
            if (btn != .left) return;
            if (self.picker != null or self.editor != null or self.keyentry != null or self.browser != null) return;
            var hits = util.List(tabs.Hit).init();
            tabs.hits(self.a, self.tab_area, self, &hits);
            for (hits.items) |hit| {
                if (hit.rect.contains(m.column, m.row)) {
                    switch (hit.click) {
                        .tab => |i| self.switchTab(i),
                        .new => self.newTab(),
                    }
                    return;
                }
            }
        },
        .scroll_up => self.scroll += 3,
        .scroll_down => self.scroll -|= 3,
        else => {},
    }
}

/// Alt+Bawah/Kanan tab berikutnya, Alt+Atas/Kiri sebelumnya, Alt+1..9 langsung ke tab itu.
fn tabKey(self: *App, code: key.Code) bool {
    switch (code) {
        .down, .right => self.stepTab(1),
        .up, .left => self.stepTab(-1),
        .char => |c| {
            if (c >= '1' and c <= '9') {
                self.switchTab(@intCast(c - '1'));
            } else return false;
        },
        else => return false,
    }
    return true;
}

fn editorKey(self: *App, code: key.Code, ctrl: bool) void {
    if (code == .esc) {
        self.editor = null;
        return;
    }
    if (code == .char) {
        const c = code.char;
        if (ctrl and c == 's') {
            self.saveSystem();
            return;
        }
        if (ctrl and c == 'r') {
            const text = config.Config.defaultSystem(self.a, self.cfg.name);
            self.editor = editor_mod.Editor.init(self.a, text) catch null;
            return;
        }
        if (ctrl and c == 'u') {
            self.editor = editor_mod.Editor.init(self.a, "") catch null;
            return;
        }
    }
    if (ctrl) return;
    if (self.editor) |*editor| editor.handle(self.a, code);
}

fn browserKey(self: *App, code: key.Code, ctrl: bool) void {
    const browser = if (self.browser) |*b| b else return;
    switch (browser.handle(self.a, code, ctrl)) {
        .none => {},
        .close => self.browser = null,
        .attach => |att| {
            if (self.attach(att.path) and !att.stay) self.browser = null;
        },
    }
}

fn keyentryKey(self: *App, code: key.Code, ctrl: bool) void {
    if (code == .esc) {
        self.keyentry = null;
        self.openConnect();
        return;
    }
    if (code == .enter) {
        self.saveKey();
        return;
    }
    if (code == .char and ctrl and code.char == 'u') {
        if (self.keyentry) |*e| e.input.clear();
        return;
    }
    if (ctrl) return;
    if (self.keyentry) |*entry| {
        entry.err = null;
        switch (code) {
            .char => |c| entry.input.insert(self.a, c),
            .backspace => entry.input.backspace(),
            .delete => entry.input.delete(),
            .left => entry.input.left(),
            .right => entry.input.right(),
            .home => entry.input.home(),
            .end => entry.input.end(),
            else => {},
        }
    }
}

fn pickerKey(self: *App, code: key.Code, ctrl: bool) void {
    switch (code) {
        .esc => {
            self.picker = null;
            return;
        },
        .enter => {
            self.confirmPick();
            return;
        },
        else => {},
    }
    if (ctrl) return;
    if (self.picker) |*picker| picker.handle(self.a, code);
}

fn chatKey(self: *App, code: key.Code, ctrl: bool) void {
    // Dropdown perintah "/": panah pilih, Tab melengkapi, Enter menjalankan, Esc menutup.
    var matches = util.List(*const @import("../app/commands.zig").Cmd).init();
    self.commandMatches(&matches);
    if (matches.len() > 0) {
        const count = matches.len();
        const sel = @min(self.cmd_sel, count - 1);
        switch (code) {
            .up => {
                self.cmd_sel = (sel + count - 1) % count;
                return;
            },
            .down => {
                self.cmd_sel = (sel + 1) % count;
                return;
            },
            .tab => {
                self.completeCommand(matches.items[sel]);
                return;
            },
            .enter => {
                const cmd = matches.items[sel];
                if (cmd.arg) {
                    self.completeCommand(cmd);
                } else {
                    self.input.clear();
                    self.cmd_sel = 0;
                    const line = std.fmt.allocPrint(self.a, "/{s}", .{cmd.name}) catch return;
                    commands.run(self, line);
                }
                return;
            },
            .esc => {
                self.input.clear();
                self.cmd_sel = 0;
                return;
            },
            else => {},
        }
    }
    switch (code) {
        .char, .backspace, .delete => self.cmd_sel = 0,
        else => {},
    }

    switch (code) {
        .char => |c| {
            if (ctrl) {
                switch (c) {
                    'd' => if (self.input.isEmpty()) {
                        self.quit = true;
                    },
                    'l' => self.clear(),
                    'f' => self.openFiles(null),
                    'x' => if (self.attachments.len() > 0) {
                        self.attachments.clearRetainingCapacity();
                        self.info("lampiran dilepas");
                    },
                    'n' => self.newTab(),
                    'w' => self.closeTab(),
                    'u' => self.input.clear(),
                    'p' => self.openCommands(),
                    'o' => self.openModels(),
                    'a' => self.input.home(),
                    'e' => self.input.end(),
                    else => {},
                }
            } else {
                self.input.insert(self.a, c);
            }
        },
        .enter => self.submit(),
        .backspace => self.input.backspace(),
        .delete => self.input.delete(),
        .left => self.input.left(),
        .right => self.input.right(),
        .home => self.input.home(),
        .end => {
            self.input.end();
            self.scroll = 0;
        },
        .up => self.scroll += 1,
        .down => self.scroll -|= 1,
        .page_up => self.scroll += 10,
        .page_down => self.scroll -|= 10,
        .esc => self.cancel(),
        else => {},
    }
}
