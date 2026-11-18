//! Model percakapan. Port 1:1 dari src/chat.rs.

const std = @import("std");
const util = @import("util.zig");

pub const Role = enum {
    system,
    user,
    assistant,

    pub fn asStr(self: Role) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
        };
    }
};

pub const Message = struct {
    role: Role,
    content: util.Str = .{},
    /// Label kecil di bawah balasan, mis. "Claudia · model".
    tag: []const u8 = "",
    /// Nama lampiran yang ditampilkan di bawah pesan user.
    files: util.List([]const u8) = .{},
    /// Isi lampiran; ikut dikirim ke model tapi tidak ditampilkan.
    context: []const u8 = "",
    /// Alat file yang dipakai model buat balasan ini; hanya ditampilkan, tidak dikirim balik.
    tools: util.List([]const u8) = .{},

    pub fn new(a: std.mem.Allocator, role: Role, text: []const u8) !Message {
        var m = Message{ .role = role };
        try m.content.append(a, text);
        return m;
    }

    pub fn setTag(self: *Message, tag: []const u8) void {
        self.tag = tag;
    }

    pub fn setFiles(self: *Message, files: []const []const u8, context: []const u8) void {
        self.files.items = @constCast(files);
        self.context = context;
    }

    /// Yang dikirim ke model: teks pesan ditambah isi lampiran.
    pub fn full(self: *const Message, a: std.mem.Allocator) ![]u8 {
        const out = try a.alloc(u8, self.content.len() + self.context.len);
        @memcpy(out[0..self.content.len()], self.content.items());
        @memcpy(out[self.content.len()..], self.context);
        return out;
    }

    pub fn pushContent(self: *Message, a: std.mem.Allocator, text: []const u8) !void {
        try self.content.append(a, text);
    }

    pub fn pushTool(self: *Message, a: std.mem.Allocator, label: []const u8) !void {
        try self.tools.append(a, label);
    }
};
