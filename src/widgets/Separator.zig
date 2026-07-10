//! A rule between panes: a horizontal line across the region's first row
//! or a vertical line down its first column, in Block's line styles, with
//! an optional embedded label on the horizontal form.
const Separator = @This();

const std = @import("std");
const Region = @import("../Region.zig");
const Surface = @import("../Surface.zig");
const cell_mod = @import("../cell.zig");
const Cell = cell_mod.Cell;
const Style = cell_mod.Style;
const Lines = @import("Block.zig").Lines;

direction: Direction = .horizontal,
lines: Lines = .single,
style: Style = .{},
/// Overlaid on a horizontal rule starting at column 2 (`── label ──`);
/// include your own padding spaces. Ignored for vertical rules.
label: []const u8 = "",
label_opts: ?Surface.Options = null,

pub const Direction = enum { horizontal, vertical };

pub fn draw(self: Separator, region: Region) void {
    const c = self.lines.chars();
    switch (self.direction) {
        .horizontal => {
            const w = region.width();
            if (w == 0 or region.height() == 0) return;
            var x: u16 = 0;
            while (x < w) : (x += 1) region.writeCell(x, 0, Cell.init(c.h, 1, self.style));
            if (self.label.len > 0 and w > 2) {
                const o = self.label_opts orelse Surface.Options{
                    .fg = self.style.fg,
                    .bg = self.style.bg,
                    .attrs = self.style.attrs,
                };
                const strip = region.sub(.{ .x = 2, .y = 0, .width = w - 2, .height = 1 });
                _ = strip.writeText(0, 0, self.label, o);
            }
        },
        .vertical => {
            const h = region.height();
            if (h == 0 or region.width() == 0) return;
            var y: u16 = 0;
            while (y < h) : (y += 1) region.writeCell(0, y, Cell.init(c.v, 1, self.style));
        },
    }
}

// --- tests ------------------------------------------------------------

test "horizontal rule with a label" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 10, 1);
    defer s.deinit(gpa);

    (Separator{ .label = " af " }).draw(Region.full(&s));
    try std.testing.expectEqualStrings("─", s.cellAt(0, 0).?.grapheme());
    try std.testing.expectEqualStrings("─", s.cellAt(1, 0).?.grapheme());
    try std.testing.expectEqualStrings(" ", s.cellAt(2, 0).?.grapheme());
    try std.testing.expectEqualStrings("a", s.cellAt(3, 0).?.grapheme());
    try std.testing.expectEqualStrings("─", s.cellAt(6, 0).?.grapheme());
    try std.testing.expectEqualStrings("─", s.cellAt(9, 0).?.grapheme());
}

test "vertical rule" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 3, 3);
    defer s.deinit(gpa);

    (Separator{ .direction = .vertical, .lines = .double }).draw(
        Region.init(&s, .{ .x = 1, .y = 0, .width = 1, .height = 3 }),
    );
    try std.testing.expectEqualStrings("║", s.cellAt(1, 0).?.grapheme());
    try std.testing.expectEqualStrings("║", s.cellAt(1, 2).?.grapheme());
    try std.testing.expectEqualStrings(" ", s.cellAt(0, 0).?.grapheme());
}
