# TODO

Known gaps, in rough priority order. Items marked in source with `TODO` comments.

(none currently — candidates: scroll-region optimization in the Renderer, OSC parsing for clipboard/hyperlinks, Windows/ConPTY)

## Done

- ~~cursor positioning/visibility/shape API (`Terminal.setCursor`)~~
- ~~`caps.zig`: verify truecolor via XTGETTCAP~~ (2895a83)
- ~~`Surface.zig`: fold zero-width marks into the previous cell in `writeText`~~ (3f1cac6)

- ~~`Loop.zig`: ESC-grace timeout for escape sequences split across reads~~ (44d3232)
- ~~`caps.zig`: runtime capability detection via query responses~~ (44d3232)
- ~~`Tty.zig`: panic-safe termios restore~~ (ec342f7)
- ~~`cell.zig`: overflow pool for graphemes longer than 15 bytes~~
