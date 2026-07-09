//! Terminal capabilities: conservative defaults, upgraded by runtime
//! detection. `Terminal.detectCaps` writes `query_sequence`, then folds the
//! resulting `Event.cap` responses into a `Caps` via `apply` until the DA1
//! fence arrives (every terminal answers DA1, and responses arrive in order,
//! so anything still unanswered at that point is unsupported).
const std = @import("std");
const ctlseqs = @import("ctlseqs.zig");
const event = @import("event.zig");

/// Everything we ask the terminal, DA1 fence last.
pub const query_sequence = ctlseqs.kitty_kb_query ++ ctlseqs.sync_query ++
    ctlseqs.truecolor_query ++ ctlseqs.da1_request;

pub const Caps = struct {
    kitty_keyboard: bool = false,
    /// Starts as a modern-ANSI assumption (RGB output degrades gracefully
    /// where it's wrong); XTGETTCAP replies during detection confirm or
    /// deny it. No reply leaves the assumption in place.
    truecolor: bool = true,
    /// Whether a positive XTGETTCAP reply arrived. Terminals that answer
    /// per-capname send separate RGB and Tc replies — once one confirms,
    /// a later "don't know that cap" reply must not downgrade.
    truecolor_confirmed: bool = false,
    synchronized_output: bool = false,

    /// What you get on any current mainstream terminal emulator.
    pub const assume_modern: Caps = .{
        .kitty_keyboard = true,
        .truecolor = true,
        .synchronized_output = true,
    };

    /// Fold one query response in. Returns true when `cap` was the DA1
    /// fence, i.e. detection is complete.
    pub fn apply(self: *Caps, cap: event.Cap) bool {
        switch (cap) {
            // Any reply at all means the protocol is spoken.
            .kitty_keyboard => self.kitty_keyboard = true,
            .truecolor => |confirmed| {
                if (confirmed) {
                    self.truecolor = true;
                    self.truecolor_confirmed = true;
                } else if (!self.truecolor_confirmed) {
                    self.truecolor = false;
                }
            },
            .decrqm => |m| {
                if (m.mode == 2026) {
                    // 1 = set, 2 = reset, 3 = permanently set: all usable.
                    // 0 = not recognized, 4 = permanently reset: not usable.
                    self.synchronized_output = switch (m.value) {
                        1, 2, 3 => true,
                        else => false,
                    };
                }
            },
            .da1 => return true,
        }
        return false;
    }
};

test "apply folds responses and signals the da1 fence" {
    var caps: Caps = .{};
    try std.testing.expect(!caps.apply(.{ .kitty_keyboard = 0 }));
    try std.testing.expect(caps.kitty_keyboard);
    try std.testing.expect(!caps.apply(.{ .decrqm = .{ .mode = 2026, .value = 2 } }));
    try std.testing.expect(caps.synchronized_output);
    try std.testing.expect(caps.apply(.da1));
}

test "truecolor replies confirm, deny, and stay sticky" {
    // no reply: assumption survives
    const silent: Caps = .{};
    try std.testing.expect(silent.truecolor);

    // explicit denial downgrades
    var denied: Caps = .{};
    _ = denied.apply(.{ .truecolor = false });
    try std.testing.expect(!denied.truecolor);

    // per-name replies: a confirm followed by an unknown-cap denial sticks
    var split: Caps = .{};
    _ = split.apply(.{ .truecolor = true });
    _ = split.apply(.{ .truecolor = false });
    try std.testing.expect(split.truecolor);
}

test "unsupported decrqm values stay off" {
    var caps: Caps = .{};
    _ = caps.apply(.{ .decrqm = .{ .mode = 2026, .value = 0 } });
    try std.testing.expect(!caps.synchronized_output);
    _ = caps.apply(.{ .decrqm = .{ .mode = 2026, .value = 4 } });
    try std.testing.expect(!caps.synchronized_output);
}
