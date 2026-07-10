//! A single-line editable text field. The buffer, cursor, and horizontal
//! scroll live in a `TextField.State` backed by caller-provided memory; the
//! widget draws the visible slice (scrolled so the cursor stays in view)
//! and returns the surface-absolute cursor cell to pass to
//! `Terminal.setCursor`. Editing is grapheme-aware throughout: é, 宽 and
//! ZWJ emoji move and delete as single units.
const TextField = @This();

const std = @import("std");
const Region = @import("../Region.zig");
const Surface = @import("../Surface.zig");
const unicode = @import("../unicode.zig");
const event = @import("../event.zig");
const Key = event.Key;

opts: Surface.Options = .{},
/// Shown (in `placeholder_opts`) while the field is empty.
placeholder: []const u8 = "",
placeholder_opts: Surface.Options = .{ .attrs = .{ .dim = true } },

/// Where the hardware cursor belongs, in surface coordinates.
pub const Cursor = struct { x: u16, y: u16 };

/// Draw into the region's first row and return the cursor cell, or null
/// for an empty region. Adjusts `state.scroll` so the cursor is visible.
pub fn draw(self: TextField, region: Region, state: *State) ?Cursor {
    const w = region.width();
    if (w == 0 or region.height() == 0) return null;

    // Scroll left if the cursor moved before the window, right until the
    // cursor's column fits. Both walks are grapheme-aligned.
    if (state.cursor < state.scroll) state.scroll = state.cursor;
    while (columnsBetween(state.text(), state.scroll, state.cursor) >= w) {
        var it = unicode.graphemeIterator(state.text()[state.scroll..]);
        const g = it.next() orelse break;
        state.scroll += g.len;
    }

    if (state.len == 0 and self.placeholder.len > 0) {
        _ = region.writeText(0, 0, self.placeholder, self.placeholder_opts);
    } else {
        _ = region.writeText(0, 0, state.text()[state.scroll..], self.opts);
    }

    const col: u16 = @intCast(columnsBetween(state.text(), state.scroll, state.cursor));
    return .{ .x = region.rect.x + col, .y = region.rect.y };
}

fn columnsBetween(text: []const u8, from: usize, to: usize) usize {
    if (to <= from) return 0;
    return unicode.strWidth(text[from..to]);
}

/// The application-owned buffer + cursor + scroll. `init` with any `[]u8`
/// the application provides; input that would overflow it is dropped.
pub const State = struct {
    buf: []u8,
    len: usize = 0,
    /// Byte offset of the insertion point, always on a grapheme boundary.
    cursor: usize = 0,
    /// Byte offset of the first visible grapheme; `draw` maintains it.
    scroll: usize = 0,

    pub fn init(buf: []u8) State {
        return .{ .buf = buf };
    }

    pub fn text(self: *const State) []const u8 {
        return self.buf[0..self.len];
    }

    /// Handle a standard editing key (arrows, home/end, ctrl+a/e/u,
    /// backspace/delete, printable input). Returns whether the key was
    /// consumed, so the application checks its own bindings first and
    /// falls through to this.
    pub fn handleKey(self: *State, k: Key) bool {
        if (k.kind == .release) return false;
        if (k.matches(Key.left, .{})) {
            self.moveLeft();
        } else if (k.matches(Key.right, .{})) {
            self.moveRight();
        } else if (k.matches(Key.home, .{}) or k.matches('a', .{ .ctrl = true })) {
            self.cursor = 0;
        } else if (k.matches(Key.end, .{}) or k.matches('e', .{ .ctrl = true })) {
            self.cursor = self.len;
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

    /// Insert text at the cursor, made single-line safe: newlines fold to
    /// spaces, carriage returns and other C0 controls are dropped. Anything
    /// past the buffer's capacity is dropped.
    pub fn insert(self: *State, bytes: []const u8) void {
        for (bytes) |b| {
            const c: u8 = switch (b) {
                '\n' => ' ',
                0...9, 11...31, 127 => continue,
                else => b,
            };
            self.insertRaw(&.{c});
        }
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

    pub fn backspace(self: *State) void {
        if (self.cursor == 0) return;
        const start = self.prevBoundary();
        self.deleteRange(start, self.cursor);
        self.cursor = start;
    }

    pub fn deleteForward(self: *State) void {
        if (self.cursor >= self.len) return;
        self.deleteRange(self.cursor, self.nextBoundary());
    }

    pub fn clear(self: *State) void {
        self.len = 0;
        self.cursor = 0;
        self.scroll = 0;
    }

    /// Byte offset of the grapheme boundary before the cursor.
    fn prevBoundary(self: *const State) usize {
        var it = unicode.graphemeIterator(self.buf[0..self.cursor]);
        var prev: usize = 0;
        while (it.next()) |g| prev = g.offset;
        return prev;
    }

    /// Byte offset of the grapheme boundary after the cursor.
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

/// A key event that should insert its codepoint: printable, unmodified,
/// and not one of the kitty functional keys (which live in the PUA).
fn isText(k: Key) bool {
    if (k.mods.ctrl or k.mods.alt or k.mods.super or k.mods.hyper or k.mods.meta) return false;
    if (k.codepoint < 0x20 or k.codepoint == 127) return false;
    if (k.codepoint >= 0xE000 and k.codepoint <= 0xF8FF) return false;
    return true;
}

// --- tests ------------------------------------------------------------

test "insert, move, and delete are grapheme-aware" {
    var buf: [64]u8 = undefined;
    var st = State.init(&buf);

    st.insert("ab宽é👍");
    try std.testing.expectEqualStrings("ab宽é👍", st.text());
    try std.testing.expectEqual(st.len, st.cursor);

    st.backspace(); // removes the whole 👍
    try std.testing.expectEqualStrings("ab宽é", st.text());
    st.moveLeft(); // over é
    st.moveLeft(); // over 宽
    st.deleteForward(); // removes 宽
    try std.testing.expectEqualStrings("abé", st.text());
    st.insert("X");
    try std.testing.expectEqualStrings("abXé", st.text());
}

test "insert is single-line safe and respects capacity" {
    var buf: [4]u8 = undefined;
    var st = State.init(&buf);
    st.insert("a\r\nb\x07");
    try std.testing.expectEqualStrings("a b", st.text()); // \n → space, \r and BEL dropped
    st.insert("cd"); // 'c' fits, 'd' would overflow → dropped
    try std.testing.expectEqualStrings("a bc", st.text());
}

test "handleKey covers the standard bindings" {
    var buf: [64]u8 = undefined;
    var st = State.init(&buf);

    try std.testing.expect(st.handleKey(.{ .codepoint = 'h' }));
    try std.testing.expect(st.handleKey(.{ .codepoint = 'i' }));
    try std.testing.expectEqualStrings("hi", st.text());

    try std.testing.expect(st.handleKey(.{ .codepoint = Key.left }));
    try std.testing.expect(st.handleKey(.{ .codepoint = Key.backspace }));
    try std.testing.expectEqualStrings("i", st.text());

    try std.testing.expect(st.handleKey(.{ .codepoint = 'a', .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(@as(usize, 0), st.cursor);
    try std.testing.expect(st.handleKey(.{ .codepoint = Key.delete }));
    try std.testing.expectEqualStrings("", st.text());

    // not ours: releases, chords, functional keys
    try std.testing.expect(!st.handleKey(.{ .codepoint = 'x', .kind = .release }));
    try std.testing.expect(!st.handleKey(.{ .codepoint = 'x', .mods = .{ .alt = true } }));
    try std.testing.expect(!st.handleKey(.{ .codepoint = Key.f(5) }));
    try std.testing.expectEqualStrings("", st.text());
}

test "draw renders, places the cursor, and shows the placeholder" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 10, 1);
    defer s.deinit(gpa);

    var buf: [64]u8 = undefined;
    var st = State.init(&buf);
    const tf: TextField = .{ .placeholder = "soek…" };

    var cur = tf.draw(Region.full(&s), &st).?;
    try std.testing.expectEqualStrings("s", s.cellAt(0, 0).?.grapheme());
    try std.testing.expect(s.cellAt(0, 0).?.style.attrs.dim);
    try std.testing.expectEqual(@as(u16, 0), cur.x);

    s.clear();
    st.insert("a宽b");
    cur = tf.draw(Region.full(&s), &st).?;
    try std.testing.expectEqualStrings("a", s.cellAt(0, 0).?.grapheme());
    try std.testing.expectEqualStrings("宽", s.cellAt(1, 0).?.grapheme());
    try std.testing.expectEqualStrings("b", s.cellAt(3, 0).?.grapheme());
    try std.testing.expectEqual(@as(u16, 4), cur.x); // after 1+2+1 columns

    // offset region: cursor comes back surface-absolute
    const r = Region.init(&s, .{ .x = 3, .y = 0, .width = 6, .height = 1 });
    cur = tf.draw(r, &st).?;
    try std.testing.expectEqual(@as(u16, 7), cur.x);

    // empty region: nothing to draw, no cursor
    const none = Region.init(&s, .{ .x = 0, .y = 5, .width = 4, .height = 1 });
    try std.testing.expectEqual(@as(?Cursor, null), tf.draw(none, &st));
}

test "horizontal scroll keeps the cursor visible" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 5, 1);
    defer s.deinit(gpa);

    var buf: [64]u8 = undefined;
    var st = State.init(&buf);
    st.insert("abcdefgh"); // cursor at the end, 8 columns into a 5-wide field
    const tf: TextField = .{};

    var cur = tf.draw(Region.full(&s), &st).?;
    // window scrolled: "efgh" visible, cursor on the last free column
    try std.testing.expectEqualStrings("e", s.cellAt(0, 0).?.grapheme());
    try std.testing.expectEqual(@as(u16, 4), cur.x);
    try std.testing.expectEqual(@as(usize, 4), st.scroll);

    // move home: window snaps back
    st.cursor = 0;
    s.clear();
    cur = tf.draw(Region.full(&s), &st).?;
    try std.testing.expectEqual(@as(usize, 0), st.scroll);
    try std.testing.expectEqualStrings("a", s.cellAt(0, 0).?.grapheme());
    try std.testing.expectEqual(@as(u16, 0), cur.x);

    // wide graphemes scroll by whole units
    st.clear();
    st.insert("宽宽宽宽");
    cur = tf.draw(Region.full(&s), &st).?;
    try std.testing.expectEqual(@as(u16, 4), cur.x); // 2 glyphs visible, cursor after them
    try std.testing.expectEqualStrings("宽", s.cellAt(0, 0).?.grapheme());
}
