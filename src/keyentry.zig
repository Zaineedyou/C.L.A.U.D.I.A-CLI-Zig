//! Dialog isi API key untuk satu provider. Port 1:1 dari src/keyentry.rs.

const std = @import("std");
const input = @import("input.zig");

pub const KeyEntry = struct {
    /// Indeks di `provider.ALL`.
    provider: usize,
    input: input.Input = .{},
    err: ?[]const u8 = null,
    /// Umur popup dalam tick, untuk animasi buka.
    age: u8 = 0,

    pub fn init(provider: usize) KeyEntry {
        return .{ .provider = provider };
    }
};
