//! A 2D grid of cells that user code draws into each frame.
//! All writes are clipped to the surface bounds — drawing off-screen is a no-op.
const Surface = @This();

const std = @import("std");
const cell_mod = @import("cell.zig");
const Cell = cell_mod.Cell;
const Style = cell_mod.Style;
const unicode = @import("unicode.zig");
const GraphemePool = @import("GraphemePool.zig");

width: u16,
height: u16,
cells: []Cell,
/// Where graphemes too long for a Cell's inline buffer get interned.
/// Without one (standalone surfaces) they degrade to U+FFFD. The Renderer
/// points both of its surfaces at the same pool.
pool: ?*GraphemePool = null,

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
        if (w == 0) {
            // A zero-width cluster of its own (bare combining mark, ZWSP…):
            // compose it onto the glyph to the left of the write position.
            self.foldZeroWidth(col, y, bytes);
            continue;
        }
        if (@as(u32, col) + w > self.width) break;
        self.writeCell(col, y, self.makeCell(bytes, w, style));
        if (w == 2) {
            var sp = Cell.spacer;
            sp.style = style;
            self.writeCell(col + 1, y, sp);
        }
        col += w;
    }
    return col -| x;
}

/// Cap on a composed grapheme (base + folded marks). Past this we drop
/// further marks — a bound against pathological mark stacking (Zalgo text).
const max_fold_bytes = 128;

/// Append a zero-width mark's bytes to the glyph cell left of `col`,
/// stepping over a wide glyph's spacer. Degradation always keeps the base
/// glyph: at worst the mark is dropped (no cell to the left, spacer-only,
/// fold cap hit, or pool unavailable for an overflowing combination).
fn foldZeroWidth(self: *Surface, col: u16, y: u16, mark: []const u8) void {
    if (col == 0) return;
    var cx = col - 1;
    var target = self.cellAt(cx, y) orelse return;
    if (target.width == 0 and cx > 0) { // spacer: the glyph is one further left
        cx -= 1;
        target = self.cellAt(cx, y) orelse return;
    }
    if (target.width == 0) return;

    var buf: [max_fold_bytes]u8 = undefined;
    const base = self.graphemeOf(target.*);
    if (base.len + mark.len > buf.len) return;
    @memcpy(buf[0..base.len], base);
    @memcpy(buf[base.len..][0..mark.len], mark);
    const combined = buf[0 .. base.len + mark.len];

    if (combined.len <= Cell.max_grapheme_bytes) {
        target.* = Cell.init(combined, target.width, target.style);
    } else if (self.pool) |pool| {
        if (pool.intern(combined)) |idx| {
            target.* = Cell.initPooled(idx, target.width, target.style);
        }
    }
}

/// Build a cell for one grapheme, interning through the pool when it
/// doesn't fit inline. Degrades to U+FFFD without a pool (or on OOM) so
/// the draw path never fails.
fn makeCell(self: *Surface, bytes: []const u8, width: u2, style: Style) Cell {
    if (bytes.len > Cell.max_grapheme_bytes) {
        if (self.pool) |pool| {
            if (pool.intern(bytes)) |idx| return Cell.initPooled(idx, width, style);
        }
    }
    return Cell.init(bytes, width, style);
}

/// Resolve a cell's grapheme, following the pool for overflowed cells.
pub fn graphemeOf(self: *const Surface, c: Cell) []const u8 {
    if (c.poolIndex()) |idx| {
        if (self.pool) |pool| return pool.get(idx);
    }
    return c.grapheme();
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

test "writeText interns oversized graphemes through the pool" {
    const gpa = std.testing.allocator;
    var pool = GraphemePool.init(gpa);
    defer pool.deinit();
    var s = try Surface.init(gpa, 10, 1);
    defer s.deinit(gpa);
    s.pool = &pool;

    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}";
    const n = s.writeText(0, 0, family, .{});
    try std.testing.expectEqual(@as(u16, 2), n);
    const c = s.cellAt(0, 0).?.*;
    try std.testing.expect(c.poolIndex() != null);
    try std.testing.expectEqualStrings(family, s.graphemeOf(c));
    // second write of the same grapheme produces an equal cell (same index)
    var s2 = try Surface.init(gpa, 10, 1);
    defer s2.deinit(gpa);
    s2.pool = &pool;
    _ = s2.writeText(0, 0, family, .{});
    try std.testing.expect(c.eql(s2.cellAt(0, 0).?.*));
}

test "writeText without a pool degrades to replacement char" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 10, 1);
    defer s.deinit(gpa);

    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}";
    _ = s.writeText(0, 0, family, .{});
    try std.testing.expectEqualStrings("\u{FFFD}", s.graphemeOf(s.cellAt(0, 0).?.*));
}

test "zero-width mark folds into the previous cell across calls" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 10, 1);
    defer s.deinit(gpa);

    _ = s.writeText(0, 0, "e", .{});
    const n = s.writeText(1, 0, "\u{301}x", .{}); // bare acute, then 'x'
    try std.testing.expectEqualStrings("e\u{301}", s.graphemeOf(s.cellAt(0, 0).?.*));
    try std.testing.expectEqualStrings("x", s.cellAt(1, 0).?.grapheme());
    try std.testing.expectEqual(@as(u16, 1), n); // mark took no column
}

test "zero-width cluster mid-string folds left" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 10, 1);
    defer s.deinit(gpa);

    const n = s.writeText(0, 0, "a\u{200B}b", .{}); // ZWSP is its own cluster
    try std.testing.expectEqual(@as(u16, 2), n);
    try std.testing.expectEqualStrings("a\u{200B}", s.graphemeOf(s.cellAt(0, 0).?.*));
    try std.testing.expectEqualStrings("b", s.cellAt(1, 0).?.grapheme());
}

test "zero-width mark skips a wide glyph's spacer" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 10, 1);
    defer s.deinit(gpa);

    _ = s.writeText(0, 0, "宽", .{});
    _ = s.writeText(2, 0, "\u{301}", .{});
    try std.testing.expectEqualStrings("宽\u{301}", s.graphemeOf(s.cellAt(0, 0).?.*));
    try std.testing.expectEqual(@as(u2, 0), s.cellAt(1, 0).?.width); // spacer intact
}

test "fold overflowing inline capacity re-interns through the pool" {
    const gpa = std.testing.allocator;
    var pool = GraphemePool.init(gpa);
    defer pool.deinit();
    var s = try Surface.init(gpa, 10, 1);
    defer s.deinit(gpa);
    s.pool = &pool;

    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}";
    _ = s.writeText(0, 0, family, .{});
    _ = s.writeText(2, 0, "\u{301}", .{});
    try std.testing.expectEqualStrings(family ++ "\u{301}", s.graphemeOf(s.cellAt(0, 0).?.*));
}

test "fold degradation keeps the base glyph" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 10, 1);
    defer s.deinit(gpa);

    // 14-byte single cluster; +2-byte mark would need the (absent) pool.
    const flag = "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}";
    _ = s.writeText(0, 0, flag, .{});
    _ = s.writeText(2, 0, "\u{301}", .{});
    try std.testing.expectEqualStrings(flag, s.graphemeOf(s.cellAt(0, 0).?.*));

    // A mark with nothing to its left is dropped, not a crash.
    _ = s.writeText(0, 0, "\u{301}", .{});
}

test "writes outside bounds are no-ops" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 4, 2);
    defer s.deinit(gpa);

    s.writeCell(99, 0, .{});
    try std.testing.expectEqual(@as(u16, 0), s.writeText(0, 99, "nope", .{}));
}
