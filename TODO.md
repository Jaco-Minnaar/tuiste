# TODO

Known gaps, in rough priority order. Items marked in source with `TODO` comments.

- `caps.zig`: verify truecolor via XTGETTCAP (needs DCS response parsing in the Parser).

## Done

- ~~`Surface.zig`: fold zero-width marks into the previous cell in `writeText`~~

- ~~`Loop.zig`: ESC-grace timeout for escape sequences split across reads~~ (44d3232)
- ~~`caps.zig`: runtime capability detection via query responses~~ (44d3232)
- ~~`Tty.zig`: panic-safe termios restore~~ (ec342f7)
- ~~`cell.zig`: overflow pool for graphemes longer than 15 bytes~~
