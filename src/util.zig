//! Struktur data kecil yang dipakai di seluruh port: list dinamis dan string builder.
//! Ditulis di atas std.mem.Allocator saja supaya tidak bergantung pada API std.ArrayList
//! yang berubah antar versi Zig.

const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub fn List(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Panjang slice = jumlah elemen terpakai; `cap` = kapasitas alokasi.
        items: []T = &.{},
        cap: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn len(self: Self) usize {
            return self.items.len;
        }

        pub fn isEmpty(self: Self) bool {
            return self.items.len == 0;
        }

        pub fn slice(self: Self) []T {
            return self.items;
        }

        fn ensure(self: *Self, a: Allocator, total: usize) !void {
            if (total <= self.cap) return;
            var new_cap: usize = if (self.cap == 0) 8 else self.cap;
            while (new_cap < total) new_cap = new_cap + new_cap / 2 + 1;
            if (self.cap == 0) {
                const mem = try a.alloc(T, new_cap);
                self.items = mem[0..0];
            } else {
                const old = self.items.ptr[0..self.cap];
                const mem = try a.realloc(old, new_cap);
                self.items = mem[0..self.items.len];
            }
            self.cap = new_cap;
        }

        pub fn append(self: *Self, a: Allocator, value: T) !void {
            try self.ensure(a, self.items.len + 1);
            const n = self.items.len;
            self.items = self.items.ptr[0 .. n + 1];
            self.items[n] = value;
        }

        pub fn appendSlice(self: *Self, a: Allocator, values: []const T) !void {
            if (values.len == 0) return;
            try self.ensure(a, self.items.len + values.len);
            const n = self.items.len;
            self.items = self.items.ptr[0 .. n + values.len];
            @memcpy(self.items[n..], values);
        }

        pub fn addOne(self: *Self, a: Allocator) !*T {
            try self.ensure(a, self.items.len + 1);
            const n = self.items.len;
            self.items = self.items.ptr[0 .. n + 1];
            return &self.items[n];
        }

        pub fn pop(self: *Self) ?T {
            if (self.items.len == 0) return null;
            const n = self.items.len - 1;
            const v = self.items[n];
            self.items = self.items[0..n];
            return v;
        }

        pub fn insert(self: *Self, a: Allocator, index: usize, value: T) !void {
            try self.ensure(a, self.items.len + 1);
            const n = self.items.len;
            self.items = self.items.ptr[0 .. n + 1];
            var i = n;
            while (i > index) : (i -= 1) self.items[i] = self.items[i - 1];
            self.items[index] = value;
        }

        pub fn remove(self: *Self, index: usize) T {
            const v = self.items[index];
            var i = index;
            while (i + 1 < self.items.len) : (i += 1) self.items[i] = self.items[i + 1];
            self.items = self.items[0 .. self.items.len - 1];
            return v;
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.items = self.items[0..0];
        }

        pub fn last(self: Self) ?*T {
            if (self.items.len == 0) return null;
            return &self.items[self.items.len - 1];
        }

        pub fn first(self: Self) ?*T {
            if (self.items.len == 0) return null;
            return &self.items[0];
        }

        pub fn deinit(self: *Self, a: Allocator) void {
            if (self.cap > 0) a.free(self.items.ptr[0..self.cap]);
            self.items = &.{};
            self.cap = 0;
        }
    };
}

pub const Str = struct {
    buf: []u8 = &.{},
    len_: usize = 0,
    cap: usize = 0,

    pub fn init() Str {
        return .{};
    }

    pub fn from(a: Allocator, s: []const u8) !Str {
        var out = Str{};
        try out.append(a, s);
        return out;
    }

    pub fn clone(a: Allocator, s: []const u8) Str {
        var out = Str{};
        out.append(a, s) catch {};
        return out;
    }

    pub fn items(self: Str) []const u8 {
        return self.buf[0..self.len_];
    }

    pub fn slice(self: *Str) []u8 {
        return self.buf[0..self.len_];
    }

    pub fn len(self: Str) usize {
        return self.len_;
    }

    pub fn isEmpty(self: Str) bool {
        return self.len_ == 0;
    }

    pub fn clear(self: *Str) void {
        self.len_ = 0;
    }

    pub fn ensure(self: *Str, a: Allocator, total: usize) !void {
        if (total <= self.cap) return;
        var new_cap: usize = if (self.cap == 0) 16 else self.cap;
        while (new_cap < total) new_cap = new_cap + new_cap / 2 + 1;
        if (self.cap == 0) {
            self.buf = try a.alloc(u8, new_cap);
        } else {
            self.buf = try a.realloc(self.buf[0..self.cap], new_cap);
        }
        self.cap = new_cap;
    }

    pub fn append(self: *Str, a: Allocator, s: []const u8) !void {
        try self.ensure(a, self.len_ + s.len);
        @memcpy(self.buf[self.len_ .. self.len_ + s.len], s);
        self.len_ += s.len;
    }

    pub fn appendByte(self: *Str, a: Allocator, c: u8) !void {
        try self.ensure(a, self.len_ + 1);
        self.buf[self.len_] = c;
        self.len_ += 1;
    }

    pub fn appendFmt(self: *Str, a: Allocator, comptime fmt: []const u8, args: anytype) !void {
        const extra = std.fmt.count(fmt, args);
        try self.ensure(a, self.len_ + extra);
        const written = try std.fmt.bufPrint(self.buf[self.len_ .. self.len_ + extra], fmt, args);
        self.len_ += written.len;
    }

    /// Salin isi jadi slice milik alokator (untuk disimpan setelah buffer ini dipakai lagi).
    pub fn dupe(self: Str, a: Allocator) ![]u8 {
        const out = try a.alloc(u8, self.len_);
        @memcpy(out, self.buf[0..self.len_]);
        return out;
    }

    pub fn dupeZ(self: Str, a: Allocator) ![:0]u8 {
        const out = try a.allocSentinel(u8, self.len_, 0);
        @memcpy(out[0..self.len_], self.buf[0..self.len_]);
        return out;
    }

    pub fn deinit(self: *Str, a: Allocator) void {
        if (self.cap > 0) a.free(self.buf[0..self.cap]);
        self.buf = &.{};
        self.len_ = 0;
        self.cap = 0;
    }
};

test "str grows" {
    const a = std.testing.allocator;
    var s = Str.init();
    defer s.deinit(a);
    try s.append(a, "halo");
    try s.append(a, " dunia");
    try std.testing.expectEqualStrings("halo dunia", s.items());
}

test "list append and remove" {
    const a = std.testing.allocator;
    var l = List(u32).init();
    defer l.deinit(a);
    try l.append(a, 1);
    try l.append(a, 2);
    try l.insert(a, 1, 9);
    _ = l.remove(0);
    try std.testing.expectEqual(@as(usize, 2), l.len());
    try std.testing.expectEqual(@as(u32, 9), l.items[0]);
}
