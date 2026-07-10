//! Rect splitting for immediate-mode layout: carve a rect into rows or
//! columns from a constraint list, into caller-provided storage. Fixed
//! requests (`len`, `pct`, `min`) resolve first; leftover space goes to the
//! `fill`s proportionally by weight, or — with no fills — grows the `min`s
//! equally. Over-constrained input truncates from the tail. Deterministic
//! and allocation-free; there is deliberately no solver here.
const std = @import("std");
const Rect = @import("Rect.zig");

pub const Direction = enum { horizontal, vertical };

pub const Constraint = union(enum) {
    /// Exactly this many cells.
    len: u16,
    /// This percentage of the whole axis (values above 100 clamp).
    pct: u8,
    /// At least this many cells; grows when leftover space has no `fill`
    /// to go to.
    min: u16,
    /// A share of whatever the fixed constraints leave over, proportional
    /// to this weight (0 counts as 1, so `.fill = 0` isn't a trap).
    fill: u16,
};

/// Split `rect` along `dir` into one piece per constraint, written to
/// `out` (which must hold at least `constraints.len` rects). Pieces tile
/// the rect in order from the top/left; if the constraints don't claim the
/// whole axis, the gap is left at the tail. Returns the filled slice.
pub fn split(rect: Rect, dir: Direction, constraints: []const Constraint, out: []Rect) []Rect {
    std.debug.assert(out.len >= constraints.len);
    const total: u16 = switch (dir) {
        .horizontal => rect.width,
        .vertical => rect.height,
    };

    // Base sizes, parked in out[i].width until positioning.
    var used: u32 = 0;
    var fill_weight: u32 = 0;
    var min_count: u32 = 0;
    for (constraints, 0..) |c, i| {
        const base: u16 = switch (c) {
            .len => |n| n,
            .pct => |p| @intCast(@as(u32, total) * @min(p, 100) / 100),
            .min => |n| n,
            .fill => 0,
        };
        out[i] = .{ .width = base };
        used += base;
        switch (c) {
            .fill => |w| fill_weight += @max(w, 1),
            .min => min_count += 1,
            else => {},
        }
    }

    // Hand out the leftover.
    if (used < total) {
        const leftover: u32 = total - used;
        if (fill_weight > 0) {
            // Exact by construction: piece i gets the difference between
            // successive cumulative targets, so the shares always sum to
            // `leftover` with no rounding drift.
            var acc: u32 = 0;
            var given: u32 = 0;
            for (constraints, 0..) |c, i| switch (c) {
                .fill => |w| {
                    acc += @max(w, 1);
                    const target = leftover * acc / fill_weight;
                    out[i].width += @intCast(target - given);
                    given = target;
                },
                else => {},
            };
        } else if (min_count > 0) {
            var nth: u32 = 0;
            for (constraints, 0..) |c, i| switch (c) {
                .min => {
                    const extra: u32 = if (nth < leftover % min_count) 1 else 0;
                    out[i].width += @intCast(leftover / min_count + extra);
                    nth += 1;
                },
                else => {},
            };
        }
    }

    // Positions, clamped so the tail truncates when over-constrained.
    var pos: u32 = 0;
    for (constraints, 0..) |_, i| {
        const size: u16 = @intCast(@min(out[i].width, total - @min(pos, total)));
        out[i] = switch (dir) {
            .horizontal => .{
                .x = rect.x + @as(u16, @intCast(pos)),
                .y = rect.y,
                .width = size,
                .height = rect.height,
            },
            .vertical => .{
                .x = rect.x,
                .y = rect.y + @as(u16, @intCast(pos)),
                .width = rect.width,
                .height = size,
            },
        };
        pos += size;
    }
    return out[0..constraints.len];
}

// --- tests ------------------------------------------------------------

const expectEqual = std.testing.expectEqual;

test "vertical split tiles in order" {
    var out: [3]Rect = undefined;
    const rows = split(
        .{ .x = 1, .y = 2, .width = 10, .height = 12 },
        .vertical,
        &.{ .{ .len = 3 }, .{ .fill = 1 }, .{ .len = 1 } },
        &out,
    );
    try expectEqual(Rect{ .x = 1, .y = 2, .width = 10, .height = 3 }, rows[0]);
    try expectEqual(Rect{ .x = 1, .y = 5, .width = 10, .height = 8 }, rows[1]);
    try expectEqual(Rect{ .x = 1, .y = 13, .width = 10, .height = 1 }, rows[2]);
}

test "horizontal split with percentages" {
    var out: [2]Rect = undefined;
    const cols = split(
        .{ .width = 10, .height = 4 },
        .horizontal,
        &.{ .{ .pct = 25 }, .{ .fill = 1 } },
        &out,
    );
    try expectEqual(@as(u16, 2), cols[0].width); // floor(10 * 25%)
    try expectEqual(@as(u16, 8), cols[1].width);
    try expectEqual(@as(u16, 2), cols[1].x);
    try expectEqual(@as(u16, 4), cols[1].height);
}

test "fill weights share leftover exactly" {
    var out: [3]Rect = undefined;
    const cols = split(
        .{ .width = 11, .height = 1 },
        .horizontal,
        &.{ .{ .len = 1 }, .{ .fill = 1 }, .{ .fill = 2 } },
        &out,
    );
    // 10 leftover at weights 1:2 → 3 + 7 (cumulative rounding, sums exactly)
    try expectEqual(@as(u16, 3), cols[1].width);
    try expectEqual(@as(u16, 7), cols[2].width);
    try expectEqual(@as(u16, 11), cols[0].width + cols[1].width + cols[2].width);
}

test "min grows when nothing fills" {
    var out: [3]Rect = undefined;
    const rows = split(
        .{ .width = 5, .height = 12 },
        .vertical,
        &.{ .{ .min = 2 }, .{ .len = 1 }, .{ .min = 2 } },
        &out,
    );
    // 7 leftover over two mins → 4 and 3 (remainder to the first)
    try expectEqual(@as(u16, 6), rows[0].height);
    try expectEqual(@as(u16, 5), rows[2].height);

    // with a fill present, mins stay at their minimum
    const rows2 = split(
        .{ .width = 5, .height = 12 },
        .vertical,
        &.{ .{ .min = 2 }, .{ .fill = 1 } },
        &out,
    );
    try expectEqual(@as(u16, 2), rows2[0].height);
    try expectEqual(@as(u16, 10), rows2[1].height);
}

test "over-constrained input truncates from the tail" {
    var out: [3]Rect = undefined;
    const rows = split(
        .{ .width = 5, .height = 6 },
        .vertical,
        &.{ .{ .len = 4 }, .{ .len = 4 }, .{ .len = 4 } },
        &out,
    );
    try expectEqual(@as(u16, 4), rows[0].height);
    try expectEqual(@as(u16, 2), rows[1].height);
    try expectEqual(@as(u16, 0), rows[2].height);
    // the empty piece still sits at a sane position
    try expectEqual(@as(u16, 6), rows[2].y);
}

test "under-constrained input leaves the gap at the tail" {
    var out: [1]Rect = undefined;
    const rows = split(.{ .width = 5, .height = 9 }, .vertical, &.{.{ .len = 2 }}, &out);
    try expectEqual(@as(u16, 2), rows[0].height);
}

test "empty constraint list" {
    var out: [1]Rect = undefined;
    const none = split(.{ .width = 5, .height = 5 }, .vertical, &.{}, &out);
    try expectEqual(@as(usize, 0), none.len);
}
