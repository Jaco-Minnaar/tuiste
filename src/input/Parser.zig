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

/// Between the bracketed-paste delimiters the parsing rules change: every
/// byte is literal content until the `CSI 201~` terminator, so paste mode is
/// the one piece of state the byte stream alone can't carry.
in_paste: bool = false,

pub const Result = struct {
    event: ?Event,
    /// Bytes consumed. 0 means "incomplete — feed more input".
    /// consumed > 0 with a null event means "recognized and ignored".
    consumed: usize,
};

/// Parse one event from the front of `input`. `more` signals that further
/// bytes are known to be pending, which disambiguates a lone ESC.
pub fn parse(self: *Parser, input: []const u8, more: bool) Result {
    std.debug.assert(input.len > 0);
    if (self.in_paste) return self.parsePaste(input);
    const r = if (input[0] == 0x1b) parseEscape(input, more) else parseGround(input);
    if (r.event) |ev| {
        if (ev == .paste_start) self.in_paste = true;
    }
    return r;
}

const paste_terminator = "\x1b[201~";

/// Paste mode: everything is literal content until the terminator. Content
/// is returned as `.paste_chunk` slices into `input`. A trailing partial
/// terminator is held back until later bytes resolve it — unlike a lone ESC
/// keypress there is no timeout ambiguity here, because the terminal is
/// mid-paste and the terminator is guaranteed to still be in flight (the
/// Loop knows this and waits instead of applying its ESC grace timeout).
fn parsePaste(self: *Parser, input: []const u8) Result {
    if (std.mem.indexOf(u8, input, paste_terminator)) |i| {
        if (i == 0) {
            self.in_paste = false;
            return .{ .event = .paste_end, .consumed = paste_terminator.len };
        }
        return .{ .event = .{ .paste_chunk = input[0..i] }, .consumed = i };
    }
    // No terminator, so nothing but a partial prefix of one at the very end
    // of the input can be part of it; everything before that is content.
    const held = partialSuffixLen(input, paste_terminator);
    const end = input.len - held;
    if (end == 0) return .{ .event = null, .consumed = 0 };
    return .{ .event = .{ .paste_chunk = input[0..end] }, .consumed = end };
}

/// Length of the longest proper prefix of `needle` that `haystack` ends with.
fn partialSuffixLen(haystack: []const u8, needle: []const u8) usize {
    var k = @min(haystack.len, needle.len - 1);
    while (k > 0) : (k -= 1) {
        if (std.mem.endsWith(u8, haystack, needle[0..k])) return k;
    }
    return 0;
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
        'P' => return parseDcs(input),
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

    // `?`-prefixed parameters mark terminal *responses* to our capability
    // queries (and DEC private modes), never keyboard input.
    if (params.len > 0 and params[0] == '?') {
        return parsePrivate(params[1..], final, consumed);
    }

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

/// CSI sequences whose parameters begin with `?`: capability-query responses.
/// `params` has the leading `?` already stripped.
fn parsePrivate(params: []const u8, final: u8, consumed: usize) Result {
    switch (final) {
        'u' => {
            // Kitty keyboard query reply: CSI ? flags u
            const flags = subParam(params, 0) orelse 0;
            return .{ .event = .{ .cap = .{
                .kitty_keyboard = @intCast(flags & 0xff),
            } }, .consumed = consumed };
        },
        'c' => return .{ .event = .{ .cap = .da1 }, .consumed = consumed },
        'y' => {
            // DECRQM reply: CSI ? mode ; value $ y
            // The `$` intermediate rides along at the end of the params slice.
            const trimmed = std.mem.trimEnd(u8, params, "$");
            var it: ParamIter = .{ .rest = trimmed };
            const mode = subParam(it.next() orelse "", 0) orelse
                return .{ .event = null, .consumed = consumed };
            const value = subParam(it.next() orelse "", 0) orelse 0;
            return .{ .event = .{ .cap = .{ .decrqm = .{
                .mode = @intCast(@min(mode, std.math.maxInt(u16))),
                .value = @intCast(@min(value, std.math.maxInt(u8))),
            } } }, .consumed = consumed };
        },
        else => return .{ .event = null, .consumed = consumed },
    }
}

/// DCS strings: ESC P <payload> ESC \ (ST). The only payloads we understand
/// are XTGETTCAP replies; anything else is consumed and ignored.
fn parseDcs(input: []const u8) Result {
    // Find the ST terminator.
    var i: usize = 2;
    const end = while (i + 1 < input.len) : (i += 1) {
        if (input[i] == 0x1b and input[i + 1] == '\\') break i;
        if (i > 2048) return .{ .event = null, .consumed = i }; // runaway; drop
    } else return .{ .event = null, .consumed = 0 }; // incomplete

    const payload = input[2..end];
    const consumed = end + 2;

    // XTGETTCAP reply: DCS 1 + r name=value[;name=value…] ST (hex-encoded
    // names) on success, DCS 0 + r … ST when the terminal doesn't know the
    // requested caps. We only ever ask about RGB/Tc (truecolor).
    if (payload.len >= 3 and payload[1] == '+' and payload[2] == 'r') {
        if (payload[0] == '0')
            return .{ .event = .{ .cap = .{ .truecolor = false } }, .consumed = consumed };
        if (payload[0] == '1') {
            var truecolor = false;
            var it = std.mem.splitScalar(u8, payload[3..], ';');
            while (it.next()) |pair| {
                const name_hex = if (std.mem.indexOfScalar(u8, pair, '=')) |eq| pair[0..eq] else pair;
                var name_buf: [8]u8 = undefined;
                const name = hexDecode(&name_buf, name_hex) orelse continue;
                if (std.mem.eql(u8, name, "RGB") or std.mem.eql(u8, name, "Tc")) truecolor = true;
            }
            return .{ .event = .{ .cap = .{ .truecolor = truecolor } }, .consumed = consumed };
        }
    }
    return .{ .event = null, .consumed = consumed };
}

fn hexDecode(buf: []u8, hex: []const u8) ?[]const u8 {
    if (hex.len % 2 != 0 or hex.len / 2 > buf.len) return null;
    var n: usize = 0;
    while (n < hex.len) : (n += 2) {
        buf[n / 2] = std.fmt.parseInt(u8, hex[n .. n + 2], 16) catch return null;
    }
    return buf[0 .. hex.len / 2];
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

test "capability query responses" {
    var p: Parser = .{};

    const kitty = p.parse("\x1b[?1u", false);
    try std.testing.expectEqual(@as(usize, 5), kitty.consumed);
    try std.testing.expectEqualDeep(Event{ .cap = .{ .kitty_keyboard = 1 } }, kitty.event.?);
    // flags 0 still means "protocol supported"
    try std.testing.expectEqualDeep(Event{ .cap = .{ .kitty_keyboard = 0 } }, p.parse("\x1b[?0u", false).event.?);

    const da1 = p.parse("\x1b[?62;4;22c", false);
    try std.testing.expectEqual(@as(usize, 11), da1.consumed);
    try std.testing.expectEqualDeep(Event{ .cap = .da1 }, da1.event.?);

    const sync = p.parse("\x1b[?2026;1$y", false);
    try std.testing.expectEqualDeep(Event{ .cap = .{ .decrqm = .{ .mode = 2026, .value = 1 } } }, sync.event.?);
    const unsupported = p.parse("\x1b[?2026;0$y", false);
    try std.testing.expectEqualDeep(Event{ .cap = .{ .decrqm = .{ .mode = 2026, .value = 0 } } }, unsupported.event.?);
}

test "xtgettcap replies" {
    var p: Parser = .{};

    // RGB=8/8/8 (values hex-encoded like the names)
    const rgb = p.parse("\x1bP1+r524742=382F382F38\x1b\\", false);
    try std.testing.expectEqual(@as(usize, 24), rgb.consumed);
    try std.testing.expectEqualDeep(Event{ .cap = .{ .truecolor = true } }, rgb.event.?);

    // Tc with no value, second pair unknown
    const tc = p.parse("\x1bP1+r5463;626F6F=31\x1b\\", false);
    try std.testing.expectEqualDeep(Event{ .cap = .{ .truecolor = true } }, tc.event.?);

    // terminal doesn't know the caps
    const denied = p.parse("\x1bP0+r\x1b\\", false);
    try std.testing.expectEqualDeep(Event{ .cap = .{ .truecolor = false } }, denied.event.?);

    // unrelated DCS payloads are consumed and ignored
    const other = p.parse("\x1bP=1s\x1b\\", false);
    try std.testing.expectEqual(@as(?Event, null), other.event);
    try std.testing.expectEqual(@as(usize, 7), other.consumed);

    // incomplete DCS wants more bytes
    try std.testing.expectEqual(@as(usize, 0), p.parse("\x1bP1+r5246", false).consumed);
}

test "private-prefixed sequences never parse as keys" {
    var p: Parser = .{};
    // Looks like a kitty key ('a' with ctrl) but the ? marks it as a response.
    const r = p.parse("\x1b[?97;5u", false);
    try std.testing.expect(r.event.? == .cap);
}

test "focus and paste delimiters" {
    var p: Parser = .{};
    try std.testing.expectEqualDeep(Event.focus_in, p.parse("\x1b[I", false).event.?);
    try std.testing.expectEqualDeep(Event.paste_start, p.parse("\x1b[200~", false).event.?);
    try std.testing.expect(p.in_paste);
}

test "paste content is literal until the terminator" {
    var p: Parser = .{};
    _ = p.parse("\x1b[200~", false);

    // Escape-looking bytes inside a paste stay literal.
    const chunk = p.parse("hi \x1b[A there\x1b[201~", true);
    try std.testing.expectEqualStrings("hi \x1b[A there", chunk.event.?.paste_chunk);

    const end = p.parse("\x1b[201~", true);
    try std.testing.expectEqualDeep(Event.paste_end, end.event.?);
    try std.testing.expect(!p.in_paste);

    // Back to normal parsing.
    try std.testing.expectEqualDeep(
        Event{ .key = .{ .codepoint = Key.up } },
        p.parse("\x1b[A", false).event.?,
    );
}

test "paste terminator split across reads" {
    var p: Parser = .{};
    _ = p.parse("\x1b[200~", false);

    // Content up to the partial terminator is emitted; the tail is held.
    const chunk = p.parse("abc\x1b[201", true);
    try std.testing.expectEqualStrings("abc", chunk.event.?.paste_chunk);
    try std.testing.expectEqual(@as(usize, 3), chunk.consumed);

    // Held tail alone: incomplete regardless of `more` — mid-paste the
    // terminator is guaranteed to still be in flight...
    try std.testing.expectEqual(@as(usize, 0), p.parse("\x1b[201", true).consumed);
    try std.testing.expectEqual(@as(usize, 0), p.parse("\x1b[201", false).consumed);
    // ...and completes once the rest arrives.
    try std.testing.expectEqualDeep(Event.paste_end, p.parse("\x1b[201~", true).event.?);
}

test "held partial terminator that diverges is literal content" {
    var p: Parser = .{};
    _ = p.parse("\x1b[200~", false);
    // Ends like a terminator, but the next byte proves it content.
    const r = p.parse("abc\x1b[20x", true);
    try std.testing.expectEqualStrings("abc\x1b[20x", r.event.?.paste_chunk);
    try std.testing.expect(p.in_paste);
    // Content ending in a terminator lookalike right before the real one.
    const r2 = p.parse("ab\x1b[2\x1b[201~", true);
    try std.testing.expectEqualStrings("ab\x1b[2", r2.event.?.paste_chunk);
    try std.testing.expectEqualDeep(Event.paste_end, p.parse("\x1b[201~", true).event.?);
}

test "empty paste" {
    var p: Parser = .{};
    _ = p.parse("\x1b[200~", false);
    try std.testing.expectEqualDeep(Event.paste_end, p.parse("\x1b[201~", false).event.?);
}
