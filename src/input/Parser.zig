//! Pure byte-stream → Event state machine. No I/O: it is fed bytes and
//! returns events, which keeps the entire input matrix unit-testable.
//!
//! Handles: UTF-8 ground keys, C0 controls, alt-prefixed keys, SS3 (ESC O),
//! legacy CSI keys, kitty keyboard `CSI u`, SGR mouse, focus, and the
//! bracketed-paste delimiters.
const Parser = @This();

const std = @import("std");
const event = @import("../event.zig");
const Event = event.Event;
const Key = event.Key;
const Mods = event.Mods;
const Mouse = event.Mouse;

// No state yet: every supported sequence parses from a byte slice alone.
// The struct exists so paste-mode and grapheme state can live here later.

pub const Result = struct {
    event: ?Event,
    /// Bytes consumed. 0 means "incomplete — feed more input".
    /// consumed > 0 with a null event means "recognized and ignored".
    consumed: usize,
};

/// Parse one event from the front of `input`. `more` signals that further
/// bytes are known to be pending, which disambiguates a lone ESC.
pub fn parse(self: *Parser, input: []const u8, more: bool) Result {
    _ = self;
    std.debug.assert(input.len > 0);
    if (input[0] == 0x1b) return parseEscape(input, more);
    return parseGround(input);
}

fn keyEvent(k: Key, consumed: usize) Result {
    return .{ .event = .{ .key = k }, .consumed = consumed };
}

/// A key outside any escape sequence: C0 control or UTF-8 text.
fn parseGround(input: []const u8) Result {
    const b = input[0];
    switch (b) {
        Key.tab => return keyEvent(.{ .codepoint = Key.tab }, 1),
        Key.enter => return keyEvent(.{ .codepoint = Key.enter }, 1),
        Key.backspace => return keyEvent(.{ .codepoint = Key.backspace }, 1),
        0 => return keyEvent(.{ .codepoint = Key.space, .mods = .{ .ctrl = true } }, 1),
        1...8, 10...12, 14...26 => return keyEvent(
            .{ .codepoint = 'a' + @as(u21, b) - 1, .mods = .{ .ctrl = true } },
            1,
        ),
        else => {},
    }
    const len = std.unicode.utf8ByteSequenceLength(b) catch {
        return .{ .event = null, .consumed = 1 }; // invalid lead byte: drop it
    };
    if (input.len < len) return .{ .event = null, .consumed = 0 };
    const cp = std.unicode.utf8Decode(input[0..len]) catch {
        return .{ .event = null, .consumed = 1 };
    };
    return keyEvent(.{ .codepoint = cp }, len);
}

fn parseEscape(input: []const u8, more: bool) Result {
    if (input.len == 1) {
        if (more) return .{ .event = null, .consumed = 0 };
        return keyEvent(.{ .codepoint = Key.escape }, 1);
    }
    switch (input[1]) {
        '[' => return parseCsi(input),
        'O' => {
            // SS3: F1–F4 and application-mode cursor keys.
            if (input.len < 3) return .{ .event = null, .consumed = 0 };
            const cp: ?u21 = switch (input[2]) {
                'P' => Key.f(1),
                'Q' => Key.f(2),
                'R' => Key.f(3),
                'S' => Key.f(4),
                'A' => Key.up,
                'B' => Key.down,
                'C' => Key.right,
                'D' => Key.left,
                'H' => Key.home,
                'F' => Key.end,
                else => null,
            };
            if (cp) |c| return keyEvent(.{ .codepoint = c }, 3);
            return .{ .event = null, .consumed = 3 };
        },
        0x1b => return keyEvent(.{ .codepoint = Key.escape }, 1),
        else => {
            // ESC-prefixed ground key: alt modifier.
            const inner = parseGround(input[1..]);
            if (inner.consumed == 0) return .{ .event = null, .consumed = 0 };
            if (inner.event) |ev| {
                var k = ev.key;
                k.mods.alt = true;
                return keyEvent(k, 1 + inner.consumed);
            }
            return .{ .event = null, .consumed = 1 + inner.consumed };
        },
    }
}

/// Kitty encodes modifiers as (bitfield + 1); Mods is laid out in wire order.
fn modsFromParam(p: u21) Mods {
    if (p == 0) return .{};
    return @bitCast(@as(u8, @truncate(p - 1)));
}

fn kindFromParam(p: u21) event.KeyEventKind {
    return switch (p) {
        2 => .repeat,
        3 => .release,
        else => .press,
    };
}

/// Iterates `;`-separated CSI parameter groups; each group may carry
/// `:`-separated sub-parameters (kitty).
const ParamIter = struct {
    rest: []const u8,

    fn next(self: *ParamIter) ?[]const u8 {
        if (self.rest.len == 0) return null;
        const end = std.mem.indexOfScalar(u8, self.rest, ';') orelse {
            defer self.rest = self.rest[self.rest.len..];
            return self.rest;
        };
        defer self.rest = self.rest[end + 1 ..];
        return self.rest[0..end];
    }
};

fn subParam(group: []const u8, n: usize) ?u21 {
    var it = std.mem.splitScalar(u8, group, ':');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i == n) {
            if (part.len == 0) return null;
            return std.fmt.parseInt(u21, part, 10) catch null;
        }
    }
    return null;
}

fn parseCsi(input: []const u8) Result {
    // input starts with ESC [ — scan for the final byte (0x40–0x7E).
    var i: usize = 2;
    const end: usize = while (i < input.len) : (i += 1) {
        const b = input[i];
        if (b >= 0x40 and b <= 0x7e) break i;
        if (i > 64) return .{ .event = null, .consumed = i }; // runaway; drop
    } else return .{ .event = null, .consumed = 0 };

    const final = input[end];
    const consumed = end + 1;
    var params = input[2..end];

    switch (final) {
        'A', 'B', 'C', 'D', 'H', 'F' => {
            const cp: u21 = switch (final) {
                'A' => Key.up,
                'B' => Key.down,
                'C' => Key.right,
                'D' => Key.left,
                'H' => Key.home,
                else => Key.end,
            };
            var it: ParamIter = .{ .rest = params };
            _ = it.next(); // group 0 is always "1"
            const mod_group = it.next() orelse "";
            return keyEvent(.{
                .codepoint = cp,
                .mods = modsFromParam(subParam(mod_group, 0) orelse 1),
                .kind = kindFromParam(subParam(mod_group, 1) orelse 1),
            }, consumed);
        },
        '~' => {
            var it: ParamIter = .{ .rest = params };
            const num = subParam(it.next() orelse "", 0) orelse 0;
            switch (num) {
                200 => return .{ .event = .paste_start, .consumed = consumed },
                201 => return .{ .event = .paste_end, .consumed = consumed },
                else => {},
            }
            const cp: u21 = switch (num) {
                2 => Key.insert,
                3 => Key.delete,
                5 => Key.page_up,
                6 => Key.page_down,
                7 => Key.home,
                8 => Key.end,
                11...15 => Key.f(num - 10),
                17...21 => Key.f(num - 11),
                23, 24 => Key.f(num - 12),
                else => return .{ .event = null, .consumed = consumed },
            };
            const mod_group = it.next() orelse "";
            return keyEvent(.{
                .codepoint = cp,
                .mods = modsFromParam(subParam(mod_group, 0) orelse 1),
                .kind = kindFromParam(subParam(mod_group, 1) orelse 1),
            }, consumed);
        },
        'u' => {
            // Kitty: CSI codepoint[:shifted[:base]] ; mods[:event] u
            var it: ParamIter = .{ .rest = params };
            const key_group = it.next() orelse return .{ .event = null, .consumed = consumed };
            const cp = subParam(key_group, 0) orelse return .{ .event = null, .consumed = consumed };
            const mod_group = it.next() orelse "";
            return keyEvent(.{
                .codepoint = cp,
                .shifted = subParam(key_group, 1),
                .base = subParam(key_group, 2),
                .mods = modsFromParam(subParam(mod_group, 0) orelse 1),
                .kind = kindFromParam(subParam(mod_group, 1) orelse 1),
            }, consumed);
        },
        'I' => return .{ .event = .focus_in, .consumed = consumed },
        'O' => return .{ .event = .focus_out, .consumed = consumed },
        'M', 'm' => {
            if (params.len == 0 or params[0] != '<')
                return .{ .event = null, .consumed = consumed }; // X10 mouse etc.
            params = params[1..];
            var it: ParamIter = .{ .rest = params };
            const btn = subParam(it.next() orelse "", 0) orelse 0;
            const col = subParam(it.next() orelse "", 0) orelse 1;
            const row = subParam(it.next() orelse "", 0) orelse 1;

            var mods: Mods = .{};
            mods.shift = btn & 4 != 0;
            mods.alt = btn & 8 != 0;
            mods.ctrl = btn & 16 != 0;

            const button: event.MouseButton = if (btn & 64 != 0)
                (if (btn & 1 != 0) .wheel_down else .wheel_up)
            else switch (btn & 3) {
                0 => .left,
                1 => .middle,
                2 => .right,
                else => .none,
            };

            return .{ .event = .{ .mouse = .{
                .col = @intCast(@max(col, 1) - 1),
                .row = @intCast(@max(row, 1) - 1),
                .button = button,
                .kind = if (btn & 32 != 0) .motion else if (final == 'M') .press else .release,
                .mods = mods,
            } }, .consumed = consumed };
        },
        else => return .{ .event = null, .consumed = consumed },
    }
}

// --- tests ------------------------------------------------------------

fn expectKey(input: []const u8, expected: Key, consumed: usize) !void {
    var p: Parser = .{};
    const r = p.parse(input, false);
    try std.testing.expectEqual(consumed, r.consumed);
    try std.testing.expectEqualDeep(Event{ .key = expected }, r.event.?);
}

test "plain ascii key" {
    try expectKey("a", .{ .codepoint = 'a' }, 1);
}

test "utf-8 key" {
    try expectKey("👍", .{ .codepoint = 0x1F44D }, 4);
}

test "ctrl+letter C0 controls" {
    try expectKey("\x01", .{ .codepoint = 'a', .mods = .{ .ctrl = true } }, 1);
    try expectKey("\x03", .{ .codepoint = 'c', .mods = .{ .ctrl = true } }, 1);
    try expectKey("\t", .{ .codepoint = Key.tab }, 1);
    try expectKey("\r", .{ .codepoint = Key.enter }, 1);
}

test "lone escape vs pending bytes" {
    var p: Parser = .{};
    try std.testing.expectEqual(@as(usize, 0), p.parse("\x1b", true).consumed);
    try expectKey("\x1b", .{ .codepoint = Key.escape }, 1);
}

test "alt+key" {
    try expectKey("\x1bq", .{ .codepoint = 'q', .mods = .{ .alt = true } }, 2);
}

test "legacy arrows with and without modifiers" {
    try expectKey("\x1b[A", .{ .codepoint = Key.up }, 3);
    try expectKey("\x1b[1;5A", .{ .codepoint = Key.up, .mods = .{ .ctrl = true } }, 6);
}

test "legacy tilde keys" {
    try expectKey("\x1b[3~", .{ .codepoint = Key.delete }, 4);
    try expectKey("\x1b[5;2~", .{ .codepoint = Key.page_up, .mods = .{ .shift = true } }, 6);
}

test "ss3 function key" {
    try expectKey("\x1bOP", .{ .codepoint = Key.f(1) }, 3);
}

test "kitty CSI u key" {
    try expectKey("\x1b[97;5u", .{ .codepoint = 'a', .mods = .{ .ctrl = true } }, 7);
    // release event with shifted alternate: shift+a released
    try expectKey("\x1b[97:65;2:3u", .{
        .codepoint = 'a',
        .shifted = 'A',
        .mods = .{ .shift = true },
        .kind = .release,
    }, 12);
}

test "incomplete csi wants more bytes" {
    var p: Parser = .{};
    try std.testing.expectEqual(@as(usize, 0), p.parse("\x1b[1;5", false).consumed);
}

test "sgr mouse press and wheel" {
    var p: Parser = .{};
    const r = p.parse("\x1b[<0;10;5M", false);
    try std.testing.expectEqual(@as(usize, 10), r.consumed);
    try std.testing.expectEqualDeep(Event{ .mouse = .{
        .col = 9,
        .row = 4,
        .button = .left,
        .kind = .press,
    } }, r.event.?);

    const w = p.parse("\x1b[<64;1;1M", false);
    try std.testing.expectEqual(event.MouseButton.wheel_up, w.event.?.mouse.button);
}

test "focus and paste delimiters" {
    var p: Parser = .{};
    try std.testing.expectEqualDeep(Event.focus_in, p.parse("\x1b[I", false).event.?);
    try std.testing.expectEqualDeep(Event.paste_start, p.parse("\x1b[200~", false).event.?);
}
