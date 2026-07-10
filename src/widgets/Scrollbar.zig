//! A vertical scrollbar for a one-column strip beside a List, Table, or
//! Paragraph. Fed the same numbers those widgets already expose: the item
//! total (`items.len` / `measure`), the window height, and the offset.
const Scrollbar = @This();

const std = @import("std");
const Region = @import("../Region.zig");
const Surface = @import("../Surface.zig");
const cell_mod = @import("../cell.zig");
const Cell = cell_mod.Cell;
const Style = cell_mod.Style;

/// Total rows of content.
total: usize = 0,
/// Rows visible at once (the companion widget's region height).
window: usize = 0,
/// First visible row (the companion's `State.offset` / `scroll`).
offset: usize = 0,
track: []const u8 = "░",
thumb: []const u8 = "█",
style: Style = .{},

/// Draw down the region's first column. When everything fits the thumb
/// fills the track (nothing to scroll, nothing to signal).
pub fn draw(self: Scrollbar, region: Region) void {
    const h: usize = region.height();
    if (h == 0 or region.width() == 0) return;

    var thumb_len = h;
    var thumb_top: usize = 0;
    if (self.total > self.window and self.total > 0) {
        thumb_len = @max(1, h * self.window / self.total);
        const denom = self.total - self.window;
        thumb_top = (h - thumb_len) * @min(self.offset, denom) / denom;
    }

    var y: u16 = 0;
    while (y < h) : (y += 1) {
        const in_thumb = y >= thumb_top and y < thumb_top + thumb_len;
        region.writeCell(0, y, Cell.init(if (in_thumb) self.thumb else self.track, 1, self.style));
    }
}

// --- tests ------------------------------------------------------------

test "thumb size and position track the window" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 2, 10);
    defer s.deinit(gpa);
    const r = Region.init(&s, .{ .width = 1, .height = 10 });

    // 10-row track over 40 items in a 10-row window: quarter-size thumb
    (Scrollbar{ .total = 40, .window = 10, .offset = 0 }).draw(r);
    try std.testing.expectEqualStrings("█", s.cellAt(0, 0).?.grapheme());
    try std.testing.expectEqualStrings("█", s.cellAt(0, 1).?.grapheme());
    try std.testing.expectEqualStrings("░", s.cellAt(0, 2).?.grapheme());

    // scrolled to the end: thumb at the bottom
    (Scrollbar{ .total = 40, .window = 10, .offset = 30 }).draw(r);
    try std.testing.expectEqualStrings("░", s.cellAt(0, 0).?.grapheme());
    try std.testing.expectEqualStrings("█", s.cellAt(0, 9).?.grapheme());
    try std.testing.expectEqualStrings("█", s.cellAt(0, 8).?.grapheme());

    // midway: thumb in the middle
    (Scrollbar{ .total = 40, .window = 10, .offset = 15 }).draw(r);
    try std.testing.expectEqualStrings("░", s.cellAt(0, 0).?.grapheme());
    try std.testing.expectEqualStrings("█", s.cellAt(0, 4).?.grapheme());
    try std.testing.expectEqualStrings("░", s.cellAt(0, 9).?.grapheme());
}

test "everything visible fills the track" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 1, 4);
    defer s.deinit(gpa);

    (Scrollbar{ .total = 3, .window = 4 }).draw(Region.full(&s));
    try std.testing.expectEqualStrings("█", s.cellAt(0, 0).?.grapheme());
    try std.testing.expectEqualStrings("█", s.cellAt(0, 3).?.grapheme());
}
