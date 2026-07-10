//! An activity indicator. The application owns time, immediate-mode style:
//! it passes a tick counter (bumped on whatever cadence it likes, e.g. a
//! `nextEvent` timeout) and the spinner indexes its frame set — the library
//! has no timers.
const Spinner = @This();

const std = @import("std");
const Region = @import("../Region.zig");
const Surface = @import("../Surface.zig");

/// Any monotonic counter; frame = tick % frames.len.
tick: usize = 0,
frames: []const []const u8 = &braille,
opts: Surface.Options = .{},

pub const braille = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
pub const line = [_][]const u8{ "|", "/", "-", "\\" };

/// Draw the current frame at the region's origin.
pub fn draw(self: Spinner, region: Region) void {
    if (self.frames.len == 0) return;
    _ = region.writeText(0, 0, self.frames[self.tick % self.frames.len], self.opts);
}

// --- tests ------------------------------------------------------------

test "ticks cycle the frame set" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 4, 1);
    defer s.deinit(gpa);

    (Spinner{ .tick = 0, .frames = &line }).draw(Region.full(&s));
    try std.testing.expectEqualStrings("|", s.cellAt(0, 0).?.grapheme());
    (Spinner{ .tick = 5, .frames = &line }).draw(Region.full(&s));
    try std.testing.expectEqualStrings("/", s.cellAt(0, 0).?.grapheme());

    (Spinner{ .tick = 3 }).draw(Region.full(&s)); // default braille set
    try std.testing.expectEqualStrings("⠸", s.cellAt(0, 0).?.grapheme());

    (Spinner{ .frames = &.{} }).draw(Region.full(&s)); // empty set: no-op
}
