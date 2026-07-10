//! A one-row tab bar. The application owns which tab is active (a plain
//! `usize` — no State struct needed) and switches what it draws beneath;
//! the widget just renders the labels. `hitTest` maps a mouse column back
//! to a tab index for click-to-switch.
const Tabs = @This();

const std = @import("std");
const Region = @import("../Region.zig");
const Surface = @import("../Surface.zig");
const unicode = @import("../unicode.zig");

titles: []const []const u8 = &.{},
selected: usize = 0,
opts: Surface.Options = .{ .attrs = .{ .dim = true } },
selected_opts: Surface.Options = .{ .attrs = .{ .bold = true } },
divider: []const u8 = " │ ",

/// Draw the bar into the region's first row.
pub fn draw(self: Tabs, region: Region) void {
    if (region.height() == 0) return;
    var x: u16 = 0;
    for (self.titles, 0..) |title, i| {
        if (i > 0) x += region.writeText(x, 0, self.divider, .{ .attrs = .{ .dim = true } });
        const o = if (i == self.selected) self.selected_opts else self.opts;
        x += region.writeText(x, 0, title, o);
        if (x >= region.width()) break;
    }
}

/// The tab at region-relative column `col`, or null if it's on a divider
/// or past the last tab — feed it `m.col - region.rect.x` on mouse press.
pub fn hitTest(self: Tabs, col: u16) ?usize {
    var x: usize = 0;
    const divider_w = unicode.strWidth(self.divider);
    for (self.titles, 0..) |title, i| {
        if (i > 0) x += divider_w;
        const end = x + unicode.strWidth(title);
        if (col < x) return null; // on the divider before this tab
        if (col < end) return i;
        x = end;
    }
    return null;
}

// --- tests ------------------------------------------------------------

test "renders titles with the selection emphasized" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 20, 1);
    defer s.deinit(gpa);

    (Tabs{ .titles = &.{ "een", "twee" }, .selected = 1 }).draw(Region.full(&s));
    try std.testing.expectEqualStrings("e", s.cellAt(0, 0).?.grapheme());
    try std.testing.expect(s.cellAt(0, 0).?.style.attrs.dim);
    try std.testing.expectEqualStrings("│", s.cellAt(4, 0).?.grapheme());
    try std.testing.expectEqualStrings("t", s.cellAt(6, 0).?.grapheme());
    try std.testing.expect(s.cellAt(6, 0).?.style.attrs.bold);
}

test "hitTest maps columns to tabs" {
    const t: Tabs = .{ .titles = &.{ "een", "twee" } }; // een: 0-2, div: 3-5, twee: 6-9
    try std.testing.expectEqual(@as(?usize, 0), t.hitTest(0));
    try std.testing.expectEqual(@as(?usize, 0), t.hitTest(2));
    try std.testing.expectEqual(@as(?usize, null), t.hitTest(4));
    try std.testing.expectEqual(@as(?usize, 1), t.hitTest(6));
    try std.testing.expectEqual(@as(?usize, 1), t.hitTest(9));
    try std.testing.expectEqual(@as(?usize, null), t.hitTest(10));
}
