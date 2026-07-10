//! An axis-aligned rectangle of cells: position + size, in whatever
//! coordinate space the user of it defines (Surface-absolute for Region).
const Rect = @This();

const std = @import("std");

x: u16 = 0,
y: u16 = 0,
width: u16 = 0,
height: u16 = 0,

pub fn isEmpty(self: Rect) bool {
    return self.width == 0 or self.height == 0;
}

/// The overlapping rectangle of `a` and `b`; empty when they are disjoint.
pub fn intersect(a: Rect, b: Rect) Rect {
    const x1 = @max(a.x, b.x);
    const y1 = @max(a.y, b.y);
    const x2 = @min(@as(u32, a.x) + a.width, @as(u32, b.x) + b.width);
    const y2 = @min(@as(u32, a.y) + a.height, @as(u32, b.y) + b.height);
    if (x2 <= x1 or y2 <= y1) return .{ .x = x1, .y = y1 };
    return .{
        .x = x1,
        .y = y1,
        .width = @intCast(x2 - x1),
        .height = @intCast(y2 - y1),
    };
}

/// Whether the point (x, y) falls inside — handy for mouse hit-testing.
pub fn contains(self: Rect, x: u16, y: u16) bool {
    return x >= self.x and y >= self.y and
        @as(u32, x) < @as(u32, self.x) + self.width and
        @as(u32, y) < @as(u32, self.y) + self.height;
}

pub const Inset = struct {
    left: u16 = 0,
    right: u16 = 0,
    top: u16 = 0,
    bottom: u16 = 0,

    /// The same margin on all four sides.
    pub fn uniform(n: u16) Inset {
        return .{ .left = n, .right = n, .top = n, .bottom = n };
    }
};

/// The rectangle with `m` shaved off each side; collapses to empty (never
/// wraps) when the margins meet.
pub fn inset(self: Rect, m: Inset) Rect {
    const mw = @min(@as(u32, m.left) + m.right, self.width);
    const mh = @min(@as(u32, m.top) + m.bottom, self.height);
    return .{
        .x = self.x +| @min(m.left, self.width),
        .y = self.y +| @min(m.top, self.height),
        .width = @intCast(self.width - mw),
        .height = @intCast(self.height - mh),
    };
}

/// A rect of at most (w, h) centered inside this one — modals, dialogs.
pub fn centered(self: Rect, w: u16, h: u16) Rect {
    const cw = @min(w, self.width);
    const ch = @min(h, self.height);
    return .{
        .x = self.x + (self.width - cw) / 2,
        .y = self.y + (self.height - ch) / 2,
        .width = cw,
        .height = ch,
    };
}

test "intersect overlapping and disjoint" {
    const a: Rect = .{ .x = 0, .y = 0, .width = 10, .height = 5 };
    const b: Rect = .{ .x = 4, .y = 3, .width = 10, .height = 5 };
    try std.testing.expectEqual(Rect{ .x = 4, .y = 3, .width = 6, .height = 2 }, a.intersect(b));
    try std.testing.expectEqual(a.intersect(b), b.intersect(a));

    const far: Rect = .{ .x = 50, .y = 50, .width = 1, .height = 1 };
    try std.testing.expect(a.intersect(far).isEmpty());

    // touching edges don't overlap
    const beside: Rect = .{ .x = 10, .y = 0, .width = 3, .height = 5 };
    try std.testing.expect(a.intersect(beside).isEmpty());
}

test "inset shrinks and saturates" {
    const r: Rect = .{ .x = 1, .y = 1, .width = 10, .height = 6 };
    try std.testing.expectEqual(
        Rect{ .x = 2, .y = 2, .width = 8, .height = 4 },
        r.inset(Inset.uniform(1)),
    );
    try std.testing.expectEqual(
        Rect{ .x = 3, .y = 1, .width = 8, .height = 6 },
        r.inset(.{ .left = 2 }),
    );
    // margins meeting or exceeding the size collapse to empty, never wrap
    try std.testing.expect(r.inset(Inset.uniform(5)).isEmpty());
    try std.testing.expect(r.inset(.{ .left = 99 }).isEmpty());
}

test "centered places and clamps" {
    const r: Rect = .{ .x = 2, .y = 2, .width = 10, .height = 6 };
    try std.testing.expectEqual(
        Rect{ .x = 5, .y = 4, .width = 4, .height = 2 },
        r.centered(4, 2),
    );
    // larger than the container: clamps to it
    try std.testing.expectEqual(r, r.centered(99, 99));
}

test "contains is inclusive of origin, exclusive of far edge" {
    const r: Rect = .{ .x = 2, .y = 1, .width = 3, .height = 2 };
    try std.testing.expect(r.contains(2, 1));
    try std.testing.expect(r.contains(4, 2));
    try std.testing.expect(!r.contains(5, 1));
    try std.testing.expect(!r.contains(2, 3));
    try std.testing.expect(!r.contains(0, 0));
}
