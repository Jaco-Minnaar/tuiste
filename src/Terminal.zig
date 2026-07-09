//! Top-level composition: Tty + Caps + Renderer, with a frame/render API.
//!
//!     var term = try Terminal.init(gpa, io, .{});
//!     defer term.deinit();
//!     var loop = try Loop.init(&term.tty);
//!     while (true) {
//!         var frame = term.frame();
//!         frame.writeText(...);
//!         try term.render();
//!         switch ((try loop.nextEvent(null)) orelse continue) { ... }
//!     }
const Terminal = @This();

const std = @import("std");
const Io = std.Io;
const Tty = @import("Tty.zig");
const Renderer = @import("Renderer.zig");
const Surface = @import("Surface.zig");
const ctlseqs = @import("ctlseqs.zig");
const caps_mod = @import("caps.zig");
const Caps = caps_mod.Caps;
const Loop = @import("Loop.zig");
const event = @import("event.zig");

gpa: std.mem.Allocator,
tty: Tty,
renderer: Renderer,
caps: Caps,
options: Options,

pub const Options = struct {
    /// Starting point; call `detectCaps` after creating the Loop to upgrade
    /// these from actual terminal responses.
    caps: Caps = .{},
    /// Push kitty keyboard disambiguation (ignored by terminals without it).
    kitty_keyboard: bool = true,
    mouse: bool = false,
    bracketed_paste: bool = true,
    focus_events: bool = true,
};

pub fn init(gpa: std.mem.Allocator, io: Io, options: Options) !Terminal {
    var tty = try Tty.init(gpa, io);
    errdefer tty.deinit(gpa);
    try tty.makeRaw();

    const size = try tty.size();
    var renderer = try Renderer.init(gpa, size.cols, size.rows);
    errdefer renderer.deinit(gpa);

    const w = tty.writer();
    try w.writeAll(ctlseqs.enter_alt_screen ++ ctlseqs.hide_cursor ++
        ctlseqs.clear_screen ++ ctlseqs.cursor_home);
    if (options.kitty_keyboard) try w.writeAll(ctlseqs.kitty_kb_push);
    if (options.mouse) try w.writeAll(ctlseqs.mouse_on);
    if (options.bracketed_paste) try w.writeAll(ctlseqs.bracketed_paste_on);
    if (options.focus_events) try w.writeAll(ctlseqs.focus_on);
    try tty.flush();

    return .{
        .gpa = gpa,
        .tty = tty,
        .renderer = renderer,
        .caps = options.caps,
        .options = options,
    };
}

/// Undo everything init did, best-effort — teardown must not fail.
pub fn deinit(self: *Terminal) void {
    const w = self.tty.writer();
    if (self.options.focus_events) w.writeAll(ctlseqs.focus_off) catch {};
    if (self.options.bracketed_paste) w.writeAll(ctlseqs.bracketed_paste_off) catch {};
    if (self.options.mouse) w.writeAll(ctlseqs.mouse_off) catch {};
    if (self.options.kitty_keyboard) w.writeAll(ctlseqs.kitty_kb_pop) catch {};
    w.writeAll(ctlseqs.sgr_reset ++ ctlseqs.show_cursor ++ ctlseqs.exit_alt_screen) catch {};
    self.tty.flush() catch {};

    self.renderer.deinit(self.gpa);
    self.tty.deinit(self.gpa);
    self.* = undefined;
}

/// Start a new frame: returns the cleared back surface to draw into.
pub fn frame(self: *Terminal) *Surface {
    self.renderer.back.clear();
    return &self.renderer.back;
}

/// Diff the drawn frame against the screen and flush the delta.
pub fn render(self: *Terminal) !void {
    try self.renderer.render(self.tty.writer(), self.caps);
    try self.tty.flush();
}

/// Call on `Event.resize`; reallocates buffers and forces a full redraw.
pub fn resize(self: *Terminal, size: event.Size) !void {
    try self.renderer.resize(self.gpa, size.cols, size.rows);
}

/// Query the terminal for its capabilities and fold the answers into
/// `self.caps`. Runs until the DA1 fence arrives or `timeout_ms` expires
/// (a terminal that answers nothing leaves the conservative defaults).
/// User input arriving mid-detection is re-queued on the loop, not lost.
pub fn detectCaps(self: *Terminal, loop: *Loop, timeout_ms: i32) !Caps {
    const w = self.tty.writer();
    try w.writeAll(caps_mod.query_sequence);
    try self.tty.flush();

    const io = self.tty.io;
    const start = std.Io.Clock.now(.awake, io);
    while (true) {
        const elapsed_ms = start.durationTo(std.Io.Clock.now(.awake, io)).toMilliseconds();
        const remaining = timeout_ms - std.math.clamp(elapsed_ms, 0, timeout_ms);
        if (remaining <= 0) break;
        const ev = (try loop.pollEvent(@intCast(remaining))) orelse break;
        switch (ev) {
            .cap => |cap| if (self.caps.apply(cap)) break,
            else => loop.pushDeferred(ev),
        }
    }
    return self.caps;
}
