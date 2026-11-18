//! Semua yang bisa membangunkan loop utama: tombol, mouse, tick animasi, potongan balasan,
//! ringkasan alat, selesai/gagal, dan daftar model dari provider.

const std = @import("std");
const key = @import("key.zig");

pub const Model = struct { id: []const u8, name: []const u8 };

pub const Ev = union(enum) {
    tick,
    key: key.Key,
    mouse: key.Mouse,
    chunk: []const u8,
    /// Model memakai alat file; isinya ringkasan buat layar.
    tool: []const u8,
    done,
    failed: []const u8,
    models: struct {
        provider: []const u8,
        ok: ?[]const Model = null,
        err: []const u8 = "",
    },
};

/// Kunci putar sederhana: antrean diisi thread jaringan, disedot loop utama.
var locked = std.atomic.Value(bool).init(false);

fn lock() void {
    while (locked.swap(true, .acquire)) std.Thread.yield() catch {};
}

fn unlock() void {
    locked.store(false, .release);
}

var queue: std.ArrayListUnmanaged(Ev) = .empty;

/// Dipanggil dari thread mana pun (worker jaringan).
pub fn push(ev: Ev) void {
    lock();
    defer unlock();
    queue.append(std.heap.c_allocator, ev) catch {};
}

pub fn pop() ?Ev {
    lock();
    defer unlock();
    if (queue.items.len == 0) return null;
    return queue.orderedRemove(0);
}
