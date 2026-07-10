//! A compact column-per-value chart filled from the bottom, using the
//! region's full height — the shape of btop's CPU graphs (a rolling area
//! graph, one column per time sample). Two renderings: eighth-height
//! blocks (▁▂▃▄▅▆▇█ — h rows give h×8 levels, one value per cell column)
//! or braille dots (two values per cell column, h×4 levels, the denser
//! btop-style texture). With more values than columns the tail is shown,
//! so feeding it a rolling history keeps the latest data visible. For
//! labeled axes or lines, use Chart.
const Sparkline = @This();

const std = @import("std");
const Region = @import("../Region.zig");
const Surface = @import("../Surface.zig");
const cell_mod = @import("../cell.zig");
const Style = cell_mod.Style;
const braille = @import("braille.zig");

values: []const f64 = &.{},
/// Fixed (min, max) mapping, or null to auto-range 0 → max(values).
/// Values outside the range clamp to the ends.
range: ?[2]f64 = null,
style: Style = .{},
marker: Marker = .block,

pub const Marker = enum { block, braille };

const eighths = [_][]const u8{ "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };

pub fn draw(self: Sparkline, region: Region) void {
    const w = region.width();
    const h = region.height();
    if (w == 0 or h == 0 or self.values.len == 0) return;

    const cols: usize = switch (self.marker) {
        .block => w,
        .braille => braille.dotWidth(region),
    };
    const n = @min(self.values.len, cols);
    const vals = self.values[self.values.len - n ..];

    var lo: f64 = 0;
    var hi: f64 = 0;
    if (self.range) |r| {
        lo = r[0];
        hi = r[1];
    } else {
        for (self.values) |v| hi = @max(hi, v);
    }
    if (!(hi > lo)) return;

    switch (self.marker) {
        .block => {
            const opts: Surface.Options = .{
                .fg = self.style.fg,
                .bg = self.style.bg,
                .attrs = self.style.attrs,
            };
            const max_e = @as(f64, @floatFromInt(@as(u32, h) * 8));
            for (vals, 0..) |v, i| {
                const t = std.math.clamp((v - lo) / (hi - lo), 0, 1);
                const e: u32 = @intFromFloat(@round(t * max_e));
                const x: u16 = @intCast(i);
                var r: u16 = 0;
                while (r < e / 8) : (r += 1) _ = region.writeText(x, h - 1 - r, "█", opts);
                if (e % 8 > 0) _ = region.writeText(x, h - 1 - @as(u16, @intCast(e / 8)), eighths[e % 8 - 1], opts);
            }
        },
        .braille => {
            const dh = braille.dotHeight(region);
            for (vals, 0..) |v, i| {
                const t = std.math.clamp((v - lo) / (hi - lo), 0, 1);
                const k: u32 = @intFromFloat(@round(t * @as(f64, @floatFromInt(dh))));
                var d: u32 = 0;
                while (d < k) : (d += 1) {
                    braille.dot(region, @intCast(i), dh - 1 - d, self.style);
                }
            }
        },
    }
}

// --- tests ------------------------------------------------------------

test "single row maps values to eighth blocks" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 6, 1);
    defer s.deinit(gpa);

    (Sparkline{ .values = &.{ 8, 4, 1, 0, 6 } }).draw(Region.full(&s));
    try std.testing.expectEqualStrings("█", s.cellAt(0, 0).?.grapheme()); // max
    try std.testing.expectEqualStrings("▄", s.cellAt(1, 0).?.grapheme()); // half
    try std.testing.expectEqualStrings("▁", s.cellAt(2, 0).?.grapheme());
    try std.testing.expectEqualStrings(" ", s.cellAt(3, 0).?.grapheme()); // zero: blank
    try std.testing.expectEqualStrings("▆", s.cellAt(4, 0).?.grapheme());
    try std.testing.expectEqualStrings(" ", s.cellAt(5, 0).?.grapheme()); // no value
}

test "multiple rows stack full blocks under the partial" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 3, 2);
    defer s.deinit(gpa);

    (Sparkline{ .values = &.{ 1.0, 0.5, 0.75 }, .range = .{ 0, 1 } }).draw(Region.full(&s));
    // 1.0 → both rows full
    try std.testing.expectEqualStrings("█", s.cellAt(0, 0).?.grapheme());
    try std.testing.expectEqualStrings("█", s.cellAt(0, 1).?.grapheme());
    // 0.5 → bottom row full, top empty
    try std.testing.expectEqualStrings(" ", s.cellAt(1, 0).?.grapheme());
    try std.testing.expectEqualStrings("█", s.cellAt(1, 1).?.grapheme());
    // 0.75 → bottom full, top half
    try std.testing.expectEqualStrings("▄", s.cellAt(2, 0).?.grapheme());
    try std.testing.expectEqualStrings("█", s.cellAt(2, 1).?.grapheme());
}

test "fixed range clamps and the tail wins" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 3, 1);
    defer s.deinit(gpa);

    // 5 values into 3 columns: only the last 3 are drawn; 9 clamps to max
    (Sparkline{
        .values = &.{ 2, 2, 4, 9, -3 },
        .range = .{ 0, 8 },
    }).draw(Region.full(&s));
    try std.testing.expectEqualStrings("▄", s.cellAt(0, 0).?.grapheme());
    try std.testing.expectEqualStrings("█", s.cellAt(1, 0).?.grapheme());
    try std.testing.expectEqualStrings(" ", s.cellAt(2, 0).?.grapheme()); // clamped to lo

    // degenerate: empty values, all-zero auto range
    s.clear();
    (Sparkline{}).draw(Region.full(&s));
    (Sparkline{ .values = &.{ 0, 0 } }).draw(Region.full(&s));
    try std.testing.expectEqualStrings(" ", s.cellAt(0, 0).?.grapheme());
}

test "braille marker packs two filled columns per cell" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 2, 1);
    defer s.deinit(gpa);

    // one row = 4 dot levels; samples fill dot columns bottom-up
    (Sparkline{
        .values = &.{ 1.0, 0.5, 0.25, 0 },
        .range = .{ 0, 1 },
        .marker = .braille,
    }).draw(Region.full(&s));

    // cell 0: left column full (dots 1,2,3,7 = 0x47), right column half
    // (dots 6,8 = 0xA0) → mask 0xE7
    const cp0 = try std.unicode.utf8Decode(s.cellAt(0, 0).?.grapheme());
    try std.testing.expectEqual(@as(u21, 0x2800 + 0xE7), cp0);
    // cell 1: left column one dot (dot 7 = 0x40), right column empty
    const cp1 = try std.unicode.utf8Decode(s.cellAt(1, 0).?.grapheme());
    try std.testing.expectEqual(@as(u21, 0x2800 + 0x40), cp1);
}

test "braille marker keeps the tail at dot resolution" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 2, 1);
    defer s.deinit(gpa);

    // 6 samples into 4 dot columns: only the last 4 drawn — the leading
    // full-height samples fall off, so no full column remains
    (Sparkline{
        .values = &.{ 1, 1, 0.25, 0.25, 0.25, 0.25 },
        .range = .{ 0, 1 },
        .marker = .braille,
    }).draw(Region.full(&s));
    const cp = try std.unicode.utf8Decode(s.cellAt(0, 0).?.grapheme());
    try std.testing.expectEqual(@as(u21, 0x2800 + 0x40 + 0x80), cp); // one bottom dot each side
}
