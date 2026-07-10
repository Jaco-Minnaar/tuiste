//! A progress bar: the filled fraction of one row, smoothed with eighth
//! blocks, with an optional centered label (a percentage by default).
const Gauge = @This();

const std = @import("std");
const Region = @import("../Region.zig");
const Surface = @import("../Surface.zig");
const unicode = @import("../unicode.zig");

/// Filled fraction, clamped to 0…1.
ratio: f32 = 0,
/// Style of the filled part (and the track it leaves behind).
opts: Surface.Options = .{},
/// Centered over the bar. Null draws a percentage; "" draws nothing.
label: ?[]const u8 = null,
label_opts: Surface.Options = .{},

/// Left-aligned partial blocks, one eighth to seven eighths.
const eighth_blocks = [_][]const u8{ "▏", "▎", "▍", "▌", "▋", "▊", "▉" };

/// Draw into the region's first row.
pub fn draw(self: Gauge, region: Region) void {
    const w = region.width();
    if (w == 0 or region.height() == 0) return;

    const ratio = std.math.clamp(self.ratio, 0.0, 1.0);
    const eighths: u32 = @intFromFloat(@round(ratio * @as(f32, @floatFromInt(w)) * 8));
    const full: u16 = @intCast(eighths / 8);
    const rem: u16 = @intCast(eighths % 8);

    var x: u16 = 0;
    while (x < full) : (x += 1) _ = region.writeText(x, 0, "█", self.opts);
    if (rem > 0 and full < w) _ = region.writeText(full, 0, eighth_blocks[rem - 1], self.opts);

    var pct_buf: [8]u8 = undefined;
    const label = self.label orelse std.fmt.bufPrint(&pct_buf, "{d}%", .{
        @as(u8, @intFromFloat(@round(ratio * 100))),
    }) catch unreachable;
    if (label.len > 0) {
        const lw: u16 = @intCast(@min(unicode.strWidth(label), w));
        _ = region.writeText((w - lw) / 2, 0, label, self.label_opts);
    }
}

// --- tests ------------------------------------------------------------

test "fills the right fraction with a percent label" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 10, 1);
    defer s.deinit(gpa);

    (Gauge{ .ratio = 0.5, .label = "" }).draw(Region.full(&s));
    try std.testing.expectEqualStrings("█", s.cellAt(4, 0).?.grapheme());
    try std.testing.expectEqualStrings(" ", s.cellAt(5, 0).?.grapheme());

    s.clear();
    (Gauge{ .ratio = 1.0 }).draw(Region.full(&s));
    try std.testing.expectEqualStrings("█", s.cellAt(0, 0).?.grapheme());
    try std.testing.expectEqualStrings("█", s.cellAt(9, 0).?.grapheme());
    // "100%" centered over the bar
    try std.testing.expectEqualStrings("1", s.cellAt(3, 0).?.grapheme());
    try std.testing.expectEqualStrings("%", s.cellAt(6, 0).?.grapheme());
}

test "partial eighths and clamping" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 8, 1);
    defer s.deinit(gpa);

    // 0.5625 of 8 cells = 4.5 cells → 4 full + a half block
    (Gauge{ .ratio = 0.5625, .label = "" }).draw(Region.full(&s));
    try std.testing.expectEqualStrings("█", s.cellAt(3, 0).?.grapheme());
    try std.testing.expectEqualStrings("▌", s.cellAt(4, 0).?.grapheme());

    s.clear();
    (Gauge{ .ratio = 7.5, .label = "" }).draw(Region.full(&s)); // clamps to 1
    try std.testing.expectEqualStrings("█", s.cellAt(7, 0).?.grapheme());
    (Gauge{ .ratio = -2, .label = "x" }).draw(Region.init(&s, .{ .width = 0, .height = 1 })); // no-op
}
