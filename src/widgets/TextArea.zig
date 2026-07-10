//! A multi-line text editor over a caller-provided buffer. The text is one
//! contiguous byte array with `\n` separators (inserts are O(n) memmoves —
//! fine at TUI scale); the display wraps words with Paragraph's LineIter,
//! and the cursor moves over those *wrapped* rows: up/down keep a sticky
//! desired column through short rows, home/end are visual-row bounds.
//! Vertical scroll follows the cursor. Grapheme-aware like TextField.
//! Deliberately out of v1: selections, undo, horizontal no-wrap mode.
const TextArea = @This();

const std = @import("std");
const Region = @import("../Region.zig");
const Surface = @import("../Surface.zig");
const unicode = @import("../unicode.zig");
const event = @import("../event.zig");
const Key = event.Key;
const LineIter = @import("Paragraph.zig").LineIter;

opts: Surface.Options = .{},

pub const Cursor = struct { x: u16, y: u16 };

/// Draw the wrapped text and return the cursor cell (surface-absolute),
/// or null for an empty region. Adjusts `state.scroll` to keep the cursor
/// visible and records the width keyboard motion will use.
pub fn draw(self: TextArea, region: Region, state: *State) ?Cursor {
    const w = region.width();
    const h: usize = region.height();
    if (w == 0 or h == 0) return null;
    state.last_width = w;

    const loc = locate(state.text(), w, state.cursor);
    const total = totalRows(state.text(), w);
    if (loc.row < state.scroll) state.scroll = loc.row;
    if (loc.row >= state.scroll + h) state.scroll = loc.row - h + 1;
    state.scroll = @min(state.scroll, total -| h);

    var it = RowIter.init(state.text(), w);
    var ord: usize = 0;
    var y: u16 = 0;
    while (it.next()) |row| {
        if (ord < state.scroll) {
            ord += 1;
            continue;
        }
        if (y >= h) break;
        ord += 1;
        _ = region.writeText(0, y, row.text, self.opts);
        y += 1;
    }

    return .{
        .x = region.rect.x + @min(loc.col, w - 1),
        .y = region.rect.y + @as(u16, @intCast(loc.row - state.scroll)),
    };
}

/// The byte offset for a click at region-relative (x, y), or null below
/// the last row — feed it `m.col/m.row - region.rect.x/y`, assign to
/// `state.cursor`, and clear `state.desired_col`.
pub fn hitTest(self: TextArea, state: State, x: u16, y: u16) ?usize {
    _ = self;
    const row = rowAt(state.text(), state.last_width, state.scroll + y) orelse return null;
    return row.start + byteAtCol(row.text, x);
}

pub const State = struct {
    buf: []u8,
    len: usize = 0,
    /// Byte offset of the insertion point, always on a grapheme boundary.
    cursor: usize = 0,
    /// First visible wrapped-row ordinal; `draw` maintains it.
    scroll: usize = 0,
    /// Sticky column that up/down aim for across short rows. Horizontal
    /// motion and edits reset it.
    desired_col: ?u16 = null,
    /// Wrap width recorded by the last `draw`; keyboard motion uses it
    /// (up/down/home/end are no-ops until the first draw).
    last_width: u16 = 0,

    pub fn init(buf: []u8) State {
        return .{ .buf = buf };
    }

    pub fn text(self: *const State) []const u8 {
        return self.buf[0..self.len];
    }

    /// Standard editor bindings: arrows (up/down over wrapped rows),
    /// home/end and ctrl+a/e (visual row), enter (newline), backspace/
    /// delete, ctrl+u clears, printable input inserts. Returns whether
    /// the key was consumed — application bindings go first.
    pub fn handleKey(self: *State, k: Key) bool {
        if (k.kind == .release) return false;
        if (k.matches(Key.left, .{})) {
            self.moveLeft();
            self.desired_col = null;
        } else if (k.matches(Key.right, .{})) {
            self.moveRight();
            self.desired_col = null;
        } else if (k.matches(Key.up, .{})) {
            self.moveUp();
        } else if (k.matches(Key.down, .{})) {
            self.moveDown();
        } else if (k.matches(Key.home, .{}) or k.matches('a', .{ .ctrl = true })) {
            self.rowHome();
            self.desired_col = null;
        } else if (k.matches(Key.end, .{}) or k.matches('e', .{ .ctrl = true })) {
            self.rowEnd();
            self.desired_col = null;
        } else if (k.matches(Key.enter, .{})) {
            self.insert("\n");
        } else if (k.matches(Key.backspace, .{})) {
            self.backspace();
        } else if (k.matches(Key.delete, .{})) {
            self.deleteForward();
        } else if (k.matches('u', .{ .ctrl = true })) {
            self.clear();
        } else if (isText(k)) {
            var tmp: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(k.codepoint, &tmp) catch return false;
            self.insert(tmp[0..n]);
        } else {
            return false;
        }
        return true;
    }

    /// Insert text at the cursor. Newlines pass through (this is the
    /// multi-line widget); `\r` is dropped, tabs fold to a space, other
    /// C0 controls are dropped. Overflow beyond the buffer is dropped.
    pub fn insert(self: *State, bytes: []const u8) void {
        for (bytes) |b| {
            const c: u8 = switch (b) {
                '\n' => '\n',
                '\t' => ' ',
                0...8, 11...31, 127 => continue,
                else => b,
            };
            self.insertRaw(&.{c});
        }
        self.desired_col = null;
    }

    fn insertRaw(self: *State, bytes: []const u8) void {
        if (self.len + bytes.len > self.buf.len) return;
        std.mem.copyBackwards(
            u8,
            self.buf[self.cursor + bytes.len .. self.len + bytes.len],
            self.buf[self.cursor..self.len],
        );
        @memcpy(self.buf[self.cursor..][0..bytes.len], bytes);
        self.len += bytes.len;
        self.cursor += bytes.len;
    }

    pub fn moveLeft(self: *State) void {
        if (self.cursor > 0) self.cursor = self.prevBoundary();
    }

    pub fn moveRight(self: *State) void {
        if (self.cursor < self.len) self.cursor = self.nextBoundary();
    }

    /// Up one wrapped row, aiming for the sticky column.
    pub fn moveUp(self: *State) void {
        if (self.last_width == 0) return;
        const loc = locate(self.text(), self.last_width, self.cursor);
        const desired = self.desired_col orelse loc.col;
        self.desired_col = desired;
        if (loc.row == 0) {
            self.cursor = 0;
            return;
        }
        const target = rowAt(self.text(), self.last_width, loc.row - 1).?;
        self.cursor = target.start + byteAtCol(target.text, desired);
    }

    /// Down one wrapped row, aiming for the sticky column.
    pub fn moveDown(self: *State) void {
        if (self.last_width == 0) return;
        const loc = locate(self.text(), self.last_width, self.cursor);
        const desired = self.desired_col orelse loc.col;
        self.desired_col = desired;
        if (rowAt(self.text(), self.last_width, loc.row + 1)) |target| {
            self.cursor = target.start + byteAtCol(target.text, desired);
        } else {
            self.cursor = self.len;
        }
    }

    /// Start of the current wrapped row.
    pub fn rowHome(self: *State) void {
        if (self.last_width == 0) {
            self.cursor = 0;
            return;
        }
        const loc = locate(self.text(), self.last_width, self.cursor);
        self.cursor = rowAt(self.text(), self.last_width, loc.row).?.start;
    }

    /// End of the current wrapped row's text.
    pub fn rowEnd(self: *State) void {
        if (self.last_width == 0) {
            self.cursor = self.len;
            return;
        }
        const loc = locate(self.text(), self.last_width, self.cursor);
        const row = rowAt(self.text(), self.last_width, loc.row).?;
        self.cursor = row.start + row.text.len;
    }

    pub fn backspace(self: *State) void {
        if (self.cursor == 0) return;
        const start = self.prevBoundary();
        self.deleteRange(start, self.cursor);
        self.cursor = start;
        self.desired_col = null;
    }

    pub fn deleteForward(self: *State) void {
        if (self.cursor >= self.len) return;
        self.deleteRange(self.cursor, self.nextBoundary());
        self.desired_col = null;
    }

    pub fn clear(self: *State) void {
        self.len = 0;
        self.cursor = 0;
        self.scroll = 0;
        self.desired_col = null;
    }

    fn prevBoundary(self: *const State) usize {
        var it = unicode.graphemeIterator(self.buf[0..self.cursor]);
        var prev: usize = 0;
        while (it.next()) |g| prev = g.offset;
        return prev;
    }

    fn nextBoundary(self: *const State) usize {
        var it = unicode.graphemeIterator(self.buf[self.cursor..self.len]);
        const g = it.next() orelse return self.cursor;
        return self.cursor + g.len;
    }

    fn deleteRange(self: *State, start: usize, end: usize) void {
        std.mem.copyForwards(u8, self.buf[start..], self.buf[end..self.len]);
        self.len -= end - start;
    }
};

/// LineIter plus what an editor needs: byte offsets per row (rows are
/// subslices, so offsets are pointer differences) and one trailing virtual
/// empty row when the text is empty or ends with a newline — LineIter
/// yields no row there, but the cursor must have somewhere to sit.
const RowIter = struct {
    text: []const u8,
    inner: LineIter,
    virtual_done: bool = false,

    pub const Row = struct { start: usize, text: []const u8 };

    fn init(text: []const u8, width: u16) RowIter {
        return .{ .text = text, .inner = .{ .text = text, .width = width, .wrap = .word } };
    }

    fn next(self: *RowIter) ?Row {
        if (self.inner.next()) |slice| {
            return .{
                .start = @intFromPtr(slice.ptr) - @intFromPtr(self.text.ptr),
                .text = slice,
            };
        }
        if (!self.virtual_done and
            (self.text.len == 0 or self.text[self.text.len - 1] == '\n'))
        {
            self.virtual_done = true;
            return .{ .start = self.text.len, .text = self.text[self.text.len..] };
        }
        return null;
    }
};

/// The wrapped row and column holding byte offset `cursor`: the last row
/// starting at or before it. Offsets in the swallowed break gap (trimmed
/// spaces, the newline itself) map to the row's visual end.
fn locate(text: []const u8, width: u16, cursor: usize) struct { row: usize, col: u16 } {
    var it = RowIter.init(text, width);
    var row_idx: usize = 0;
    var found_idx: usize = 0;
    var found: RowIter.Row = .{ .start = 0, .text = text[0..0] };
    while (it.next()) |r| : (row_idx += 1) {
        if (r.start > cursor) break;
        found = r;
        found_idx = row_idx;
    }
    const rel = @min(cursor -| found.start, found.text.len);
    return .{ .row = found_idx, .col = @intCast(unicode.strWidth(found.text[0..rel])) };
}

fn rowAt(text: []const u8, width: u16, n: usize) ?RowIter.Row {
    var it = RowIter.init(text, width);
    var i: usize = 0;
    while (it.next()) |r| : (i += 1) {
        if (i == n) return r;
    }
    return null;
}

fn totalRows(text: []const u8, width: u16) usize {
    var it = RowIter.init(text, width);
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

/// Byte offset within `row_text` of the grapheme boundary nearest `col`
/// without passing it. Zero-width clusters stay attached to their base.
fn byteAtCol(row_text: []const u8, col: u16) usize {
    var it = unicode.graphemeIterator(row_text);
    var acc: usize = 0;
    var off: usize = 0;
    while (it.next()) |g| {
        const gw = unicode.graphemeWidth(g.bytes(row_text));
        if (acc + gw > col) break;
        acc += gw;
        off = g.offset + g.len;
    }
    return off;
}

/// Printable, unmodified, and not a kitty PUA functional key.
fn isText(k: Key) bool {
    if (k.mods.ctrl or k.mods.alt or k.mods.super or k.mods.hyper or k.mods.meta) return false;
    if (k.codepoint < 0x20 or k.codepoint == 127) return false;
    if (k.codepoint >= 0xE000 and k.codepoint <= 0xF8FF) return false;
    return true;
}

// --- tests ------------------------------------------------------------

test "rows carry byte offsets and a virtual trailing row" {
    var it = RowIter.init("ab cd\nef\n", 10);
    const r0 = it.next().?;
    try std.testing.expectEqualStrings("ab cd", r0.text);
    try std.testing.expectEqual(@as(usize, 0), r0.start);
    const r1 = it.next().?;
    try std.testing.expectEqualStrings("ef", r1.text);
    try std.testing.expectEqual(@as(usize, 6), r1.start);
    const r2 = it.next().?; // trailing newline → virtual empty row
    try std.testing.expectEqual(@as(usize, 9), r2.start);
    try std.testing.expectEqual(@as(usize, 0), r2.text.len);
    try std.testing.expectEqual(@as(?RowIter.Row, null), it.next());

    // empty text still has one row for the cursor
    var empty = RowIter.init("", 10);
    try std.testing.expectEqual(@as(usize, 0), empty.next().?.start);
}

test "locate maps cursor offsets to wrapped rows" {
    const text = "the quick brown fox";
    // width 10 wraps to "the quick" / "brown fox"
    try std.testing.expectEqual(@as(usize, 0), locate(text, 10, 4).row);
    try std.testing.expectEqual(@as(u16, 4), locate(text, 10, 4).col);
    // the swallowed break space maps to the row's visual end
    try std.testing.expectEqual(@as(usize, 0), locate(text, 10, 9).row);
    try std.testing.expectEqual(@as(u16, 9), locate(text, 10, 9).col);
    // first byte after the gap is the next row, column 0
    try std.testing.expectEqual(@as(usize, 1), locate(text, 10, 10).row);
    try std.testing.expectEqual(@as(u16, 0), locate(text, 10, 10).col);

    // cursor at the very end after a newline sits on the virtual row
    const nl = "ab\n";
    try std.testing.expectEqual(@as(usize, 1), locate(nl, 10, 3).row);
    try std.testing.expectEqual(@as(u16, 0), locate(nl, 10, 3).col);
}

test "up and down keep a sticky column over wrapped rows" {
    var buf: [128]u8 = undefined;
    var st = State.init(&buf);
    st.insert("eerste lang reël hier\nkort\nderde lang reël onder");
    st.last_width = 40; // wide enough: three logical rows

    // start on row 2 at column 11 ("derde lang |reël"; row starts at 28)
    st.cursor = 28 + 11;
    st.moveUp(); // "kort" is shorter → clamps to its end, sticky col kept
    const on_kort = locate(st.text(), 40, st.cursor);
    try std.testing.expectEqual(@as(usize, 1), on_kort.row);
    try std.testing.expectEqual(@as(u16, 4), on_kort.col);
    st.moveUp(); // back to a long row → returns to column 11
    try std.testing.expectEqual(@as(u16, 11), locate(st.text(), 40, st.cursor).col);
    st.moveDown();
    st.moveDown();
    try std.testing.expectEqual(@as(u16, 11), locate(st.text(), 40, st.cursor).col);

    // top and bottom edges pin to the text bounds
    st.cursor = 3;
    st.moveUp();
    try std.testing.expectEqual(@as(usize, 0), st.cursor);
    st.cursor = st.len - 2;
    st.moveDown();
    try std.testing.expectEqual(st.len, st.cursor);
}

test "motion follows soft wraps, not just newlines" {
    var buf: [64]u8 = undefined;
    var st = State.init(&buf);
    st.insert("een twee drie vier");
    st.last_width = 9; // wraps: "een twee" / "drie vier"

    st.cursor = 0;
    st.moveDown();
    const loc = locate(st.text(), 9, st.cursor);
    try std.testing.expectEqual(@as(usize, 1), loc.row);
    try std.testing.expectEqual(@as(u16, 0), loc.col);
    try std.testing.expectEqual(@as(usize, 9), st.cursor); // start of "drie"

    st.rowEnd();
    try std.testing.expectEqual(st.len, st.cursor);
    st.rowHome();
    try std.testing.expectEqual(@as(usize, 9), st.cursor);
}

test "insert keeps newlines and folds tabs" {
    var buf: [32]u8 = undefined;
    var st = State.init(&buf);
    st.insert("a\r\nb\tc\x07");
    try std.testing.expectEqualStrings("a\nb c", st.text());
}

test "handleKey edits across rows" {
    var buf: [64]u8 = undefined;
    var st = State.init(&buf);
    st.last_width = 20;

    try std.testing.expect(st.handleKey(.{ .codepoint = 'a' }));
    try std.testing.expect(st.handleKey(.{ .codepoint = Key.enter }));
    try std.testing.expect(st.handleKey(.{ .codepoint = 'b' }));
    try std.testing.expectEqualStrings("a\nb", st.text());

    try std.testing.expect(st.handleKey(.{ .codepoint = Key.up }));
    try std.testing.expectEqual(@as(usize, 1), st.cursor); // row 0, col 1
    // backspace across the newline joins the rows
    st.cursor = 2;
    try std.testing.expect(st.handleKey(.{ .codepoint = Key.backspace }));
    try std.testing.expectEqualStrings("ab", st.text());
    try std.testing.expect(!st.handleKey(.{ .codepoint = 'x', .mods = .{ .alt = true } }));
}

test "draw wraps, scrolls to the cursor, and places it" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 6, 2);
    defer s.deinit(gpa);

    var buf: [64]u8 = undefined;
    var st = State.init(&buf);
    st.insert("een twee drie vier vyf");
    const ta: TextArea = .{};

    // cursor at the end: 5 wrapped rows in a 2-row window → scrolled down
    var cur = ta.draw(Region.full(&s), &st).?;
    try std.testing.expect(st.scroll > 0);
    try std.testing.expectEqual(@as(u16, 1), cur.y); // cursor on the last visible row
    try std.testing.expectEqualStrings("v", s.cellAt(0, 1).?.grapheme());

    // cursor back to the top: window follows
    st.cursor = 0;
    s.clear();
    cur = ta.draw(Region.full(&s), &st).?;
    try std.testing.expectEqual(@as(usize, 0), st.scroll);
    try std.testing.expectEqual(@as(u16, 0), cur.x);
    try std.testing.expectEqual(@as(u16, 0), cur.y);
    try std.testing.expectEqualStrings("e", s.cellAt(0, 0).?.grapheme());

    // trailing newline: cursor sits on the virtual empty row
    var st2 = State.init(&buf);
    st2.insert("ab\n");
    s.clear();
    cur = ta.draw(Region.full(&s), &st2).?;
    try std.testing.expectEqual(@as(u16, 0), cur.x);
    try std.testing.expectEqual(@as(u16, 1), cur.y);
}

test "hitTest maps clicks to byte offsets" {
    var buf: [64]u8 = undefined;
    var st = State.init(&buf);
    st.insert("een twee drie");
    st.last_width = 9; // "een twee" / "drie"

    const ta: TextArea = .{};
    try std.testing.expectEqual(@as(?usize, 2), ta.hitTest(st, 2, 0));
    try std.testing.expectEqual(@as(?usize, 9), ta.hitTest(st, 0, 1)); // "drie"
    try std.testing.expectEqual(@as(?usize, 13), ta.hitTest(st, 30, 1)); // past the text: row end
    try std.testing.expectEqual(@as(?usize, null), ta.hitTest(st, 0, 5)); // below the rows
}
