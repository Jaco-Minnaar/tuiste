//! The widget layer: stateless widgets drawn into a Region each frame, any
//! persistent state owned by the application and passed in. Layering rule:
//! nothing under widgets/ may import Renderer, Terminal, Tty, or Loop —
//! widgets speak only to Region/Surface/cell, so they stay a pure layer on
//! top of the core and trivially testable against a bare Surface.
//!
//! Conventions every widget follows:
//!
//! - Memory: widget state never allocates by default — the application
//!   provides the memory (TextField's buffer) or the state is a couple of
//!   integers. A widget may take an allocator only as a deliberate,
//!   documented exception; `draw` never allocates.
//! - Keys: interactive state exposes `handleKey(key, ...) bool` covering
//!   the standard bindings and reporting whether the key was consumed.
//!   Applications check their own bindings first and fall through.
//! - Mouse: interactive widgets expose `hitTest(...) ?index` mapping a
//!   region-relative position to what was hit; applications feed it
//!   `m.col/m.row - region.rect.x/y` after a `region.rect.contains` check.
//! - Focus: application-owned, immediate-mode style — keep an enum of
//!   focusable widgets, route keys to the focused one's `handleKey`, and
//!   let only the focused widget's draw request the hardware cursor (one
//!   `setCursor` per frame wins).
pub const Block = @import("widgets/Block.zig");
pub const braille = @import("widgets/braille.zig");
pub const Chart = @import("widgets/Chart.zig");
pub const Clear = @import("widgets/Clear.zig");
pub const Gauge = @import("widgets/Gauge.zig");
pub const List = @import("widgets/List.zig");
pub const Paragraph = @import("widgets/Paragraph.zig");
pub const Scrollbar = @import("widgets/Scrollbar.zig");
pub const Separator = @import("widgets/Separator.zig");
pub const Sparkline = @import("widgets/Sparkline.zig");
pub const Spinner = @import("widgets/Spinner.zig");
pub const Table = @import("widgets/Table.zig");
pub const Tabs = @import("widgets/Tabs.zig");
pub const TextArea = @import("widgets/TextArea.zig");
pub const TextField = @import("widgets/TextField.zig");
pub const Tree = @import("widgets/Tree.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
