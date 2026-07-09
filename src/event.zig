//! Input events and the Key/Mouse types, shaped around the kitty keyboard
//! model. Legacy escape sequences are normalized *into* this shape.
const std = @import("std");

pub const Size = struct {
    cols: u16,
    rows: u16,
};

pub const Event = union(enum) {
    key: Key,
    mouse: Mouse,
    resize: Size,
    focus_in,
    focus_out,
    paste_start,
    paste_end,
    cap: Cap,
};

/// A capability-query response from the terminal. `Terminal.detectCaps`
/// consumes these; applications only see them if they run detection manually.
pub const Cap = union(enum) {
    /// Terminal answered kitty `CSI ? u` — the protocol is supported.
    /// Payload is the currently-set progressive enhancement flags.
    kitty_keyboard: u8,
    /// DECRQM report: mode number and its value
    /// (0 = not recognized, 1 = set, 2 = reset, 3/4 = permanently so).
    decrqm: struct { mode: u16, value: u8 },
    /// XTGETTCAP reply for the RGB/Tc terminfo caps: the terminal
    /// confirmed (or denied) truecolor support.
    truecolor: bool,
    /// Primary device attributes reply — the end-of-detection fence:
    /// every terminal answers DA1, and responses arrive in order.
    da1,
};

/// Kitty-protocol modifier bits (value - 1 on the wire), in wire order.
pub const Mods = packed struct(u8) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,
    hyper: bool = false,
    meta: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
};

pub const KeyEventKind = enum(u2) { press = 1, repeat = 2, release = 3 };

pub const Key = struct {
    /// Unicode codepoint identifying the key. Functional keys use the kitty
    /// protocol's assignments in the Unicode Private Use Area (see constants).
    codepoint: u21,
    mods: Mods = .{},
    kind: KeyEventKind = .press,
    /// Shifted / base-layout alternates (kitty "report alternate keys"),
    /// when the terminal provides them.
    shifted: ?u21 = null,
    base: ?u21 = null,

    // Named keys that have real ASCII identities.
    pub const tab: u21 = 9;
    pub const enter: u21 = 13;
    pub const escape: u21 = 27;
    pub const space: u21 = 32;
    pub const backspace: u21 = 127;

    // Kitty functional-key codepoints (PUA), per the protocol spec:
    // https://sw.kovidgoyal.net/kitty/keyboard-protocol/#functional-key-definitions
    pub const insert: u21 = 57348;
    pub const delete: u21 = 57349;
    pub const left: u21 = 57350;
    pub const right: u21 = 57351;
    pub const up: u21 = 57352;
    pub const down: u21 = 57353;
    pub const page_up: u21 = 57354;
    pub const page_down: u21 = 57355;
    pub const home: u21 = 57356;
    pub const end: u21 = 57357;
    pub const caps_lock: u21 = 57358;
    pub const f1: u21 = 57364;

    /// F1–F12 and friends: `Key.f(5)` is F5.
    pub fn f(n: u21) u21 {
        return f1 + n - 1;
    }

    /// True when this key event is a press/repeat of `codepoint` with
    /// exactly `mods`. The workhorse for keybinding checks.
    pub fn matches(self: Key, codepoint: u21, mods: Mods) bool {
        return self.kind != .release and
            self.codepoint == codepoint and
            std.meta.eql(self.mods, mods);
    }
};

pub const MouseButton = enum { left, middle, right, none, wheel_up, wheel_down };

pub const Mouse = struct {
    /// 0-based cell coordinates, matching Surface.
    col: u16,
    row: u16,
    button: MouseButton,
    kind: enum { press, release, motion },
    mods: Mods = .{},
};

test "key matches" {
    const k: Key = .{ .codepoint = 'q' };
    try std.testing.expect(k.matches('q', .{}));
    try std.testing.expect(!k.matches('q', .{ .ctrl = true }));

    const release: Key = .{ .codepoint = 'q', .kind = .release };
    try std.testing.expect(!release.matches('q', .{}));
}
