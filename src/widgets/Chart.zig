//! An XY chart: datasets plotted in braille dots inside labeled axes —
//! line or scatter per dataset, data mapped from `x_bounds`/`y_bounds`
//! onto the plot's dot grid. Axis labels are caller-formatted strings
//! spread along each axis (the app decides number formatting), and named
//! datasets stack a legend in the plot's top-right corner. Stateless and
//! allocation-free like the rest of the layer.
const Chart = @This();

const std = @import("std");
const Region = @import("../Region.zig");
const Surface = @import("../Surface.zig");
const cell_mod = @import("../cell.zig");
const Cell = cell_mod.Cell;
const Style = cell_mod.Style;
const unicode = @import("../unicode.zig");
const braille = @import("braille.zig");

datasets: []const Dataset = &.{},
x_bounds: [2]f64 = .{ 0, 1 },
y_bounds: [2]f64 = .{ 0, 1 },
/// Spread left→right along the x axis; first is left-aligned at the axis
/// origin, last right-aligned at the edge, the rest proportionally between.
x_labels: []const []const u8 = &.{},
/// Spread bottom→top along the y axis, right-aligned against the axis.
y_labels: []const []const u8 = &.{},
axis_style: Style = .{},
/// Stack the names of named datasets in the plot's top-right corner.
show_legend: bool = true,

pub const Dataset = struct {
    name: []const u8 = "",
    /// (x, y) pairs in data space; points outside the bounds are skipped,
    /// and a line segment with a skipped endpoint is not drawn.
    points: []const [2]f64 = &.{},
    style: Style = .{},
    kind: Kind = .line,

    pub const Kind = enum { line, scatter };
};

pub fn draw(self: Chart, region: Region) void {
    const w = region.width();
    const h = region.height();

    // Geometry: y labels + one axis column on the left, one axis row (plus
    // an x-label row) at the bottom.
    var ylw: u16 = 0;
    for (self.y_labels) |l| ylw = @max(ylw, @as(u16, @intCast(unicode.strWidth(l))));
    const left = ylw + 1;
    const bottom: u16 = if (self.x_labels.len > 0) 2 else 1;
    if (w <= left or h <= bottom) return;
    const axis_row = h - bottom;
    const plot = region.sub(.{ .x = left, .width = w - left, .height = axis_row });

    // Axes.
    var y: u16 = 0;
    while (y < axis_row) : (y += 1) region.writeCell(ylw, y, Cell.init("│", 1, self.axis_style));
    region.writeCell(ylw, axis_row, Cell.init("└", 1, self.axis_style));
    var x = left;
    while (x < w) : (x += 1) region.writeCell(x, axis_row, Cell.init("─", 1, self.axis_style));

    const axis_opts: Surface.Options = .{
        .fg = self.axis_style.fg,
        .bg = self.axis_style.bg,
        .attrs = self.axis_style.attrs,
    };

    // Labels: y bottom→top over the plot rows, x spread along the axis.
    if (self.y_labels.len > 0 and axis_row > 0) {
        const n = self.y_labels.len;
        for (self.y_labels, 0..) |label, i| {
            const row: u16 = if (n == 1)
                axis_row - 1
            else
                axis_row - 1 - @as(u16, @intCast(i * (axis_row - 1) / (n - 1)));
            const lw: u16 = @intCast(unicode.strWidth(label));
            _ = region.writeText(ylw -| lw, row, label, axis_opts);
        }
    }
    if (self.x_labels.len > 0) {
        const n = self.x_labels.len;
        const plot_w = w - left;
        for (self.x_labels, 0..) |label, i| {
            const lw: u16 = @intCast(@min(unicode.strWidth(label), plot_w));
            const lx: u16 = if (n == 1)
                left
            else
                left + @as(u16, @intCast(i * (plot_w - lw) / (n - 1)));
            _ = region.writeText(lx, h - 1, label, axis_opts);
        }
    }

    // Datasets.
    const dw = braille.dotWidth(plot);
    const dh = braille.dotHeight(plot);
    if (dw == 0 or dh == 0) return;
    for (self.datasets) |ds| {
        switch (ds.kind) {
            .scatter => for (ds.points) |p| {
                const d = self.mapPoint(p, dw, dh) orelse continue;
                braille.dot(plot, d[0], d[1], ds.style);
            },
            .line => {
                var i: usize = 1;
                while (i < ds.points.len) : (i += 1) {
                    const a = self.mapPoint(ds.points[i - 1], dw, dh) orelse continue;
                    const b = self.mapPoint(ds.points[i], dw, dh) orelse continue;
                    braille.line(plot, a[0], a[1], b[0], b[1], ds.style);
                }
            },
        }
    }

    // Legend.
    if (self.show_legend) {
        var row: u16 = 0;
        for (self.datasets) |ds| {
            if (ds.name.len == 0) continue;
            const lw: u16 = @intCast(unicode.strWidth(ds.name));
            _ = plot.writeText(plot.width() -| lw, row, ds.name, .{
                .fg = ds.style.fg,
                .bg = ds.style.bg,
                .attrs = ds.style.attrs,
            });
            row += 1;
        }
    }
}

/// Data space → dot space, y flipped (data grows up, rows grow down).
/// Null for points outside the bounds (NaN fails the range check too).
fn mapPoint(self: Chart, p: [2]f64, dw: u32, dh: u32) ?[2]u32 {
    const xspan = self.x_bounds[1] - self.x_bounds[0];
    const yspan = self.y_bounds[1] - self.y_bounds[0];
    if (xspan <= 0 or yspan <= 0) return null;
    const tx = (p[0] - self.x_bounds[0]) / xspan;
    const ty = (p[1] - self.y_bounds[0]) / yspan;
    if (!(tx >= 0 and tx <= 1 and ty >= 0 and ty <= 1)) return null;
    return .{
        @intFromFloat(@round(tx * @as(f64, @floatFromInt(dw - 1)))),
        @intFromFloat(@round((1 - ty) * @as(f64, @floatFromInt(dh - 1)))),
    };
}

// --- tests ------------------------------------------------------------

fn isBraille(g: []const u8) bool {
    if (g.len != 3) return false;
    const cp = std.unicode.utf8Decode(g) catch return false;
    return cp >= 0x2800 and cp <= 0x28FF;
}

test "axes and labels are placed around the plot" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 12, 6);
    defer s.deinit(gpa);

    (Chart{
        .y_labels = &.{ "0", "9" },
        .x_labels = &.{ "a", "b" },
    }).draw(Region.full(&s));

    // axis column at x=1 (labels are 1 wide), corner, axis row at y=4
    try std.testing.expectEqualStrings("│", s.cellAt(1, 0).?.grapheme());
    try std.testing.expectEqualStrings("│", s.cellAt(1, 3).?.grapheme());
    try std.testing.expectEqualStrings("└", s.cellAt(1, 4).?.grapheme());
    try std.testing.expectEqualStrings("─", s.cellAt(2, 4).?.grapheme());
    try std.testing.expectEqualStrings("─", s.cellAt(11, 4).?.grapheme());
    // y labels: "0" at the bottom plot row, "9" at the top
    try std.testing.expectEqualStrings("0", s.cellAt(0, 3).?.grapheme());
    try std.testing.expectEqualStrings("9", s.cellAt(0, 0).?.grapheme());
    // x labels: "a" at the axis origin, "b" right-aligned at the far edge
    try std.testing.expectEqualStrings("a", s.cellAt(2, 5).?.grapheme());
    try std.testing.expectEqualStrings("b", s.cellAt(11, 5).?.grapheme());
}

test "points map into the plot's dot grid" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 12, 6);
    defer s.deinit(gpa);

    (Chart{
        .y_labels = &.{ "0", "9" },
        .x_labels = &.{ "a", "b" },
        .show_legend = false,
        .datasets = &.{.{
            .kind = .scatter,
            .points = &.{ .{ 0, 0 }, .{ 1, 1 }, .{ 2, 0.5 }, .{ 0.5, -1 } },
            .style = .{ .fg = .{ .ansi = 2 } },
        }},
    }).draw(Region.full(&s));

    // (0,0) → bottom-left of the plot; (1,1) → top-right; both others out
    // of bounds and skipped
    try std.testing.expectEqualStrings("⡀", s.cellAt(2, 3).?.grapheme());
    try std.testing.expectEqual(cell_mod.Color{ .ansi = 2 }, s.cellAt(2, 3).?.style.fg);
    try std.testing.expectEqualStrings("⠈", s.cellAt(11, 0).?.grapheme());
    var braille_cells: usize = 0;
    var yy: u16 = 0;
    while (yy < 4) : (yy += 1) {
        var xx: u16 = 2;
        while (xx < 12) : (xx += 1) {
            if (isBraille(s.cellAt(xx, yy).?.grapheme())) braille_cells += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), braille_cells); // only the two in-bounds points
}

test "line datasets connect their points" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 10, 4);
    defer s.deinit(gpa);

    (Chart{
        .show_legend = false,
        .datasets = &.{.{ .points = &.{ .{ 0, 0 }, .{ 1, 1 } } }},
    }).draw(Region.full(&s));

    // diagonal from bottom-left to top-right of the plot (x=1..9, y=0..2)
    try std.testing.expect(isBraille(s.cellAt(1, 2).?.grapheme()));
    try std.testing.expect(isBraille(s.cellAt(9, 0).?.grapheme()));
    // connected: every plot column touched
    var xx: u16 = 1;
    while (xx < 10) : (xx += 1) {
        var any = false;
        var yy: u16 = 0;
        while (yy < 3) : (yy += 1) {
            if (isBraille(s.cellAt(xx, yy).?.grapheme())) any = true;
        }
        try std.testing.expect(any);
    }
}

test "legend stacks named datasets top-right" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 12, 5);
    defer s.deinit(gpa);

    (Chart{
        .datasets = &.{
            .{ .name = "sin", .style = .{ .fg = .{ .ansi = 2 } } },
            .{ .name = "cos", .style = .{ .fg = .{ .ansi = 5 } } },
        },
    }).draw(Region.full(&s));

    try std.testing.expectEqualStrings("s", s.cellAt(9, 0).?.grapheme());
    try std.testing.expectEqual(cell_mod.Color{ .ansi = 2 }, s.cellAt(9, 0).?.style.fg);
    try std.testing.expectEqualStrings("c", s.cellAt(9, 1).?.grapheme());
}

test "degenerate shapes and bounds draw nothing" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 3, 2);
    defer s.deinit(gpa);

    // too small for labels + axes
    (Chart{ .y_labels = &.{"1000"} }).draw(Region.full(&s));
    try std.testing.expectEqualStrings(" ", s.cellAt(0, 0).?.grapheme());

    // zero-span bounds: all points rejected, axes still drawn
    var s2 = try Surface.init(gpa, 6, 3);
    defer s2.deinit(gpa);
    (Chart{
        .x_bounds = .{ 1, 1 },
        .datasets = &.{.{ .points = &.{.{ 1, 0.5 }} }},
        .show_legend = false,
    }).draw(Region.full(&s2));
    try std.testing.expectEqualStrings("└", s2.cellAt(0, 2).?.grapheme());
    var xx: u16 = 1;
    while (xx < 6) : (xx += 1) {
        var yy: u16 = 0;
        while (yy < 2) : (yy += 1) {
            try std.testing.expect(!isBraille(s2.cellAt(xx, yy).?.grapheme()));
        }
    }
}
