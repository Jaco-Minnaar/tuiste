//! Fills a region with a styled blank — the underlay for anything drawn on
//! top of other content. `Rect.centered` + Clear + Block is a complete
//! modal: without the Clear, whatever the popup doesn't paint would show
//! the content underneath.
const Clear = @This();

const std = @import("std");
const Region = @import("../Region.zig");
const cell_mod = @import("../cell.zig");
const Cell = cell_mod.Cell;
const Style = cell_mod.Style;

style: Style = .{},

pub fn draw(self: Clear, region: Region) void {
    var c: Cell = .{};
    c.style = self.style;
    region.fill(c);
}

// --- tests ------------------------------------------------------------

const Surface = @import("../Surface.zig");

test "clears exactly the region with the style" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 6, 3);
    defer s.deinit(gpa);

    _ = s.writeText(0, 1, "eeeeee", .{});
    (Clear{ .style = .{ .bg = .{ .ansi = 4 } } }).draw(
        Region.init(&s, .{ .x = 1, .y = 1, .width = 3, .height = 1 }),
    );
    try std.testing.expectEqualStrings("e", s.cellAt(0, 1).?.grapheme());
    try std.testing.expectEqualStrings(" ", s.cellAt(1, 1).?.grapheme());
    try std.testing.expectEqual(cell_mod.Color{ .ansi = 4 }, s.cellAt(3, 1).?.style.bg);
    try std.testing.expectEqualStrings("e", s.cellAt(4, 1).?.grapheme());
}
