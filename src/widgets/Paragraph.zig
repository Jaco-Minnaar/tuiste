//! Wrapped text. Word-wraps (or hard-wraps) into the region, honoring
//! explicit newlines; `measure` answers "how many rows at this width"
//! without drawing, for layout decisions. Vertical scrolling is immediate
//! mode like everything else: the application owns the offset and passes
//! it in via `scroll`.
const Paragraph = @This();

const std = @import("std");
const Region = @import("../Region.zig");
const Surface = @import("../Surface.zig");
const unicode = @import("../unicode.zig");

text: []const u8 = "",
opts: Surface.Options = .{},
wrap: Wrap = .word,
/// Wrapped rows to skip before the first drawn one. Clamp it in the app
/// with `measure` — scrolled past the end just draws nothing.
scroll: u16 = 0,

pub const Wrap = enum {
    /// Break at spaces; a word wider than the region hard-breaks.
    word,
    /// Break at any grapheme boundary.
    grapheme,
};

/// Wrap into the region and return the number of rows actually written
/// (bounded by the region height).
pub fn draw(self: Paragraph, region: Region) u16 {
    if (region.width() == 0 or region.height() == 0) return 0;
    var lines: LineIter = .{ .text = self.text, .width = region.width(), .wrap = self.wrap };
    var skip = self.scroll;
    var row: u16 = 0;
    while (lines.next()) |line| {
        if (skip > 0) {
            skip -= 1;
            continue;
        }
        if (row >= region.height()) break;
        _ = region.writeText(0, row, line, self.opts);
        row += 1;
    }
    return row;
}

/// Rows the text needs when wrapped to `width` — measure before splitting
/// a layout, or to clamp a scroll offset. A trailing newline does not add
/// an empty row; interior blank lines count.
pub fn measure(self: Paragraph, width: u16) u16 {
    if (width == 0) return 0;
    var lines: LineIter = .{ .text = self.text, .width = width, .wrap = self.wrap };
    var rows: u16 = 0;
    while (lines.next()) |_| rows +|= 1;
    return rows;
}

/// Yields one wrapped row per call: grapheme- and width-aware, breaking at
/// spaces in `.word` mode (swallowing the space run and trimming it from
/// the row's tail), anywhere in `.grapheme` mode. Always consumes at least
/// one grapheme per row, so a glyph wider than the whole region can't stall
/// it (the row just clips at draw time). Rows are subslices of the input
/// text (TextArea leans on that to recover byte offsets); a trailing
/// newline yields no empty row.
pub const LineIter = struct {
    text: []const u8,
    width: u16,
    wrap: Wrap,
    pos: usize = 0,

    pub fn next(self: *LineIter) ?[]const u8 {
        if (self.pos >= self.text.len) return null;
        const start = self.pos;
        var iter = unicode.graphemeIterator(self.text[start..]);
        var col: u32 = 0;
        var break_end: ?usize = null; // exclusive line end at the last space run
        var break_resume: usize = 0; // where to continue after breaking there
        var prev_space = false;
        while (iter.next()) |g| {
            const abs = start + g.offset;
            const bytes = g.bytes(self.text[start..]);
            const is_space = bytes.len == 1 and bytes[0] == ' ';

            if (bytes.len == 1 and bytes[0] == '\n') {
                self.pos = abs + 1;
                return self.text[start..trimmedEnd(abs, prev_space, break_end)];
            }

            const gw = unicode.graphemeWidth(bytes);
            if (col + gw > self.width and abs > start) {
                if (self.wrap == .word) {
                    if (is_space) {
                        // The overflowing grapheme is the break itself.
                        self.pos = skipSpaces(self.text, abs);
                        return self.text[start..trimmedEnd(abs, prev_space, break_end)];
                    }
                    if (break_end) |be| {
                        self.pos = break_resume;
                        return self.text[start..be];
                    }
                    // No space on this row: hard-break like .grapheme.
                }
                self.pos = abs;
                return self.text[start..abs];
            }

            col += gw;
            if (is_space) {
                if (!prev_space) break_end = abs;
                break_resume = abs + 1;
            }
            prev_space = is_space;
        }
        self.pos = self.text.len;
        return self.text[start..];
    }

    /// End of a row cut at `abs`: with a space run leading up to it, cut at
    /// the run's start instead so rows never carry trailing spaces.
    fn trimmedEnd(abs: usize, prev_space: bool, break_end: ?usize) usize {
        return if (prev_space) break_end.? else abs;
    }

    fn skipSpaces(text: []const u8, from: usize) usize {
        var i = from;
        while (i < text.len and text[i] == ' ') i += 1;
        return i;
    }
};

// --- tests ------------------------------------------------------------

fn expectRows(text: []const u8, width: u16, wrap: Wrap, expected: []const []const u8) !void {
    var lines: LineIter = .{ .text = text, .width = width, .wrap = wrap };
    for (expected) |want| {
        const got = lines.next() orelse return error.TooFewRows;
        try std.testing.expectEqualStrings(want, got);
    }
    try std.testing.expectEqual(@as(?[]const u8, null), lines.next());
}

test "word wrap breaks at spaces and trims them" {
    try expectRows("the quick brown fox", 10, .word, &.{ "the quick", "brown fox" });
    try expectRows("een twee", 3, .word, &.{ "een", "twe", "e" }); // word wider than width hard-breaks
    try expectRows("a  b", 2, .word, &.{ "a", "b" }); // space run swallowed, no leading space
    try expectRows("ab cd ", 5, .word, &.{"ab cd"}); // trailing spaces trimmed
}

test "explicit newlines and blank lines" {
    try expectRows("een\n\ntwee", 10, .word, &.{ "een", "", "twee" });
    try expectRows("een\n", 10, .word, &.{"een"}); // trailing newline adds no row
    try expectRows("een \ntwee", 10, .word, &.{ "een", "twee" }); // spaces before newline trimmed
}

test "grapheme wrap breaks anywhere" {
    try expectRows("abcdef", 4, .grapheme, &.{ "abcd", "ef" });
}

test "wide graphemes count two columns" {
    try expectRows("宽宽宽", 4, .word, &.{ "宽宽", "宽" });
    // wider than the whole width: still consumes one per row (no stall)
    try expectRows("宽宽", 1, .word, &.{ "宽", "宽" });
}

test "combining marks stay with their base" {
    // é as e + U+0301 — must never split across rows
    try expectRows("ee\u{301}e", 2, .grapheme, &.{ "ee\u{301}", "e" });
}

test "draw writes wrapped rows and honors scroll and height" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 5, 2);
    defer s.deinit(gpa);

    const p: Paragraph = .{ .text = "een twee drie vier" };
    const rows = p.draw(Region.full(&s));
    try std.testing.expectEqual(@as(u16, 2), rows); // 4 wrapped rows, height clips at 2
    try std.testing.expectEqualStrings("e", s.cellAt(0, 0).?.grapheme());
    try std.testing.expectEqualStrings("t", s.cellAt(0, 1).?.grapheme());

    s.clear();
    const scrolled: Paragraph = .{ .text = "een twee drie vier", .scroll = 2 };
    _ = scrolled.draw(Region.full(&s));
    try std.testing.expectEqualStrings("d", s.cellAt(0, 0).?.grapheme());
    try std.testing.expectEqualStrings("v", s.cellAt(0, 1).?.grapheme());

    // scrolled past the end: nothing drawn
    s.clear();
    const gone: Paragraph = .{ .text = "een twee", .scroll = 99 };
    try std.testing.expectEqual(@as(u16, 0), gone.draw(Region.full(&s)));
    try std.testing.expectEqualStrings(" ", s.cellAt(0, 0).?.grapheme());
}

test "exact-width rows stay inside a surrounding block" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 14, 6);
    defer s.deinit(gpa);

    const Block = @import("Block.zig");
    const inner = (Block{}).draw(Region.full(&s)); // 12 x 4 interior
    const p: Paragraph = .{ .text = "abcdefghijkl mnop" }; // word == inner width
    _ = p.draw(inner);

    try std.testing.expectEqualStrings("a", s.cellAt(1, 1).?.grapheme());
    try std.testing.expectEqualStrings("l", s.cellAt(12, 1).?.grapheme());
    try std.testing.expectEqualStrings("│", s.cellAt(13, 1).?.grapheme()); // border intact
    try std.testing.expectEqualStrings("m", s.cellAt(1, 2).?.grapheme()); // rest wrapped

    // wide graphemes filling the row exactly
    var s2 = try Surface.init(gpa, 6, 4);
    defer s2.deinit(gpa);
    const inner2 = (Block{}).draw(Region.full(&s2)); // 4 x 2 interior
    _ = (Paragraph{ .text = "宽宽宽" }).draw(inner2);
    try std.testing.expectEqualStrings("│", s2.cellAt(5, 1).?.grapheme());
    try std.testing.expectEqualStrings("宽", s2.cellAt(1, 2).?.grapheme());
}

test "measure agrees with wrapping" {
    const p: Paragraph = .{ .text = "the quick brown fox\njumps" };
    try std.testing.expectEqual(@as(u16, 3), p.measure(10));
    try std.testing.expectEqual(@as(u16, 5), p.measure(5));
    try std.testing.expectEqual(@as(u16, 0), p.measure(0));
    const empty: Paragraph = .{};
    try std.testing.expectEqual(@as(u16, 0), empty.measure(10));
}
