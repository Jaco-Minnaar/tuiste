//! Every escape sequence the library emits, in one place. If a terminal
//! quirk ever needs a different byte sequence, this is the only file to touch.
const std = @import("std");
const Io = std.Io;
const cell_mod = @import("cell.zig");
const Style = cell_mod.Style;

pub const enter_alt_screen = "\x1b[?1049h";
pub const exit_alt_screen = "\x1b[?1049l";
pub const hide_cursor = "\x1b[?25l";
pub const show_cursor = "\x1b[?25h";
pub const clear_screen = "\x1b[2J";
pub const cursor_home = "\x1b[H";
pub const sgr_reset = "\x1b[0m";

/// Synchronized output (mode 2026): terminal applies the whole frame at once.
pub const sync_begin = "\x1b[?2026h";
pub const sync_end = "\x1b[?2026l";

pub const bracketed_paste_on = "\x1b[?2004h";
pub const bracketed_paste_off = "\x1b[?2004l";

/// Button-event mouse tracking + SGR encoding.
pub const mouse_on = "\x1b[?1002h\x1b[?1006h";
pub const mouse_off = "\x1b[?1006l\x1b[?1002l";

pub const focus_on = "\x1b[?1004h";
pub const focus_off = "\x1b[?1004l";

/// Kitty keyboard: push "disambiguate escape codes" (progressive flag 1).
/// Terminals that don't know the protocol ignore both sequences.
pub const kitty_kb_push = "\x1b[>1u";
pub const kitty_kb_pop = "\x1b[<u";
pub const kitty_kb_query = "\x1b[?u";

/// DECRQM: ask whether synchronized output (mode 2026) is supported.
pub const sync_query = "\x1b[?2026$p";

/// XTGETTCAP for the terminfo caps "RGB" and "Tc" (hex-encoded): a positive
/// reply to either confirms truecolor.
pub const truecolor_query = "\x1bP+q524742;5463\x1b\\";

pub const da1_request = "\x1b[c";

/// DECSCUSR: reset the cursor shape to the terminal's default.
pub const cursor_shape_reset = "\x1b[0 q";

/// DECSTBM: reset the scroll margins to the full screen.
pub const margins_reset = "\x1b[r";

/// DECSTBM: confine scrolling to the 1-based rows [top, bottom].
pub fn setScrollRegion(writer: *Io.Writer, top: u16, bottom: u16) Io.Writer.Error!void {
    try writer.print("\x1b[{d};{d}r", .{ top, bottom });
}

/// SU: scroll the region up n lines (content moves up, blanks appear at the bottom).
pub fn scrollUp(writer: *Io.Writer, n: u16) Io.Writer.Error!void {
    try writer.print("\x1b[{d}S", .{n});
}

/// SD: scroll the region down n lines (content moves down, blanks appear at the top).
pub fn scrollDown(writer: *Io.Writer, n: u16) Io.Writer.Error!void {
    try writer.print("\x1b[{d}T", .{n});
}

/// Move the cursor to 1-based (row, col).
pub fn cup(writer: *Io.Writer, row: u16, col: u16) Io.Writer.Error!void {
    try writer.print("\x1b[{d};{d}H", .{ row, col });
}

/// DECSCUSR: set the cursor shape (note the space before the final q).
pub fn cursorShape(writer: *Io.Writer, shape: u4) Io.Writer.Error!void {
    try writer.print("\x1b[{d} q", .{shape});
}

/// OSC 8: everything written after this links to `uri`, until closed.
/// Cells carrying the same uri *and* a same non-empty `id` are one link to
/// the terminal (hover highlights them together even when emitted apart);
/// an empty id omits the parameter. Terminals without hyperlink support
/// ignore the OSC and show plain text.
pub fn hyperlinkStart(writer: *Io.Writer, id: []const u8, uri: []const u8) Io.Writer.Error!void {
    if (id.len > 0) {
        try writer.print("\x1b]8;id={s};{s}\x1b\\", .{ id, uri });
    } else {
        try writer.print("\x1b]8;;{s}\x1b\\", .{uri});
    }
}

/// OSC 8 with an empty URI: close the open hyperlink.
pub const hyperlink_end = "\x1b]8;;\x1b\\";

/// OSC 52: write `text` to a system selection, base64-encoded. `dest` is
/// the selection byte: 'c' clipboard, 'p' primary. Encoded in 48-byte
/// chunks (64 output chars, padding only in the last) so any length streams
/// without allocating.
pub fn osc52Copy(writer: *Io.Writer, dest: u8, text: []const u8) Io.Writer.Error!void {
    try writer.print("\x1b]52;{c};", .{dest});
    const encoder = std.base64.standard.Encoder;
    var i: usize = 0;
    while (i < text.len) : (i += 48) {
        var out: [64]u8 = undefined;
        try writer.writeAll(encoder.encode(&out, text[i..@min(i + 48, text.len)]));
    }
    try writer.writeAll("\x1b\\");
}

/// Emit the full SGR state for `style`, starting from a reset so no prior
/// attribute leaks through.
pub fn sgr(writer: *Io.Writer, style: Style) Io.Writer.Error!void {
    try writer.writeAll("\x1b[0");
    if (style.attrs.bold) try writer.writeAll(";1");
    if (style.attrs.dim) try writer.writeAll(";2");
    if (style.attrs.italic) try writer.writeAll(";3");
    if (style.attrs.underline) try writer.writeAll(";4");
    if (style.attrs.blink) try writer.writeAll(";5");
    if (style.attrs.reverse) try writer.writeAll(";7");
    if (style.attrs.hidden) try writer.writeAll(";8");
    if (style.attrs.strikethrough) try writer.writeAll(";9");
    switch (style.fg) {
        .default => {},
        .ansi => |n| try writer.print(";{d}", .{if (n < 8) 30 + @as(u8, n) else 90 + @as(u8, n) - 8}),
        .indexed => |n| try writer.print(";38;5;{d}", .{n}),
        .rgb => |c| try writer.print(";38;2;{d};{d};{d}", .{ c[0], c[1], c[2] }),
    }
    switch (style.bg) {
        .default => {},
        .ansi => |n| try writer.print(";{d}", .{if (n < 8) 40 + @as(u8, n) else 100 + @as(u8, n) - 8}),
        .indexed => |n| try writer.print(";48;5;{d}", .{n}),
        .rgb => |c| try writer.print(";48;2;{d};{d};{d}", .{ c[0], c[1], c[2] }),
    }
    try writer.writeByte('m');
}

test "osc52 base64-encodes the payload" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try osc52Copy(&w, 'c', "hello");
    try std.testing.expectEqualStrings("\x1b]52;c;aGVsbG8=\x1b\\", w.buffered());

    // empty text still produces a well-formed (clearing) sequence
    var w2: Io.Writer = .fixed(&buf);
    try osc52Copy(&w2, 'c', "");
    try std.testing.expectEqualStrings("\x1b]52;c;\x1b\\", w2.buffered());

    // multi-chunk payload: padding appears only at the very end
    var w3: Io.Writer = .fixed(&buf);
    try osc52Copy(&w3, 'p', "a" ** 49);
    var expect_buf: [128]u8 = undefined;
    const expect = std.base64.standard.Encoder.encode(&expect_buf, "a" ** 49);
    try std.testing.expectEqualStrings(expect, w3.buffered()[7 .. w3.buffered().len - 2]);
}

test "sgr emits reset plus attributes" {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try sgr(&w, .{ .fg = .{ .rgb = .{ 255, 0, 128 } }, .attrs = .{ .bold = true } });
    try std.testing.expectEqualStrings("\x1b[0;1;38;2;255;0;128m", w.buffered());
}

test "sgr bright ansi colors" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try sgr(&w, .{ .fg = .{ .ansi = 9 }, .bg = .{ .ansi = 2 } });
    try std.testing.expectEqualStrings("\x1b[0;91;42m", w.buffered());
}
