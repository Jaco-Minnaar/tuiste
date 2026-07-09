//! Terminal capabilities. Conservative defaults until runtime detection
//! (DA1, kitty `CSI ? u`, XTGETTCAP) is wired through the event loop.
//! TODO: emit the queries from ctlseqs, parse the replies in input/Parser.zig
//! as events, and fold them into this struct during Terminal startup.

pub const Caps = struct {
    kitty_keyboard: bool = false,
    /// Modern-ANSI assumption; almost universally true today, and RGB output
    /// degrades gracefully on the terminals where it isn't.
    truecolor: bool = true,
    synchronized_output: bool = false,

    /// What you get on any current mainstream terminal emulator.
    pub const assume_modern: Caps = .{
        .kitty_keyboard = true,
        .truecolor = true,
        .synchronized_output = true,
    };
};
