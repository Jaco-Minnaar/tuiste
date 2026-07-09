//! tuiste — an immediate-mode terminal UI library. ("Tuiste" is Afrikaans
//! for "home": a home for terminal UIs.)
//!
//! Design commitments:
//!   * Immediate mode: draw the whole frame each pass; the Renderer diffs
//!     cells and writes the minimal delta. Render is allocation-free after init.
//!   * User-owned event loop: the library never takes control flow.
//!   * Modern-ANSI terminals, runtime capability queries, no terminfo.
//!   * Linux first.
const std = @import("std");

pub const cell = @import("cell.zig");
pub const Cell = cell.Cell;
pub const Style = cell.Style;
pub const Color = cell.Color;
pub const Attrs = cell.Attrs;

pub const Surface = @import("Surface.zig");
pub const Tty = @import("Tty.zig");
pub const Renderer = @import("Renderer.zig");
pub const Terminal = @import("Terminal.zig");
pub const Loop = @import("Loop.zig");
pub const Parser = @import("input/Parser.zig");

pub const event = @import("event.zig");
pub const Event = event.Event;
pub const Cap = event.Cap;
pub const Key = event.Key;
pub const Mods = event.Mods;
pub const Mouse = event.Mouse;
pub const Size = event.Size;

pub const caps = @import("caps.zig");
pub const Caps = caps.Caps;

pub const ctlseqs = @import("ctlseqs.zig");
pub const unicode = @import("unicode.zig");

/// Opt-in panic handler: restores the terminal (cooked mode, main screen,
/// visible cursor) before the default panic output, so a crash never leaves
/// the user's shell raw with the message invisible on the alt screen.
/// In your application's root source file:
///
///     pub const panic = tuiste.panic;
pub const panic = std.debug.FullPanic(panicWithRestore);

fn panicWithRestore(msg: []const u8, first_trace_addr: ?usize) noreturn {
    Tty.panicRestore();
    std.debug.defaultPanic(msg, first_trace_addr);
}

test {
    std.testing.refAllDecls(@This());
}
