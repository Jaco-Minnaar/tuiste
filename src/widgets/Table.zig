//! A multi-column List: a header row, then selectable rows whose column
//! widths come from `layout.split` constraints — the same `len`/`pct`/
//! `min`/`fill` vocabulary as pane layout. Selection and scroll reuse
//! `List.State` verbatim (same clamping, same scroll-follows-selection),
//! so `selectNext`/`selectPrev` and mouse hit math carry over unchanged.
const Table = @This();

const std = @import("std");
const Region = @import("../Region.zig");
const Surface = @import("../Surface.zig");
const cell_mod = @import("../cell.zig");
const Cell = cell_mod.Cell;
const layout = @import("../layout.zig");
const Rect = @import("../Rect.zig");

pub const State = @import("List.zig").State;

pub const max_columns = 16;

pub const Column = struct {
    header: []const u8 = "",
    width: layout.Constraint = .{ .fill = 1 },
};

/// At most `max_columns`; extras are ignored.
columns: []const Column = &.{},
/// One slice of cell texts per row; short rows leave their tail columns
/// blank, extra cells are ignored. Cells clip at their column edge.
rows: []const []const []const u8 = &.{},
opts: Surface.Options = .{},
header_opts: Surface.Options = .{ .attrs = .{ .bold = true } },
selected_opts: Surface.Options = .{ .attrs = .{ .reverse = true } },
/// Blank cells kept clear at the right of every column but the last.
gap: u16 = 1,

/// Rows of the region consumed by the header (for mouse hit math:
/// `row_index = state.offset + m.row - inner.rect.y - header_height`).
pub const header_height: u16 = 1;

pub fn draw(self: Table, region: Region, state: *State) void {
    const w = region.width();
    const h = region.height();
    if (w == 0 or h == 0) return;

    // Column geometry from the layout constraints.
    const ncols = @min(self.columns.len, max_columns);
    var constraints: [max_columns]layout.Constraint = undefined;
    for (self.columns[0..ncols], 0..) |col, i| constraints[i] = col.width;
    var col_rects: [max_columns]Rect = undefined;
    const cols = layout.split(
        .{ .width = w, .height = 1 },
        .horizontal,
        constraints[0..ncols],
        &col_rects,
    );

    for (cols, 0..) |c, i| {
        const strip = self.columnStrip(region, c, i, 0);
        _ = strip.writeText(0, 0, self.columns[i].header, self.header_opts);
    }

    if (h <= header_height) return;
    const view: usize = h - header_height;
    const len = self.rows.len;
    if (len == 0) {
        state.selected = null;
        state.offset = 0;
        return;
    }

    // Same state hygiene as List, over the body viewport.
    if (state.selected) |sel| {
        const s = @min(sel, len - 1);
        state.selected = s;
        if (s < state.offset) state.offset = s;
        if (s >= state.offset + view) state.offset = s - view + 1;
    }
    state.offset = @min(state.offset, len -| view);

    var row: u16 = 0;
    while (row < view and state.offset + row < len) : (row += 1) {
        const i = state.offset + row;
        const y = header_height + row;
        const is_selected = if (state.selected) |s| s == i else false;
        const o = if (is_selected) self.selected_opts else self.opts;
        if (is_selected) {
            var bg: Cell = .{};
            bg.style = .{ .fg = o.fg, .bg = o.bg, .attrs = o.attrs };
            region.sub(.{ .y = y, .width = w, .height = 1 }).fill(bg);
        }
        const cells = self.rows[i];
        for (cols, 0..) |c, ci| {
            if (ci >= cells.len) break;
            const strip = self.columnStrip(region, c, ci, y);
            _ = strip.writeText(0, 0, cells[ci], o);
        }
    }
}

/// The row at region-relative `row`, or null on the header or past the
/// data — feed it `m.row - region.rect.y` on mouse press.
pub fn hitTest(self: Table, state: State, row: u16) ?usize {
    if (row < header_height) return null;
    const i = state.offset + (row - header_height);
    if (i >= self.rows.len) return null;
    return i;
}

/// A one-row region for column `i` at row `y`, with the gap shaved off
/// every column but the last so neighbors can't run together.
fn columnStrip(self: Table, region: Region, c: Rect, i: usize, y: u16) Region {
    const trailing_gap = if (i + 1 < self.columns.len) @min(self.gap, c.width) else 0;
    return region.sub(.{ .x = c.x, .y = y, .width = c.width - trailing_gap, .height = 1 });
}

// --- tests ------------------------------------------------------------

const test_columns = [_]Column{
    .{ .header = "id", .width = .{ .len = 3 } },
    .{ .header = "naam", .width = .{ .fill = 1 } },
    .{ .header = "status", .width = .{ .len = 6 } },
};
const test_rows = [_][]const []const u8{
    &.{ "1", "bobotie", "reg" },
    &.{ "2", "melktert", "wag" },
    &.{ "3", "koeksisters", "reg" },
    &.{ "4", "potjiekos", "prut" },
};

test "header, column split, and cell clipping" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 16, 4);
    defer s.deinit(gpa);

    var state: State = .{};
    (Table{ .columns = &test_columns, .rows = &test_rows }).draw(Region.full(&s), &state);

    // header row, bold
    try std.testing.expectEqualStrings("i", s.cellAt(0, 0).?.grapheme());
    try std.testing.expect(s.cellAt(0, 0).?.style.attrs.bold);
    try std.testing.expectEqualStrings("n", s.cellAt(3, 0).?.grapheme()); // fill col starts after len 3
    try std.testing.expectEqualStrings("s", s.cellAt(10, 0).?.grapheme()); // status col: 16-3-6

    // body: fill column is 7 wide minus 1 gap → "koeksisters" clips to "koeksi"
    try std.testing.expectEqualStrings("1", s.cellAt(0, 1).?.grapheme());
    try std.testing.expectEqualStrings("b", s.cellAt(3, 1).?.grapheme());
    try std.testing.expectEqualStrings("i", s.cellAt(8, 3).?.grapheme()); // koeksi|
    try std.testing.expectEqualStrings(" ", s.cellAt(9, 3).?.grapheme()); // gap stays clear
    try std.testing.expectEqualStrings("r", s.cellAt(10, 1).?.grapheme()); // status cell
}

test "selection highlights the full row and scroll follows" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 16, 3); // header + 2 body rows
    defer s.deinit(gpa);
    const t: Table = .{ .columns = &test_columns, .rows = &test_rows };

    var state: State = .{ .selected = 3 };
    t.draw(Region.full(&s), &state);
    // selection out of view scrolled the body window to rows 2..3
    try std.testing.expectEqual(@as(usize, 2), state.offset);
    try std.testing.expectEqualStrings("4", s.cellAt(0, 2).?.grapheme());
    try std.testing.expect(s.cellAt(15, 2).?.style.attrs.reverse); // full-width highlight
    try std.testing.expect(!s.cellAt(0, 1).?.style.attrs.reverse);
    // header untouched by scrolling
    try std.testing.expectEqualStrings("i", s.cellAt(0, 0).?.grapheme());

    // shrunk row set clamps state, like List
    var stale: State = .{ .selected = 99, .offset = 99 };
    t.draw(Region.full(&s), &stale);
    try std.testing.expectEqual(@as(?usize, 3), stale.selected);
}

test "hitTest skips the header" {
    const t: Table = .{ .columns = &test_columns, .rows = &test_rows };
    const state: State = .{ .offset = 1 };
    try std.testing.expectEqual(@as(?usize, null), t.hitTest(state, 0)); // header row
    try std.testing.expectEqual(@as(?usize, 1), t.hitTest(state, 1));
    try std.testing.expectEqual(@as(?usize, 3), t.hitTest(state, 3));
    try std.testing.expectEqual(@as(?usize, null), t.hitTest(state, 4)); // past the data
}

test "degenerate shapes" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 16, 1); // header only, no body space
    defer s.deinit(gpa);

    var state: State = .{ .selected = 1 };
    (Table{ .columns = &test_columns, .rows = &test_rows }).draw(Region.full(&s), &state);
    try std.testing.expectEqualStrings("i", s.cellAt(0, 0).?.grapheme());

    var s2 = try Surface.init(gpa, 16, 2);
    defer s2.deinit(gpa);

    // no rows: state resets (needs body space to reach the row logic)
    var st2: State = .{ .selected = 2, .offset = 1 };
    (Table{ .columns = &test_columns }).draw(Region.full(&s2), &st2);
    try std.testing.expectEqual(@as(?usize, null), st2.selected);

    // short row leaves its tail columns blank (row 2 has one cell)
    s2.clear();
    var st3: State = .{};
    const short_rows = [_][]const []const u8{&.{"x"}};
    (Table{ .columns = &test_columns, .rows = &short_rows }).draw(Region.full(&s2), &st3);
    try std.testing.expectEqualStrings("x", s2.cellAt(0, 1).?.grapheme());
    try std.testing.expectEqualStrings(" ", s2.cellAt(3, 1).?.grapheme());
}
