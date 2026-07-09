//! Thin wrapper over the `zg` Unicode data, so the dependency stays swappable
//! and the rest of the library never imports it directly.
const std = @import("std");
const DisplayWidth = @import("DisplayWidth");
const Graphemes = @import("Graphemes");

pub const Grapheme = Graphemes.Grapheme;
pub const GraphemeIterator = Graphemes.Iterator;

pub fn graphemeIterator(str: []const u8) GraphemeIterator {
    return Graphemes.iterator(str);
}

/// Display width of a whole string in terminal columns.
pub fn strWidth(str: []const u8) usize {
    return DisplayWidth.strWidth(str);
}

/// Display width of a single grapheme cluster, clamped to the 0–2 range
/// that a terminal cell can actually represent.
pub fn graphemeWidth(bytes: []const u8) u2 {
    const w = DisplayWidth.graphemeWidth(bytes);
    if (w <= 0) return 0;
    if (w >= 2) return 2;
    return 1;
}

test "grapheme widths" {
    try std.testing.expectEqual(@as(u2, 1), graphemeWidth("a"));
    try std.testing.expectEqual(@as(u2, 2), graphemeWidth("宽"));
    try std.testing.expectEqual(@as(u2, 2), graphemeWidth("👍"));
}

test "string width counts columns not bytes" {
    try std.testing.expectEqual(@as(usize, 4), strWidth("宽字"));
    try std.testing.expectEqual(@as(usize, 5), strWidth("héllo"));
}
