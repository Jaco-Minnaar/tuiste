//! A 2D grid of cells that user code draws into each frame.
//! All writes are clipped to the surface bounds — drawing off-screen is a no-op.
const Surface = @This();

const std = @import("std");
const cell_mod = @import("cell.zig");
const Cell = cell_mod.Cell;
const Style = cell_mod.Style;
const unicode = @import("unicode.zig");

width: u16,
height: u16,
cells: []Cell,

pub fn init(gpa: std.mem.Allocator, width: u16, height: u16) std.mem.Allocator.Error!Surface {
    const cells = try gpa.alloc(Cell, @as(usize, width) * height);
    @memset(cells, .{});
    return .{ .width = width, .height = height, .cells = cells };
}

pub fn deinit(self: *Surface, gpa: std.mem.Allocator) void {
    gpa.free(self.cells);
    self.* = undefined;
}

pub fn resize(self: *Surface, gpa: std.mem.Allocator, width: u16, height: u16) std.mem.Allocator.Error!void {
    const new_cells = try gpa.realloc(self.cells, @as(usize, width) * height);
    self.cells = new_cells;
    self.width = width;
    self.height = height;
    self.clear();
}

/// Reset every cell to the default (styled space).
pub fn clear(self: *Surface) void {
    @memset(self.cells, .{});
}

pub fn fill(self: *Surface, c: Cell) void {
    @memset(self.cells, c);
}

pub fn cellAt(self: *const Surface, x: u16, y: u16) ?*Cell {
    if (x >= self.width or y >= self.height) return null;
    return &self.cells[@as(usize, y) * self.width + x];
}

pub fn writeCell(self: *Surface, x: u16, y: u16, c: Cell) void {
    const dst = self.cellAt(x, y) orelse return;
    dst.* = c;
}

/// Write UTF-8 text starting at (x, y), grapheme- and width-aware.
/// Wide graphemes take two cells (the second becomes a spacer). Text is
/// clipped at the right edge; a wide grapheme that would straddle it is
/// dropped. Returns the number of columns written.
pub fn writeText(self: *Surface, x: u16, y: u16, text: []const u8, style: Style) u16 {
    if (y >= self.height) return 0;
    var col: u16 = x;
    var iter = unicode.graphemeIterator(text);
    while (iter.next()) |g| {
        const bytes = g.bytes(text);
        const w = unicode.graphemeWidth(bytes);
        if (w == 0) continue; // TODO: fold zero-width marks into the previous cell
        if (@as(u32, col) + w > self.width) break;
        self.writeCell(col, y, Cell.init(bytes, w, style));
        if (w == 2) {
            var sp = Cell.spacer;
            sp.style = style;
            self.writeCell(col + 1, y, sp);
        }
        col += w;
    }
    return col -| x;
}

test "writeText basic" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 10, 3);
    defer s.deinit(gpa);

    const n = s.writeText(1, 0, "hi", .{});
    try std.testing.expectEqual(@as(u16, 2), n);
    try std.testing.expectEqualStrings("h", s.cellAt(1, 0).?.grapheme());
    try std.testing.expectEqualStrings("i", s.cellAt(2, 0).?.grapheme());
    // untouched neighbors stay default
    try std.testing.expectEqualStrings(" ", s.cellAt(0, 0).?.grapheme());
}

test "writeText wide grapheme leaves a spacer" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 10, 1);
    defer s.deinit(gpa);

    const n = s.writeText(0, 0, "宽x", .{});
    try std.testing.expectEqual(@as(u16, 3), n);
    try std.testing.expectEqual(@as(u2, 2), s.cellAt(0, 0).?.width);
    try std.testing.expectEqual(@as(u2, 0), s.cellAt(1, 0).?.width);
    try std.testing.expectEqualStrings("x", s.cellAt(2, 0).?.grapheme());
}

test "writeText clips at the right edge" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 4, 1);
    defer s.deinit(gpa);

    const n = s.writeText(2, 0, "ab宽", .{});
    // "ab" fits (cols 2,3); wide grapheme would straddle the edge → dropped
    try std.testing.expectEqual(@as(u16, 2), n);
}

test "writes outside bounds are no-ops" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 4, 2);
    defer s.deinit(gpa);

    s.writeCell(99, 0, .{});
    try std.testing.expectEqual(@as(u16, 0), s.writeText(0, 99, "nope", .{}));
}
