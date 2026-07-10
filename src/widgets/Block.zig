//! A bordered box with an optional title in the top edge. Stateless, like
//! every widget: configure the struct, `draw` it into a Region each frame,
//! and lay content out in the inner Region it returns.
const Block = @This();

const std = @import("std");
const Region = @import("../Region.zig");
const cell_mod = @import("../cell.zig");
const Cell = cell_mod.Cell;
const Style = cell_mod.Style;

/// Overlaid on the top border starting one cell after the corner run —
/// include your own padding spaces (` log `) for breathing room. Clipped
/// so it never reaches the top-right corner.
title: []const u8 = "",
lines: Lines = .single,
/// Style of the border cells.
style: Style = .{},
/// Style of the title text; defaults to the border style.
title_style: ?Style = null,

pub const Lines = enum {
    single,
    rounded,
    double,
    thick,

    /// The character set for this line style (also used by Separator).
    pub fn chars(self: Lines) Chars {
        return switch (self) {
            .single => .{ .tl = "┌", .tr = "┐", .bl = "└", .br = "┘", .h = "─", .v = "│" },
            .rounded => .{ .tl = "╭", .tr = "╮", .bl = "╰", .br = "╯", .h = "─", .v = "│" },
            .double => .{ .tl = "╔", .tr = "╗", .bl = "╚", .br = "╝", .h = "═", .v = "║" },
            .thick => .{ .tl = "┏", .tr = "┓", .bl = "┗", .br = "┛", .h = "━", .v = "┃" },
        };
    }
};

pub const Chars = struct {
    tl: []const u8,
    tr: []const u8,
    bl: []const u8,
    br: []const u8,
    h: []const u8,
    v: []const u8,
};

/// Draw the border (and title) along the region's edges and return the
/// region one cell inside them. A region smaller than 2×2 draws nothing;
/// the returned inner region is empty then, so content writes are no-ops.
pub fn draw(self: Block, region: Region) Region {
    const w = region.width();
    const h = region.height();
    const inner = region.sub(region.bounds().inset(.uniform(1)));
    if (w < 2 or h < 2) return inner;

    const c = self.lines.chars();
    var x: u16 = 1;
    while (x < w - 1) : (x += 1) {
        region.writeCell(x, 0, Cell.init(c.h, 1, self.style));
        region.writeCell(x, h - 1, Cell.init(c.h, 1, self.style));
    }
    var y: u16 = 1;
    while (y < h - 1) : (y += 1) {
        region.writeCell(0, y, Cell.init(c.v, 1, self.style));
        region.writeCell(w - 1, y, Cell.init(c.v, 1, self.style));
    }
    region.writeCell(0, 0, Cell.init(c.tl, 1, self.style));
    region.writeCell(w - 1, 0, Cell.init(c.tr, 1, self.style));
    region.writeCell(0, h - 1, Cell.init(c.bl, 1, self.style));
    region.writeCell(w - 1, h - 1, Cell.init(c.br, 1, self.style));

    if (self.title.len > 0 and w > 4) {
        const ts = self.title_style orelse self.style;
        // A one-row strip inset from both top corners, so a long title
        // clips instead of eating the corner.
        const strip = region.sub(.{ .x = 2, .y = 0, .width = w - 4, .height = 1 });
        _ = strip.writeText(0, 0, self.title, .{ .fg = ts.fg, .bg = ts.bg, .attrs = ts.attrs });
    }
    return inner;
}

// --- tests ------------------------------------------------------------

const Surface = @import("../Surface.zig");

test "draws border, title, and yields the inner region" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 10, 4);
    defer s.deinit(gpa);

    const b: Block = .{ .title = "hi", .lines = .rounded };
    const inner = b.draw(Region.full(&s));

    try std.testing.expectEqualStrings("╭", s.cellAt(0, 0).?.grapheme());
    try std.testing.expectEqualStrings("╮", s.cellAt(9, 0).?.grapheme());
    try std.testing.expectEqualStrings("╰", s.cellAt(0, 3).?.grapheme());
    try std.testing.expectEqualStrings("╯", s.cellAt(9, 3).?.grapheme());
    try std.testing.expectEqualStrings("─", s.cellAt(1, 0).?.grapheme());
    try std.testing.expectEqualStrings("─", s.cellAt(5, 3).?.grapheme());
    try std.testing.expectEqualStrings("│", s.cellAt(0, 1).?.grapheme());
    try std.testing.expectEqualStrings("│", s.cellAt(9, 2).?.grapheme());

    // title overlays the top edge after one border cell
    try std.testing.expectEqualStrings("h", s.cellAt(2, 0).?.grapheme());
    try std.testing.expectEqualStrings("i", s.cellAt(3, 0).?.grapheme());

    // inner region is one cell in on every side
    try std.testing.expectEqual(@as(u16, 8), inner.width());
    try std.testing.expectEqual(@as(u16, 2), inner.height());
    _ = inner.writeText(0, 0, "x", .{});
    try std.testing.expectEqualStrings("x", s.cellAt(1, 1).?.grapheme());
}

test "long titles clip before the corner" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 8, 3);
    defer s.deinit(gpa);

    const b: Block = .{ .title = "much too long" };
    _ = b.draw(Region.full(&s));

    // strip covers columns 2..5; 6 keeps its border, 7 its corner
    try std.testing.expectEqualStrings("h", s.cellAt(5, 0).?.grapheme());
    try std.testing.expectEqualStrings("─", s.cellAt(6, 0).?.grapheme());
    try std.testing.expectEqualStrings("┐", s.cellAt(7, 0).?.grapheme());
}

test "degenerate regions draw nothing and yield empty inners" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 6, 3);
    defer s.deinit(gpa);

    const b: Block = .{};
    const inner = b.draw(Region.init(&s, .{ .x = 1, .y = 1, .width = 1, .height = 1 }));
    try std.testing.expect(inner.rect.isEmpty());
    try std.testing.expectEqualStrings(" ", s.cellAt(1, 1).?.grapheme()); // untouched
    _ = inner.writeText(0, 0, "x", .{}); // no-op, no crash

    // 2×2 is all border, no interior
    const inner2 = b.draw(Region.init(&s, .{ .x = 0, .y = 0, .width = 2, .height = 2 }));
    try std.testing.expect(inner2.rect.isEmpty());
    try std.testing.expectEqualStrings("┌", s.cellAt(0, 0).?.grapheme());
    try std.testing.expectEqualStrings("┘", s.cellAt(1, 1).?.grapheme());
}

test "border style applies to border cells" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 4, 3);
    defer s.deinit(gpa);

    const b: Block = .{ .style = .{ .fg = .{ .ansi = 4 } } };
    _ = b.draw(Region.full(&s));
    try std.testing.expectEqual(cell_mod.Color{ .ansi = 4 }, s.cellAt(0, 0).?.style.fg);
    try std.testing.expectEqual(cell_mod.Color.default, s.cellAt(1, 1).?.style.fg);
}
