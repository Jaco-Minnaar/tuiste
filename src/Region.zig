//! A clipped, offset view into a Surface — the canvas widgets draw into.
//! Coordinates are region-relative and every write clips at the region's
//! edges, so code holding a Region cannot escape the rectangle it was given.
//! A cheap value type: carve one up per frame, immediate-mode style.
const Region = @This();

const std = @import("std");
const Surface = @import("Surface.zig");
const Rect = @import("Rect.zig");
const cell_mod = @import("cell.zig");
const Cell = cell_mod.Cell;

surface: *Surface,
/// Surface-absolute bounds; construction clamps it inside the surface.
rect: Rect,

/// The whole surface as one region.
pub fn full(surface: *Surface) Region {
    return .{ .surface = surface, .rect = surface.bounds() };
}

/// A view of `rect` (surface-absolute), clamped to the surface bounds.
pub fn init(surface: *Surface, rect: Rect) Region {
    return .{ .surface = surface, .rect = rect.intersect(surface.bounds()) };
}

/// A nested view: `rect` is relative to this region and clipped by it.
pub fn sub(self: Region, rect: Rect) Region {
    const abs: Rect = .{
        .x = self.rect.x +| rect.x,
        .y = self.rect.y +| rect.y,
        .width = rect.width,
        .height = rect.height,
    };
    return .{ .surface = self.surface, .rect = abs.intersect(self.rect) };
}

/// The region's own extent as a region-relative rect (origin 0,0) — feed
/// it to `layout.split` and hand the pieces to `sub`.
pub fn bounds(self: Region) Rect {
    return .{ .width = self.rect.width, .height = self.rect.height };
}

pub fn width(self: Region) u16 {
    return self.rect.width;
}

pub fn height(self: Region) u16 {
    return self.rect.height;
}

/// `Surface.writeText`, region-relative and clipped to the region.
pub fn writeText(self: Region, x: u16, y: u16, text: []const u8, opts: Surface.Options) u16 {
    if (x >= self.rect.width or y >= self.rect.height) return 0;
    return self.surface.writeTextClipped(
        self.rect,
        self.rect.x + x,
        self.rect.y + y,
        text,
        opts,
    );
}

/// Write one cell at region-relative (x, y); outside the region is a no-op.
pub fn writeCell(self: Region, x: u16, y: u16, c: Cell) void {
    if (x >= self.rect.width or y >= self.rect.height) return;
    self.surface.writeCell(self.rect.x + x, self.rect.y + y, c);
}

/// The cell at region-relative (x, y), or null outside the region.
pub fn cellAt(self: Region, x: u16, y: u16) ?*Cell {
    if (x >= self.rect.width or y >= self.rect.height) return null;
    return self.surface.cellAt(self.rect.x + x, self.rect.y + y);
}

/// Fill every cell of the region.
pub fn fill(self: Region, c: Cell) void {
    var y: u16 = 0;
    while (y < self.rect.height) : (y += 1) {
        const row = (@as(usize, self.rect.y) + y) * self.surface.width + self.rect.x;
        @memset(self.surface.cells[row..][0..self.rect.width], c);
    }
}

// --- tests ------------------------------------------------------------

test "writes are translated and clipped to the region" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 10, 4);
    defer s.deinit(gpa);

    const r = Region.init(&s, .{ .x = 2, .y = 1, .width = 4, .height = 2 });
    try std.testing.expectEqual(@as(u16, 4), r.width());

    // translated: region (0,0) is surface (2,1); clipped at region width 4
    const n = r.writeText(0, 0, "abcdef", .{});
    try std.testing.expectEqual(@as(u16, 4), n);
    try std.testing.expectEqualStrings("a", s.cellAt(2, 1).?.grapheme());
    try std.testing.expectEqualStrings("d", s.cellAt(5, 1).?.grapheme());
    try std.testing.expectEqualStrings(" ", s.cellAt(6, 1).?.grapheme()); // outside stays untouched

    // below the region: no-op
    try std.testing.expectEqual(@as(u16, 0), r.writeText(0, 2, "x", .{}));

    // wide grapheme straddling the region edge is dropped
    const n2 = r.writeText(3, 1, "宽", .{});
    try std.testing.expectEqual(@as(u16, 0), n2);
}

test "sub-regions compose offsets and clip to the parent" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 10, 6);
    defer s.deinit(gpa);

    const outer = Region.init(&s, .{ .x = 1, .y = 1, .width = 8, .height = 4 });
    const inner = outer.sub(.{ .x = 2, .y = 1, .width = 100, .height = 100 });
    // clamped by the parent, not the surface
    try std.testing.expectEqual(@as(u16, 6), inner.width());
    try std.testing.expectEqual(@as(u16, 3), inner.height());

    _ = inner.writeText(0, 0, "x", .{});
    try std.testing.expectEqualStrings("x", s.cellAt(3, 2).?.grapheme());
}

test "region clamps to surface bounds" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 5, 3);
    defer s.deinit(gpa);

    const r = Region.init(&s, .{ .x = 3, .y = 2, .width = 100, .height = 100 });
    try std.testing.expectEqual(@as(u16, 2), r.width());
    try std.testing.expectEqual(@as(u16, 1), r.height());

    const off = Region.init(&s, .{ .x = 50, .y = 50, .width = 4, .height = 4 });
    try std.testing.expect(off.rect.isEmpty());
    _ = off.writeText(0, 0, "x", .{}); // no-op, no crash
}

test "writeCell and cellAt are region-relative" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 6, 3);
    defer s.deinit(gpa);

    const r = Region.init(&s, .{ .x = 1, .y = 1, .width = 3, .height = 2 });
    r.writeCell(2, 1, Cell.init("z", 1, .{}));
    try std.testing.expectEqualStrings("z", s.cellAt(3, 2).?.grapheme());
    try std.testing.expectEqualStrings("z", r.cellAt(2, 1).?.grapheme());
    try std.testing.expectEqual(@as(?*Cell, null), r.cellAt(3, 0));
    r.writeCell(99, 0, .{}); // outside: no-op
}

test "fill covers exactly the region" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 5, 4);
    defer s.deinit(gpa);

    const r = Region.init(&s, .{ .x = 1, .y = 1, .width = 2, .height = 2 });
    r.fill(Cell.init("#", 1, .{}));
    var y: u16 = 0;
    while (y < 4) : (y += 1) {
        var x: u16 = 0;
        while (x < 5) : (x += 1) {
            const expected: []const u8 = if (x >= 1 and x <= 2 and y >= 1 and y <= 2) "#" else " ";
            try std.testing.expectEqualStrings(expected, s.cellAt(x, y).?.grapheme());
        }
    }
}

test "zero-width mark never folds across the region's left edge" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 8, 1);
    defer s.deinit(gpa);

    _ = s.writeText(1, 0, "e", .{}); // glyph just left of the region
    const r = Region.init(&s, .{ .x = 2, .y = 0, .width = 4, .height = 1 });

    // mark at the region's first column: nothing to its left *inside* → dropped
    _ = r.writeText(0, 0, "\u{301}", .{});
    try std.testing.expectEqualStrings("e", s.cellAt(1, 0).?.grapheme());

    // inside the region it folds normally
    _ = r.writeText(0, 0, "a", .{});
    _ = r.writeText(1, 0, "\u{301}", .{});
    try std.testing.expectEqualStrings("a\u{301}", s.graphemeOf(s.cellAt(2, 0).?.*));
}
