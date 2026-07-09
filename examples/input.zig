//! An editable single-line text field — the terminal layer's dogfood test.
//! Exercises grapheme-aware editing (é, 宽, 👍 move/delete as units),
//! per-frame cursor positioning with a bar shape, kitty + legacy keys,
//! and bracketed paste. Quit with Escape or ctrl+c.
const std = @import("std");
const tuiste = @import("tuiste");

pub const panic = tuiste.panic;

/// A single-line editor over a fixed buffer. The cursor is a byte offset,
/// always kept on a grapheme boundary.
const Field = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,

    fn text(self: *const Field) []const u8 {
        return self.buf[0..self.len];
    }

    fn insert(self: *Field, bytes: []const u8) void {
        if (self.len + bytes.len > self.buf.len) return; // full: drop input
        std.mem.copyBackwards(
            u8,
            self.buf[self.cursor + bytes.len .. self.len + bytes.len],
            self.buf[self.cursor..self.len],
        );
        @memcpy(self.buf[self.cursor..][0..bytes.len], bytes);
        self.len += bytes.len;
        self.cursor += bytes.len;
    }

    fn insertCodepoint(self: *Field, cp: u21) void {
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch return;
        self.insert(tmp[0..n]);
    }

    /// Byte offset of the grapheme boundary before the cursor.
    fn prevBoundary(self: *const Field) usize {
        var it = tuiste.unicode.graphemeIterator(self.buf[0..self.cursor]);
        var prev: usize = 0;
        while (it.next()) |g| prev = g.offset;
        return prev;
    }

    /// Byte offset of the grapheme boundary after the cursor.
    fn nextBoundary(self: *const Field) usize {
        var it = tuiste.unicode.graphemeIterator(self.buf[self.cursor..self.len]);
        const g = it.next() orelse return self.cursor;
        return self.cursor + g.len;
    }

    fn moveLeft(self: *Field) void {
        if (self.cursor > 0) self.cursor = self.prevBoundary();
    }

    fn moveRight(self: *Field) void {
        if (self.cursor < self.len) self.cursor = self.nextBoundary();
    }

    fn backspace(self: *Field) void {
        if (self.cursor == 0) return;
        const start = self.prevBoundary();
        self.deleteRange(start, self.cursor);
        self.cursor = start;
    }

    fn deleteForward(self: *Field) void {
        if (self.cursor >= self.len) return;
        self.deleteRange(self.cursor, self.nextBoundary());
    }

    fn deleteRange(self: *Field, start: usize, end: usize) void {
        std.mem.copyForwards(u8, self.buf[start..], self.buf[end..self.len]);
        self.len -= end - start;
    }

    fn clear(self: *Field) void {
        self.len = 0;
        self.cursor = 0;
    }
};

/// A key event that should insert text: printable, unmodified, and not one
/// of the kitty functional keys (which live in the Private Use Area).
fn isText(k: tuiste.Key) bool {
    if (k.mods.ctrl or k.mods.alt or k.mods.super or k.mods.hyper or k.mods.meta) return false;
    if (k.codepoint < 0x20 or k.codepoint == 127) return false;
    if (k.codepoint >= 0xE000 and k.codepoint <= 0xF8FF) return false;
    return true;
}

pub fn main(init: std.process.Init) !void {
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_alloc.deinit();
    const gpa = debug_alloc.allocator();

    var term = try tuiste.Terminal.init(gpa, init.io, .{});
    defer term.deinit();

    var loop = try tuiste.Loop.init(&term.tty);
    _ = try term.detectCaps(&loop, 300);

    var field: Field = .{};
    var pasting = false;

    while (true) {
        var frame = term.frame();
        _ = frame.writeText(2, 1, "tuiste input example", .{ .attrs = .{ .bold = true } });
        _ = frame.writeText(2, 2, "arrows, home/end, backspace/delete, ctrl+u clears — esc or ctrl+c quits", .{ .fg = .{ .indexed = 244 } });

        _ = frame.writeText(2, 4, "> ", .{ .attrs = .{ .bold = true } });
        _ = frame.writeText(4, 4, field.text(), .{});

        var status_buf: [96]u8 = undefined;
        const status = std.fmt.bufPrint(&status_buf, "bytes: {d}   columns: {d}   cursor byte: {d}{s}", .{
            field.len,
            tuiste.unicode.strWidth(field.text()),
            field.cursor,
            if (pasting) "   [pasting]" else "",
        }) catch unreachable;
        _ = frame.writeText(2, 6, status, .{ .fg = .{ .indexed = 244 } });

        const cursor_col = 4 + tuiste.unicode.strWidth(field.buf[0..field.cursor]);
        term.setCursor(.{
            .x = @intCast(@min(cursor_col, frame.width -| 1)),
            .y = 4,
            .shape = .bar,
        });
        try term.render();

        const ev = (try loop.nextEvent(null)) orelse continue;
        switch (ev) {
            .key => |k| {
                if (k.kind == .release) continue;
                if (k.matches(tuiste.Key.escape, .{}) or k.matches('c', .{ .ctrl = true })) break;
                if (k.matches(tuiste.Key.left, .{})) {
                    field.moveLeft();
                } else if (k.matches(tuiste.Key.right, .{})) {
                    field.moveRight();
                } else if (k.matches(tuiste.Key.home, .{}) or k.matches('a', .{ .ctrl = true })) {
                    field.cursor = 0;
                } else if (k.matches(tuiste.Key.end, .{}) or k.matches('e', .{ .ctrl = true })) {
                    field.cursor = field.len;
                } else if (k.matches(tuiste.Key.backspace, .{})) {
                    field.backspace();
                } else if (k.matches(tuiste.Key.delete, .{})) {
                    field.deleteForward();
                } else if (k.matches('u', .{ .ctrl = true })) {
                    field.clear();
                } else if (isText(k)) {
                    field.insertCodepoint(k.codepoint);
                }
            },
            .paste_start => pasting = true,
            .paste_end => pasting = false,
            .resize => |size| try term.resize(size),
            else => {},
        }
    }
}
