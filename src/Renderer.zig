//! Double buffer + diff. Compares the freshly drawn back surface against the
//! front surface (what's on screen), emits the minimal escape output, and
//! copies changed cells forward. Allocation-free after init/resize.
const Renderer = @This();

const std = @import("std");
const Io = std.Io;
const Surface = @import("Surface.zig");
const cell_mod = @import("cell.zig");
const Cell = cell_mod.Cell;
const Style = cell_mod.Style;
const ctlseqs = @import("ctlseqs.zig");
const Caps = @import("caps.zig").Caps;
const GraphemePool = @import("GraphemePool.zig");

/// What is currently on screen.
front: Surface,
/// What user code draws into for the next frame (via `Terminal.frame`).
back: Surface,
/// Shared by both surfaces so pooled cells diff by index. Heap-allocated
/// because the surfaces hold pointers to it and Renderer moves by value.
pool: *GraphemePool,
/// Where the application wants the hardware cursor this frame; null means
/// hidden. Immediate-mode: `Terminal.frame` resets it, so it must be
/// re-requested every frame.
cursor_request: ?Cursor = null,
/// Whether the terminal is currently showing the cursor (what we last told
/// it), so render emits only transitions.
cursor_visible: bool = false,
/// Last DECSCUSR shape emitted; persistent terminal state, sent on change.
cursor_shape: Cursor.Shape = .default,
/// Scroll hints queued for the next render (see `pushScroll`).
scrolls: [max_scroll_hints]Scroll = undefined,
scroll_count: usize = 0,

pub const max_scroll_hints = 8;

/// A hint that a full-width band of the previous frame moved vertically —
/// e.g. a log pane scrolled while its status bar stayed put. Rows are
/// 0-based and inclusive.
pub const Scroll = struct {
    top: u16,
    bottom: u16,
    lines: u16,
    dir: Dir,

    pub const Dir = enum { up, down };
};

pub const Cursor = struct {
    x: u16,
    y: u16,
    shape: Shape = .default,

    /// DECSCUSR parameter values.
    pub const Shape = enum(u4) {
        default = 0,
        block_blink = 1,
        block = 2,
        underline_blink = 3,
        underline = 4,
        bar_blink = 5,
        bar = 6,
    };
};

/// A cell that can never equal a drawn cell (back cells always have len >= 1
/// except spacers, which carry width 0 in both buffers consistently).
const invalid_cell: Cell = .{ .len = 0, .width = 1 };

pub fn init(gpa: std.mem.Allocator, cols: u16, rows: u16) !Renderer {
    const pool = try gpa.create(GraphemePool);
    errdefer gpa.destroy(pool);
    pool.* = GraphemePool.init(gpa);
    errdefer pool.deinit();

    var front = try Surface.init(gpa, cols, rows);
    errdefer front.deinit(gpa);
    var back = try Surface.init(gpa, cols, rows);
    front.fill(invalid_cell);
    front.pool = pool;
    back.pool = pool;
    return .{ .front = front, .back = back, .pool = pool };
}

pub fn deinit(self: *Renderer, gpa: std.mem.Allocator) void {
    self.front.deinit(gpa);
    self.back.deinit(gpa);
    self.pool.deinit();
    gpa.destroy(self.pool);
    self.* = undefined;
}

pub fn resize(self: *Renderer, gpa: std.mem.Allocator, cols: u16, rows: u16) !void {
    try self.front.resize(gpa, cols, rows);
    try self.back.resize(gpa, cols, rows);
    self.invalidate();
}

/// Force the next render to redraw every cell.
pub fn invalidate(self: *Renderer) void {
    self.front.fill(invalid_cell);
}

/// Queue a scroll hint for the next render. Hints are a pure optimization:
/// one that is invalid, doesn't fit the queue, or is simply never sent
/// costs nothing but a larger diff — correctness never depends on them.
pub fn pushScroll(self: *Renderer, s: Scroll) void {
    if (s.lines == 0 or s.top > s.bottom or s.bottom >= self.front.height) return;
    if (self.scroll_count == self.scrolls.len) return;
    self.scrolls[self.scroll_count] = s;
    self.scroll_count += 1;
}

/// Replay one hint: DECSTBM + SU/SD on the terminal, the same row motion
/// mirrored in the front buffer. Exposed rows become invalid cells so the
/// diff repaints them regardless of what the terminal filled them with
/// (background-color-erase behavior varies). Returns whether escapes were
/// emitted (margins then need resetting).
fn applyScroll(self: *Renderer, writer: *Io.Writer, s: Scroll) !bool {
    const w: usize = self.front.width;
    const top: usize = s.top;
    const region_rows: usize = s.bottom - s.top + 1;

    if (s.lines >= region_rows) {
        // Nothing survives the scroll; just force a repaint of the region.
        @memset(self.front.cells[top * w .. (top + region_rows) * w], invalid_cell);
        return false;
    }

    try ctlseqs.setScrollRegion(writer, s.top + 1, s.bottom + 1);
    const keep = (region_rows - s.lines) * w;
    switch (s.dir) {
        .up => {
            try ctlseqs.scrollUp(writer, s.lines);
            std.mem.copyForwards(
                Cell,
                self.front.cells[top * w ..][0..keep],
                self.front.cells[(top + s.lines) * w ..][0..keep],
            );
            @memset(self.front.cells[top * w + keep ..][0 .. s.lines * w], invalid_cell);
        },
        .down => {
            try ctlseqs.scrollDown(writer, s.lines);
            std.mem.copyBackwards(
                Cell,
                self.front.cells[(top + s.lines) * w ..][0..keep],
                self.front.cells[top * w ..][0..keep],
            );
            @memset(self.front.cells[top * w ..][0 .. s.lines * w], invalid_cell);
        },
    }
    return true;
}

/// Diff back against front and write the delta. The caller flushes.
pub fn render(self: *Renderer, writer: *Io.Writer, caps: Caps) !void {
    if (caps.synchronized_output) try writer.writeAll(ctlseqs.sync_begin);

    // Hide a visible cursor while painting so it doesn't ride the diff.
    if (self.cursor_visible) {
        try writer.writeAll(ctlseqs.hide_cursor);
        self.cursor_visible = false;
    }

    // Replay scroll hints before diffing, so moved rows compare equal.
    if (self.scroll_count > 0) {
        var emitted = false;
        for (self.scrolls[0..self.scroll_count]) |s| {
            if (try self.applyScroll(writer, s)) emitted = true;
        }
        self.scroll_count = 0;
        if (emitted) try writer.writeAll(ctlseqs.margins_reset);
    }

    var last_style: ?Style = null;
    // The link the terminal currently has open (Cell.link encoding, 0 = none).
    var last_link: u32 = 0;
    // Cursor position after the last write; start impossible to force a CUP.
    var cx: u32 = std.math.maxInt(u32);
    var cy: u32 = std.math.maxInt(u32);

    var y: u16 = 0;
    while (y < self.back.height) : (y += 1) {
        var x: u16 = 0;
        while (x < self.back.width) : (x += 1) {
            const b = self.back.cellAt(x, y).?.*;
            const f = self.front.cellAt(x, y).?;
            if (b.eql(f.*)) continue;
            f.* = b;
            // Spacers carry no glyph; the wide cell to their left draws them.
            if (b.width == 0) continue;

            if (cx != x or cy != y) try ctlseqs.cup(writer, y + 1, x + 1);
            if (last_style == null or !last_style.?.eql(b.style)) {
                try ctlseqs.sgr(writer, b.style);
                last_style = b.style;
            }
            if (b.link != last_link) {
                // A link only scopes cells written while it is open; skipped
                // (unchanged) cells keep whatever link they already carry.
                if (b.link == 0) {
                    try writer.writeAll(ctlseqs.hyperlink_end);
                } else {
                    // Without an explicit id, derive one from the pool index
                    // (stable per URI), so cells of one link repainted in
                    // different frames still hover as a single link. The `~`
                    // prefix is banned in explicit ids — no collisions.
                    var id_buf: [16]u8 = undefined;
                    const id = self.back.linkIdOf(b) orelse
                        (std.fmt.bufPrint(&id_buf, "~{d}", .{b.link - 1}) catch unreachable);
                    try ctlseqs.hyperlinkStart(writer, id, self.back.linkOf(b).?);
                }
                last_link = b.link;
            }
            const bytes = self.back.graphemeOf(b);
            try writer.writeAll(bytes);
            // Terminals disagree with our width model exactly on
            // multi-codepoint clusters (ZWJ emoji drawn unmerged, combining
            // marks, VS16 variants). After one, assume nothing about where
            // the cursor landed: the next cell gets an explicit CUP, so a
            // disagreement can never shift the rest of the run — at worst
            // the cluster itself draws too wide and is overlapped by the
            // correctly-placed neighbors.
            const lead_len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch 1;
            if (lead_len == bytes.len) {
                cx = @as(u32, x) + b.width;
                cy = y;
            } else {
                cx = std.math.maxInt(u32);
            }
        }
    }

    if (last_link != 0) try writer.writeAll(ctlseqs.hyperlink_end);
    if (last_style != null) try writer.writeAll(ctlseqs.sgr_reset);

    // Park the cursor where this frame requested it. Out-of-bounds
    // requests stay hidden rather than showing a cursor somewhere wrong.
    if (self.cursor_request) |req| {
        if (req.x < self.back.width and req.y < self.back.height) {
            if (req.shape != self.cursor_shape) {
                try ctlseqs.cursorShape(writer, @intFromEnum(req.shape));
                self.cursor_shape = req.shape;
            }
            try ctlseqs.cup(writer, req.y + 1, req.x + 1);
            try writer.writeAll(ctlseqs.show_cursor);
            self.cursor_visible = true;
        }
    }

    if (caps.synchronized_output) try writer.writeAll(ctlseqs.sync_end);
}

test "render diffs only changed cells" {
    const gpa = std.testing.allocator;
    var r = try Renderer.init(gpa, 4, 2);
    defer r.deinit(gpa);

    // First frame: everything invalid → full paint of the (blank) back buffer.
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try r.render(&w, .{});
    try std.testing.expect(w.buffered().len > 0);

    // Nothing changed → nothing emitted.
    var w2: Io.Writer = .fixed(&buf);
    try r.render(&w2, .{});
    try std.testing.expectEqualStrings("", w2.buffered());

    // One cell changed → exactly one CUP, one glyph.
    _ = r.back.writeText(1, 1, "A", .{});
    var w3: Io.Writer = .fixed(&buf);
    try r.render(&w3, .{});
    const out = w3.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[2;2H") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "A") != null);
}

test "pooled graphemes render full bytes and diff stable" {
    const gpa = std.testing.allocator;
    var r = try Renderer.init(gpa, 6, 1);
    defer r.deinit(gpa);

    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try r.render(&w, .{}); // settle first frame

    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}";
    _ = r.back.writeText(0, 0, family, .{});
    var w2: Io.Writer = .fixed(&buf);
    try r.render(&w2, .{});
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), family) != null);

    // Redrawing the identical frame emits nothing: pooled cells diff by index.
    r.back.clear();
    _ = r.back.writeText(0, 0, family, .{});
    var w3: Io.Writer = .fixed(&buf);
    try r.render(&w3, .{});
    try std.testing.expectEqualStrings("", w3.buffered());
}

test "multi-codepoint clusters force a reposition before the next cell" {
    const gpa = std.testing.allocator;
    var r = try Renderer.init(gpa, 10, 1);
    defer r.deinit(gpa);

    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try r.render(&w, .{}); // settle

    // family emoji (cells 0-1), then 'a' at cell 2: same contiguous run,
    // but the terminal may draw the emoji wider than 2 cells, so 'a' must
    // be placed with an explicit CUP, never by trusting the cursor.
    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}";
    _ = r.back.writeText(0, 0, family, .{});
    _ = r.back.writeText(2, 0, "ab", .{});
    var w2: Io.Writer = .fixed(&buf);
    try r.render(&w2, .{});
    const out = w2.buffered();
    const emoji_at = std.mem.indexOf(u8, out, family).?;
    try std.testing.expect(std.mem.indexOf(u8, out[emoji_at + family.len ..], "\x1b[1;3H") != null);

    // single-codepoint neighbors still coalesce into one unpositioned run
    try std.testing.expect(std.mem.indexOf(u8, out, "ab") != null);
}

test "hyperlinked cells emit OSC 8 open and close" {
    const gpa = std.testing.allocator;
    var r = try Renderer.init(gpa, 12, 1);
    defer r.deinit(gpa);

    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try r.render(&w, .{}); // settle first frame

    _ = r.back.writeText(0, 0, "zig", .{ .link = "https://ziglang.org" });
    _ = r.back.writeText(3, 0, "!", .{});
    var w2: Io.Writer = .fixed(&buf);
    try r.render(&w2, .{});
    const out = w2.buffered();
    // first pool entry → derived id ~0
    const open = std.mem.indexOf(u8, out, "\x1b]8;id=~0;https://ziglang.org\x1b\\").?;
    const close = std.mem.indexOf(u8, out, ctlseqs.hyperlink_end).?;
    try std.testing.expect(open < close);
    // the unlinked "!" closed the link mid-diff, so no trailing close needed
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, ctlseqs.hyperlink_end));

    // identical frame: linked cells diff by index, nothing emitted
    r.back.clear();
    _ = r.back.writeText(0, 0, "zig", .{ .link = "https://ziglang.org" });
    _ = r.back.writeText(3, 0, "!", .{});
    var w3: Io.Writer = .fixed(&buf);
    try r.render(&w3, .{});
    try std.testing.expectEqualStrings("", w3.buffered());
}

test "explicit link ids are emitted and separate same-URI links" {
    const gpa = std.testing.allocator;
    var r = try Renderer.init(gpa, 8, 1);
    defer r.deinit(gpa);

    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try r.render(&w, .{}); // settle

    _ = r.back.writeText(0, 0, "a", .{ .link = "https://ziglang.org", .link_id = "one" });
    _ = r.back.writeText(1, 0, "b", .{ .link = "https://ziglang.org", .link_id = "two" });
    var w2: Io.Writer = .fixed(&buf);
    try r.render(&w2, .{});
    const out = w2.buffered();
    // distinct ids are distinct link identities: both openers emitted
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b]8;id=one;https://ziglang.org\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b]8;id=two;https://ziglang.org\x1b\\") != null);
}

test "a link open at the end of the diff is closed" {
    const gpa = std.testing.allocator;
    var r = try Renderer.init(gpa, 4, 1);
    defer r.deinit(gpa);

    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try r.render(&w, .{}); // settle

    // linked text reaching the last diffed cell — nothing after it to close
    _ = r.back.writeText(2, 0, "ab", .{ .link = "https://ziglang.org" });
    var w2: Io.Writer = .fixed(&buf);
    try r.render(&w2, .{});
    const out = w2.buffered();
    try std.testing.expect(std.mem.endsWith(
        u8,
        out[0 .. std.mem.lastIndexOf(u8, out, ctlseqs.sgr_reset).?],
        ctlseqs.hyperlink_end,
    ));
}

test "scroll hint moves rows and repaints only the exposed line" {
    const gpa = std.testing.allocator;
    var r = try Renderer.init(gpa, 4, 4);
    defer r.deinit(gpa);

    var buf: [8192]u8 = undefined;
    // Frame 1: a/b/c in the scroll band, d as the fixed status row.
    for ([_][]const u8{ "aaaa", "bbbb", "cccc", "dddd" }, 0..) |row, y|
        _ = r.back.writeText(0, @intCast(y), row, .{});
    var w: Io.Writer = .fixed(&buf);
    try r.render(&w, .{});

    // Frame 2: band scrolled up one; "nnnn" is the new bottom line.
    r.back.clear();
    for ([_][]const u8{ "bbbb", "cccc", "nnnn", "dddd" }, 0..) |row, y|
        _ = r.back.writeText(0, @intCast(y), row, .{});
    r.pushScroll(.{ .top = 0, .bottom = 2, .lines = 1, .dir = .up });
    var w2: Io.Writer = .fixed(&buf);
    try r.render(&w2, .{});
    const out = w2.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[1;3r") != null); // DECSTBM
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[1S") != null); // scroll up
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[r") != null); // margins reset
    try std.testing.expect(std.mem.indexOf(u8, out, "n") != null); // exposed line painted
    // moved rows and the status row compare equal — never repainted
    try std.testing.expect(std.mem.indexOf(u8, out, "b") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "c") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "d") == null);
}

test "scroll down exposes the top line" {
    const gpa = std.testing.allocator;
    var r = try Renderer.init(gpa, 4, 3);
    defer r.deinit(gpa);

    var buf: [8192]u8 = undefined;
    for ([_][]const u8{ "aaaa", "bbbb", "cccc" }, 0..) |row, y|
        _ = r.back.writeText(0, @intCast(y), row, .{});
    var w: Io.Writer = .fixed(&buf);
    try r.render(&w, .{});

    r.back.clear();
    for ([_][]const u8{ "nnnn", "aaaa", "bbbb" }, 0..) |row, y|
        _ = r.back.writeText(0, @intCast(y), row, .{});
    r.pushScroll(.{ .top = 0, .bottom = 2, .lines = 1, .dir = .down });
    var w2: Io.Writer = .fixed(&buf);
    try r.render(&w2, .{});
    const out = w2.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[1T") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "a") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "b") == null);
}

test "oversized and invalid scroll hints degrade to plain diff" {
    const gpa = std.testing.allocator;
    var r = try Renderer.init(gpa, 4, 3);
    defer r.deinit(gpa);

    var buf: [8192]u8 = undefined;
    _ = r.back.writeText(0, 0, "aaaa", .{});
    var w: Io.Writer = .fixed(&buf);
    try r.render(&w, .{});

    // lines >= region height: no escapes, region just repaints
    r.back.clear();
    _ = r.back.writeText(0, 0, "aaaa", .{});
    r.pushScroll(.{ .top = 0, .bottom = 1, .lines = 5, .dir = .up });
    var w2: Io.Writer = .fixed(&buf);
    try r.render(&w2, .{});
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), "r") == null);
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), "a") != null);

    // bottom out of bounds: rejected at push time, render unaffected
    r.pushScroll(.{ .top = 0, .bottom = 99, .lines = 1, .dir = .up });
    try std.testing.expectEqual(@as(usize, 0), r.scroll_count);
}

test "cursor request shows, moves, hides, and tracks shape" {
    const gpa = std.testing.allocator;
    var r = try Renderer.init(gpa, 10, 3);
    defer r.deinit(gpa);

    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try r.render(&w, .{}); // settle; no request → no cursor traffic
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), ctlseqs.show_cursor) == null);

    // request with a shape: expect DECSCUSR + CUP + show
    r.cursor_request = .{ .x = 4, .y = 1, .shape = .bar };
    var w2: Io.Writer = .fixed(&buf);
    try r.render(&w2, .{});
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), "\x1b[6 q") != null);
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), "\x1b[2;5H") != null);
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), ctlseqs.show_cursor) != null);

    // same shape again: no DECSCUSR re-emit, but hide-then-reshow around paint
    r.cursor_request = .{ .x = 5, .y = 1, .shape = .bar };
    var w3: Io.Writer = .fixed(&buf);
    try r.render(&w3, .{});
    try std.testing.expect(std.mem.indexOf(u8, w3.buffered(), "\x1b[6 q") == null);
    try std.testing.expect(std.mem.indexOf(u8, w3.buffered(), "\x1b[2;6H") != null);

    // no request (Terminal.frame clears it): exactly one hide, then silence
    r.cursor_request = null;
    var w4: Io.Writer = .fixed(&buf);
    try r.render(&w4, .{});
    try std.testing.expectEqualStrings(ctlseqs.hide_cursor, w4.buffered());
    var w5: Io.Writer = .fixed(&buf);
    try r.render(&w5, .{});
    try std.testing.expectEqualStrings("", w5.buffered());
}

test "out-of-bounds cursor request stays hidden" {
    const gpa = std.testing.allocator;
    var r = try Renderer.init(gpa, 4, 2);
    defer r.deinit(gpa);

    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try r.render(&w, .{}); // settle

    r.cursor_request = .{ .x = 4, .y = 0 }; // x == width: one past the edge
    var w2: Io.Writer = .fixed(&buf);
    try r.render(&w2, .{});
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), ctlseqs.show_cursor) == null);
}

test "adjacent cells reuse cursor position" {
    const gpa = std.testing.allocator;
    var r = try Renderer.init(gpa, 8, 1);
    defer r.deinit(gpa);

    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try r.render(&w, .{}); // settle first frame

    _ = r.back.writeText(2, 0, "ab", .{});
    var w2: Io.Writer = .fixed(&buf);
    try r.render(&w2, .{});
    // one cursor move for the run of two cells
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, w2.buffered(), "\x1b["[0..2]) - std.mem.count(u8, w2.buffered(), "\x1b[0"),
    );
}
