//! A vertical list of single-line items with a selection highlight. The
//! widget is stateless like the rest of the layer; selection and scroll
//! live in a `List.State` the application owns and passes to `draw`, which
//! keeps the selection visible by adjusting the offset (and re-clamps both
//! against the current item count, so a shrinking list can't dangle).
const List = @This();

const std = @import("std");
const Region = @import("../Region.zig");
const Surface = @import("../Surface.zig");
const cell_mod = @import("../cell.zig");
const Cell = cell_mod.Cell;
const unicode = @import("../unicode.zig");
const Key = @import("../event.zig").Key;

/// One label per row; clipped at the region edge, never wrapped.
items: []const []const u8 = &.{},
opts: Surface.Options = .{},
/// The selected row's text style; the highlight spans the full row width.
selected_opts: Surface.Options = .{ .attrs = .{ .reverse = true } },
/// Prefix drawn before the selected item (e.g. "> "); other rows are
/// indented by its display width so the item column stays aligned.
marker: []const u8 = "",

/// Application-owned selection + scroll. Mutate it from the event handler
/// (`selectNext`/`selectPrev`, or set `selected` directly for mouse hits);
/// `draw` does the clamping and keeps the selection in view.
pub const State = struct {
    selected: ?usize = null,
    /// Index of the first visible item.
    offset: usize = 0,

    pub fn selectNext(self: *State, len: usize) void {
        if (len == 0) return;
        self.selected = if (self.selected) |s| @min(s + 1, len - 1) else 0;
    }

    pub fn selectPrev(self: *State, len: usize) void {
        if (len == 0) return;
        self.selected = if (self.selected) |s| s -| 1 else len - 1;
    }

    /// Standard navigation bindings (arrows, home/end) over `len` items.
    /// Returns whether the key was consumed — check application bindings
    /// first and fall through to this.
    pub fn handleKey(self: *State, k: Key, len: usize) bool {
        if (k.kind == .release) return false;
        if (k.matches(Key.up, .{})) {
            self.selectPrev(len);
        } else if (k.matches(Key.down, .{})) {
            self.selectNext(len);
        } else if (k.matches(Key.home, .{})) {
            if (len > 0) self.selected = 0;
        } else if (k.matches(Key.end, .{})) {
            if (len > 0) self.selected = len - 1;
        } else {
            return false;
        }
        return true;
    }
};

/// The item at region-relative `row`, or null past the last item — feed it
/// `m.row - region.rect.y` on mouse press.
pub fn hitTest(self: List, state: State, row: u16) ?usize {
    const i = state.offset + row;
    if (i >= self.items.len) return null;
    return i;
}

pub fn draw(self: List, region: Region, state: *State) void {
    const h: usize = region.height();
    if (h == 0 or region.width() == 0) return;
    const len = self.items.len;
    if (len == 0) {
        state.selected = null;
        state.offset = 0;
        return;
    }

    if (state.selected) |sel| {
        const s = @min(sel, len - 1);
        state.selected = s;
        // Scroll the window as far as needed to show the selection.
        if (s < state.offset) state.offset = s;
        if (s >= state.offset + h) state.offset = s - h + 1;
    }
    state.offset = @min(state.offset, len -| h);

    const indent: u16 = @intCast(@min(unicode.strWidth(self.marker), region.width()));

    var row: u16 = 0;
    while (row < h and state.offset + row < len) : (row += 1) {
        const i = state.offset + row;
        const is_selected = if (state.selected) |s| s == i else false;
        const o = if (is_selected) self.selected_opts else self.opts;
        if (is_selected) {
            // Paint the whole row first so the highlight spans the width.
            var bg: Cell = .{};
            bg.style = .{ .fg = o.fg, .bg = o.bg, .attrs = o.attrs };
            region.sub(.{ .y = row, .width = region.width(), .height = 1 }).fill(bg);
            _ = region.writeText(0, row, self.marker, o);
        }
        _ = region.writeText(indent, row, self.items[i], o);
    }
}

// --- tests ------------------------------------------------------------

fn testItems() []const []const u8 {
    return &.{ "een", "twee", "drie", "vier", "vyf", "ses" };
}

test "renders items and clips at the region height" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 8, 3);
    defer s.deinit(gpa);

    var state: State = .{};
    (List{ .items = testItems() }).draw(Region.full(&s), &state);
    try std.testing.expectEqualStrings("e", s.cellAt(0, 0).?.grapheme());
    try std.testing.expectEqualStrings("t", s.cellAt(0, 1).?.grapheme());
    try std.testing.expectEqualStrings("d", s.cellAt(0, 2).?.grapheme());
    try std.testing.expectEqual(@as(usize, 0), state.offset);
}

test "selection is highlighted across the full row" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 8, 3);
    defer s.deinit(gpa);

    var state: State = .{ .selected = 1 };
    (List{ .items = testItems() }).draw(Region.full(&s), &state);
    try std.testing.expect(s.cellAt(0, 1).?.style.attrs.reverse);
    try std.testing.expect(s.cellAt(7, 1).?.style.attrs.reverse); // past the text too
    try std.testing.expect(!s.cellAt(0, 0).?.style.attrs.reverse);
}

test "marker prefixes the selection and indents the rest" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 8, 2);
    defer s.deinit(gpa);

    var state: State = .{ .selected = 0 };
    (List{ .items = testItems(), .marker = "> " }).draw(Region.full(&s), &state);
    try std.testing.expectEqualStrings(">", s.cellAt(0, 0).?.grapheme());
    try std.testing.expectEqualStrings("e", s.cellAt(2, 0).?.grapheme());
    try std.testing.expectEqualStrings(" ", s.cellAt(0, 1).?.grapheme()); // aligned indent
    try std.testing.expectEqualStrings("t", s.cellAt(2, 1).?.grapheme());
}

test "draw scrolls to keep the selection visible" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 8, 3);
    defer s.deinit(gpa);
    const l: List = .{ .items = testItems() };

    // below the window: window slides down so it's the last visible row
    var state: State = .{ .selected = 4 };
    l.draw(Region.full(&s), &state);
    try std.testing.expectEqual(@as(usize, 2), state.offset);
    try std.testing.expectEqualStrings("v", s.cellAt(0, 2).?.grapheme()); // vyf

    // back above the window: window slides up to it
    state.selected = 0;
    s.clear();
    l.draw(Region.full(&s), &state);
    try std.testing.expectEqual(@as(usize, 0), state.offset);
    try std.testing.expectEqualStrings("e", s.cellAt(0, 0).?.grapheme());
}

test "stale state clamps when the list shrinks" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 8, 3);
    defer s.deinit(gpa);

    var state: State = .{ .selected = 99, .offset = 99 };
    (List{ .items = testItems()[0..2] }).draw(Region.full(&s), &state);
    try std.testing.expectEqual(@as(?usize, 1), state.selected);
    try std.testing.expectEqual(@as(usize, 0), state.offset);

    // empty list resets entirely and draws nothing
    (List{}).draw(Region.full(&s), &state);
    try std.testing.expectEqual(@as(?usize, null), state.selected);
    try std.testing.expectEqual(@as(usize, 0), state.offset);
}

test "handleKey covers navigation and reports consumption" {
    var state: State = .{ .selected = 1 };
    try std.testing.expect(state.handleKey(.{ .codepoint = Key.down }, 6));
    try std.testing.expectEqual(@as(?usize, 2), state.selected);
    try std.testing.expect(state.handleKey(.{ .codepoint = Key.home }, 6));
    try std.testing.expectEqual(@as(?usize, 0), state.selected);
    try std.testing.expect(state.handleKey(.{ .codepoint = Key.end, .mods = .{} }, 6));
    try std.testing.expectEqual(@as(?usize, 5), state.selected);
    // not ours: releases and unrelated keys fall through
    try std.testing.expect(!state.handleKey(.{ .codepoint = Key.up, .kind = .release }, 6));
    try std.testing.expect(!state.handleKey(.{ .codepoint = 'x' }, 6));
}

test "hitTest maps rows through the offset" {
    const l: List = .{ .items = testItems() };
    const state: State = .{ .offset = 2 };
    try std.testing.expectEqual(@as(?usize, 2), l.hitTest(state, 0));
    try std.testing.expectEqual(@as(?usize, 5), l.hitTest(state, 3));
    try std.testing.expectEqual(@as(?usize, null), l.hitTest(state, 4)); // past the end
}

test "state navigation clamps at the ends" {
    var state: State = .{};
    state.selectNext(3); // none → first
    try std.testing.expectEqual(@as(?usize, 0), state.selected);
    state.selectNext(3);
    state.selectNext(3);
    state.selectNext(3); // clamps at last
    try std.testing.expectEqual(@as(?usize, 2), state.selected);
    state.selectPrev(3);
    state.selectPrev(3);
    state.selectPrev(3); // clamps at first
    try std.testing.expectEqual(@as(?usize, 0), state.selected);

    var fresh: State = .{};
    fresh.selectPrev(3); // none → last
    try std.testing.expectEqual(@as(?usize, 2), fresh.selected);
    fresh.selectNext(0); // empty list: no-op
    fresh.selected = null;
    fresh.selectNext(0);
    try std.testing.expectEqual(@as(?usize, null), fresh.selected);
}
