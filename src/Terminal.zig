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
const Caps = @import("caps.zig").Caps;
const event = @import("event.zig");

gpa: std.mem.Allocator,
tty: Tty,
renderer: Renderer,
caps: Caps,
options: Options,

pub const Options = struct {
    /// TODO: replace with runtime detection during startup.
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
