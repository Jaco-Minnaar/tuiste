//! Vocabulary types: what a single terminal cell looks like.
const std = @import("std");

pub const Color = union(enum) {
    default,
    /// The classic 16: 0–7 normal, 8–15 bright.
    ansi: u4,
    /// 256-color palette index.
    indexed: u8,
    rgb: [3]u8,

    pub fn eql(a: Color, b: Color) bool {
        return std.meta.eql(a, b);
    }
};

pub const Attrs = packed struct(u8) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,
    hidden: bool = false,
    strikethrough: bool = false,
};

pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    attrs: Attrs = .{},

    pub fn eql(a: Style, b: Style) bool {
        return std.meta.eql(a, b);
    }
};

pub const Cell = struct {
    /// UTF-8 bytes of one grapheme cluster, stored inline. Clusters that
    /// don't fit are interned in a `GraphemePool` (see `initPooled`); with
    /// no pool available they degrade to U+FFFD.
    bytes: [max_grapheme_bytes]u8 = [_]u8{' '} ++ [_]u8{0} ** (max_grapheme_bytes - 1),
    /// Byte count of the inline grapheme, or `overflow_len` when `bytes`
    /// holds a pool index instead.
    len: u8 = 1,
    /// Terminal columns this cell occupies. 0 marks the spacer cell that
    /// sits behind the second column of a wide grapheme.
    width: u2 = 1,
    style: Style = .{},
    /// OSC 8 hyperlink: 0 for none, else pool index + 1 of the interned URI
    /// (same pool as overflowed graphemes). Resolve via `Surface.linkOf`.
    link: u32 = 0,

    pub const max_grapheme_bytes = 15;

    /// Sentinel `len`: the grapheme lives in the pool and bytes[0..4] hold
    /// its little-endian index.
    pub const overflow_len: u8 = 0xff;

    /// The placeholder occupying the second column of a wide grapheme.
    pub const spacer: Cell = .{ .len = 0, .width = 0 };

    pub fn init(grapheme_bytes: []const u8, width: u2, style: Style) Cell {
        var c: Cell = .{ .len = 0, .width = width, .style = style };
        if (grapheme_bytes.len > max_grapheme_bytes) {
            c.bytes[0..3].* = "\u{FFFD}".*;
            c.len = 3;
            c.width = 1;
            return c;
        }
        @memcpy(c.bytes[0..grapheme_bytes.len], grapheme_bytes);
        c.len = @intCast(grapheme_bytes.len);
        return c;
    }

    /// A cell whose grapheme is interned in a `GraphemePool` at `index`.
    pub fn initPooled(index: u32, width: u2, style: Style) Cell {
        var c: Cell = .{ .len = overflow_len, .width = width, .style = style };
        std.mem.writeInt(u32, c.bytes[0..4], index, .little);
        return c;
    }

    /// Pool index of an overflowed grapheme, or null for inline cells.
    pub fn poolIndex(self: *const Cell) ?u32 {
        if (self.len != overflow_len) return null;
        return std.mem.readInt(u32, self.bytes[0..4], .little);
    }

    /// The inline grapheme bytes. Pooled cells return U+FFFD here — resolve
    /// them through `Surface.graphemeOf`, which has the pool.
    pub fn grapheme(self: *const Cell) []const u8 {
        if (self.len == overflow_len) return "\u{FFFD}";
        return self.bytes[0..self.len];
    }

    pub fn eql(a: Cell, b: Cell) bool {
        if (a.len != b.len or a.width != b.width or a.link != b.link or !a.style.eql(b.style)) return false;
        // Pooled graphemes intern to a unique index, so index equality is
        // content equality (assuming one pool, which the Renderer guarantees).
        const n = if (a.len == overflow_len) 4 else a.len;
        return std.mem.eql(u8, a.bytes[0..n], b.bytes[0..n]);
    }
};

test "default cell is a styled space" {
    const c: Cell = .{};
    try std.testing.expectEqualStrings(" ", c.grapheme());
    try std.testing.expectEqual(@as(u2, 1), c.width);
}

test "cell stores a multibyte grapheme" {
    const c = Cell.init("宽", 2, .{});
    try std.testing.expectEqualStrings("宽", c.grapheme());
    try std.testing.expectEqual(@as(u2, 2), c.width);
}

test "oversized grapheme becomes replacement char" {
    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}";
    const c = Cell.init(family, 2, .{});
    try std.testing.expectEqualStrings("\u{FFFD}", c.grapheme());
}

test "cell equality includes style" {
    const a = Cell.init("x", 1, .{});
    var b = Cell.init("x", 1, .{});
    try std.testing.expect(a.eql(b));
    b.style.fg = .{ .ansi = 1 };
    try std.testing.expect(!a.eql(b));
}

test "cell equality includes link" {
    const a = Cell.init("x", 1, .{});
    var b = Cell.init("x", 1, .{});
    b.link = 1;
    try std.testing.expect(!a.eql(b));
}
