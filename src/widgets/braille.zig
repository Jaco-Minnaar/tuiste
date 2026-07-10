//! Braille dot plotting: each cell is a 2×4 dot grid (U+2800 + an 8-bit
//! mask), giving a Region double horizontal and quadruple vertical
//! resolution. Dots merge with braille already in the target cell — read
//! the glyph, OR the bit, write it back — so datasets, and even separate
//! widgets, compose without any scratch buffer; the Surface is the
//! accumulator. Any non-braille glyph in the cell is replaced.
const std = @import("std");
const Region = @import("../Region.zig");
const cell_mod = @import("../cell.zig");
const Cell = cell_mod.Cell;
const Style = cell_mod.Style;

/// Dot-space dimensions of a region.
pub fn dotWidth(region: Region) u32 {
    return @as(u32, region.width()) * 2;
}

pub fn dotHeight(region: Region) u32 {
    return @as(u32, region.height()) * 4;
}

/// Unicode braille dot bits by (column, row) within the cell:
/// dots 1-2-3-7 down the left, 4-5-6-8 down the right.
const dot_masks = [2][4]u8{
    .{ 0x01, 0x02, 0x04, 0x40 },
    .{ 0x08, 0x10, 0x20, 0x80 },
};

/// Set the dot at dot-space (x, y); outside the region is a no-op. The
/// style applies to the whole cell (last write wins where datasets share
/// a cell).
pub fn dot(region: Region, x: u32, y: u32, style: Style) void {
    if (x >= dotWidth(region) or y >= dotHeight(region)) return;
    const cx: u16 = @intCast(x / 2);
    const cy: u16 = @intCast(y / 4);
    var mask: u8 = dot_masks[@intCast(x % 2)][@intCast(y % 4)];

    if (region.cellAt(cx, cy)) |cell| {
        const g = cell.grapheme();
        if (g.len == 3) {
            const cp = std.unicode.utf8Decode(g) catch 0;
            if (cp >= 0x2800 and cp <= 0x28FF) mask |= @as(u8, @intCast(cp & 0xFF));
        }
    }

    var enc: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(0x2800 + @as(u21, mask), &enc) catch unreachable;
    region.writeCell(cx, cy, Cell.init(enc[0..n], 1, style));
}

/// Bresenham line in dot space, both endpoints included. Endpoints may
/// lie outside the region; each dot clips individually.
pub fn line(region: Region, x0: u32, y0: u32, x1: u32, y1: u32, style: Style) void {
    var x: i64 = x0;
    var y: i64 = y0;
    const xe: i64 = x1;
    const ye: i64 = y1;
    const dx: i64 = @intCast(@abs(xe - x));
    const dy: i64 = -@as(i64, @intCast(@abs(ye - y)));
    const sx: i64 = if (x < xe) 1 else -1;
    const sy: i64 = if (y < ye) 1 else -1;
    var err = dx + dy;
    while (true) {
        dot(region, @intCast(x), @intCast(y), style);
        if (x == xe and y == ye) break;
        const e2 = 2 * err;
        if (e2 >= dy) {
            err += dy;
            x += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y += sy;
        }
    }
}

// --- tests ------------------------------------------------------------

const Surface = @import("../Surface.zig");

test "dots set the right bits and merge within a cell" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 4, 2);
    defer s.deinit(gpa);
    const r = Region.full(&s);

    dot(r, 0, 0, .{}); // dot 1
    try std.testing.expectEqualStrings("⠁", s.cellAt(0, 0).?.grapheme());
    dot(r, 1, 3, .{}); // dot 8, same cell → merged
    try std.testing.expectEqualStrings("⢁", s.cellAt(0, 0).?.grapheme());
    dot(r, 2, 4, .{}); // next cell across and down
    try std.testing.expectEqualStrings("⠁", s.cellAt(1, 1).?.grapheme());

    // a non-braille glyph is replaced, not merged
    _ = s.writeText(2, 0, "x", .{});
    dot(r, 4, 1, .{});
    try std.testing.expectEqualStrings("⠂", s.cellAt(2, 0).?.grapheme());

    // outside dot space: no-op, no crash
    dot(r, 99, 0, .{});
    dot(r, 0, 99, .{});
}

test "dot styles the cell" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 2, 1);
    defer s.deinit(gpa);

    dot(Region.full(&s), 0, 0, .{ .fg = .{ .ansi = 2 } });
    try std.testing.expectEqual(cell_mod.Color{ .ansi = 2 }, s.cellAt(0, 0).?.style.fg);
}

test "line covers both endpoints and is connected" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 5, 2);
    defer s.deinit(gpa);
    const r = Region.full(&s);

    line(r, 0, 7, 9, 0, .{}); // diagonal across the whole dot space
    // endpoints landed
    try std.testing.expect(s.cellAt(0, 1).?.grapheme()[0] == 0xE2); // braille lead byte
    try std.testing.expect(s.cellAt(4, 0).?.grapheme()[0] == 0xE2);
    // every cell column along the way got at least one dot
    var x: u16 = 0;
    while (x < 5) : (x += 1) {
        const g0 = s.cellAt(x, 0).?.grapheme();
        const g1 = s.cellAt(x, 1).?.grapheme();
        try std.testing.expect(g0[0] == 0xE2 or g1[0] == 0xE2);
    }
}
