# tuiste

An immediate-mode terminal UI library for [Zig](https://ziglang.org).
*Tuiste* is Afrikaans for "home" — a home for terminal UIs.

```
╭─ sin & cos ──────────────────────────────────────────────╮
│ 1│⠉⠑⢢                ⡔⠉⠉⠒⢄ ⢀⠔⠉⠉⠒⡄               ⢠⠊⠉⠑⠢⡀sin│
│  │  ⠈⢢             ⢀⠜    ⠈⢢⠃    ⠑⡄             ⡠⠃    ⠑cos│
│  │    ⠱⡀          ⢀⠎     ⢀⠎⢆     ⠈⢆           ⡰⠁     ⡰⠱⡀ │
│ 0│⠘⡄     ⠘⡄    ⢰⠁     ⡰⠁      ⢣      ⢣     ⡎     ⢀⠎      │
│  │  ⢱     ⠈⢆  ⡜      ⡇         ⠈⡆     ⠱⡀ ⢠⠃     ⢸        │
│-1│     ⠑⢄⣀⡤⠊  ⠑⢄⣀⠤⠊               ⠈⠢⣀⣠⠔⠁ ⠈⠢⣀⡠⠔⠁          │
│  └───────────────────────────────────────────────────────│
│   0                         2π                         4π│
╰──────────────────────────────────────────────────────────╯
```

You redraw the whole frame every pass; tuiste diffs it against what is on
screen and writes the minimal escape delta. There is no retained widget
tree, no callbacks, no framework — your `while` loop owns control flow,
your structs own all state, and the library stays out of the way.

```zig
const std = @import("std");
const tuiste = @import("tuiste");

// Restore the terminal before any panic message prints.
pub const panic = tuiste.panic;

pub fn main(init: std.process.Init) !void {
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_alloc.deinit();
    const gpa = debug_alloc.allocator();

    var term = try tuiste.Terminal.init(gpa, init.io, .{});
    defer term.deinit();
    var loop = try tuiste.Loop.init(gpa, &term.tty);
    defer loop.deinit();
    _ = try term.detectCaps(&loop, 300);

    while (true) {
        const frame = tuiste.Region.full(term.frame());
        _ = frame.writeText(2, 1, "hallo, wêreld — q quits", .{ .attrs = .{ .bold = true } });
        try term.render();

        switch ((try loop.nextEvent(null)) orelse continue) {
            .key => |k| if (k.matches('q', .{}) or k.matches('c', .{ .ctrl = true })) break,
            .resize => |size| try term.resize(size),
            else => {},
        }
    }
}
```

## Status

Pre-0.1 and Linux-only. The API is not yet stable — expect breaking
changes between commits until a tagged release. Requires **Zig 0.16.0**.

Not "portable to Linux": Linux-first by design. The library speaks modern
ANSI plus runtime capability queries (no terminfo), and uses Linux
syscalls directly in the few places an `Io` can't reach (signal and panic
handlers). macOS may come later; Windows/ConPTY is an open TODO.

## Installation

```sh
zig fetch --save git+<repository-url>
```

Then in your `build.zig`:

```zig
const tuiste = b.dependency("tuiste", .{});
exe.root_module.addImport("tuiste", tuiste.module("tuiste"));
```

The only dependency is [zg](https://codeberg.org/atman/zg) (Unicode
segmentation and width data), fetched and pinned automatically.

## How it works

- **Immediate mode, diffed.** `term.frame()` hands you a cleared back
  buffer; you draw the whole UI; `term.render()` diffs it against the
  front buffer and emits only what changed — wrapped in synchronized
  output (mode 2026) when the terminal supports it. `render` is
  allocation-free after init/resize; that is an API commitment.
- **You own the loop.** `loop.nextEvent(timeout_ms)` blocks (or times
  out — that's your animation tick). The library never takes control
  flow, spawns threads, or installs hidden timers.
- **Capabilities are detected, not assumed.** `term.detectCaps` queries
  the terminal (kitty keyboard, synchronized output, truecolor via
  XTGETTCAP, DA1 as the fence) and folds the answers into `term.caps`.
  A terminal that answers nothing leaves conservative defaults. User
  input arriving mid-detection is re-queued, not lost.
- **Unicode is handled at the cell level.** Text is written by grapheme
  cluster: wide glyphs (CJK, emoji) occupy two cells, ZWJ sequences and
  combining marks stay atomic, zero-width marks compose onto the previous
  glyph. Oversized clusters and hyperlink URIs intern into a shared pool
  so diffing stays a value compare. The renderer never trusts the
  terminal's cursor after a multi-codepoint cluster — terminals disagree
  about exactly those widths, and the explicit re-position keeps one
  misrendered emoji from shifting the rest of the row.

## Events

Input is normalized into one `Event` union shaped around the kitty
keyboard protocol (codepoint + modifiers + press/repeat/release, with
shifted/base alternates when the terminal reports them). Legacy escape
sequences are parsed *into* that shape, so application code never
branches on protocol:

```zig
switch (event) {
    .key => |k| if (k.matches('s', .{ .ctrl = true })) save(),
    .mouse => |m| ...,            // SGR encoding, press/release/motion, wheel
    .paste => |text| ...,         // one aggregated bracketed-paste event
    .resize => |size| try term.resize(size),
    .focus_in, .focus_out => ...,
    else => {},
}
```

Bracketed paste arrives as a single `.paste` event — the split-terminator
and mid-paste-Escape corner cases are handled inside the loop, including
over laggy links.

## Drawing: Surface, Region, layout

`Rect` is a plain rectangle; `Region` is a clipped, offset view into the
frame — widget code holding a Region *cannot* draw outside it. `layout.split`
carves a rect into rows or columns from constraints, allocation-free:

```zig
var rows: [3]tuiste.Rect = undefined;
const split = tuiste.layout.split(frame.bounds(), .vertical, &.{
    .{ .len = 1 },   // tab bar: exactly one row
    .{ .fill = 1 },  // content: whatever is left
    .{ .len = 1 },   // status bar
}, &rows);
const content = frame.sub(split[1]);
```

Constraints are `len` (exact), `pct`, `min` (grows into leftover), and
`fill` (weighted share). `Rect.inset` and `Rect.centered` cover margins
and modals.

## Widgets

Widgets are stateless config structs with a `draw(Region)` method,
redrawn every frame. Anything persistent — scroll offset, selection,
cursor, text buffer — lives in a small `State` struct that *your
application* owns and passes in. Conventions across the layer:

- widget state never allocates: you provide the memory
  (`TextField.State.init(&buf)`) or the state is a couple of integers;
- interactive state exposes `handleKey(key, ...) bool` — check your own
  bindings first, fall through to the widget's;
- interactive widgets expose `hitTest(...)` to map mouse positions back
  to items, rows, tabs, or byte offsets;
- focus is an app-owned enum: route keys to the focused widget, and let
  only its draw request the hardware cursor.

| Widget | What it does |
| --- | --- |
| `Block` | Border + title, returns the inner Region |
| `Paragraph` | Word/grapheme wrapping, `measure(width)`, scrolling |
| `List` | Selectable rows, marker, scroll-follows-selection |
| `Table` | Multi-column List; column widths are layout constraints |
| `Tree` | Expand/collapse over a flat pre-order node array, custom guide lines |
| `TextField` | Single-line editor, grapheme-aware, horizontal scroll |
| `TextArea` | Multi-line editor over wrapped rows, sticky cursor column |
| `Tabs` | One-row tab bar with click hit-testing |
| `Gauge` | Progress bar with eighth-block smoothing |
| `Sparkline` | Rolling area graph; block or braille (btop-style) markers |
| `Chart` | Braille XY chart: line/scatter datasets, axes, labels, legend |
| `Scrollbar` | Track/thumb companion for any scrolling widget |
| `Separator` | Horizontal/vertical rule with optional label |
| `Spinner` | Activity glyph driven by an app-owned tick counter |
| `Clear` | Styled fill — the underlay that makes modals opaque |

Plus `widgets.braille`, the dot-plotting primitive under Chart and
Sparkline (2×4 dots per cell, merged directly in the Surface — no
scratch buffers).

A modal is just composition:

```zig
const box = frame.bounds().centered(40, 7);
(tuiste.widgets.Clear{}).draw(frame.sub(box));
const inner = (tuiste.widgets.Block{ .title = " boodskap ", .lines = .double })
    .draw(frame.sub(box));
```

## Terminal extras

- **OSC 8 hyperlinks**: `writeText(x, y, "docs", .{ .link = "https://…" })`
  — with stable link ids so partial repaints stay one hoverable link.
- **OSC 52 clipboard write**: `term.copyToClipboard(text)` — works over
  SSH; streaming base64, fire-and-forget.
- **Scroll-region hints**: `term.scrollUp(top, bottom, n)` tells the
  renderer a band moved so it repaints only the exposed rows. Pure
  optimization — a wrong hint costs a bigger diff, never wrong output.
- **Cursor control**: per-frame position, visibility, and shape
  (`term.setCursor`), immediate-mode style.
- **Panic-safe restore**: alias `pub const panic = tuiste.panic;` in your
  root file and a crash restores cooked mode and the main screen *before*
  the panic message prints, so it is never lost on the alt screen.

## Examples

```sh
zig build            # compile all examples into zig-out/bin
zig build run        # scaffold demo: input echo, styles, unicode, links
zig build input      # single-line editor (TextField)
zig build textarea   # multi-line editor (TextArea)
zig build scroll     # scrolling log with hardware-scroll hints
zig build paragraph  # wrapped text with scrolling
zig build list       # selectable list with mouse support
zig build tree       # expand/collapse tree with guide lines
zig build dashboard  # tabs, table, gauge, sparkline, spinner, modal
zig build chart      # animated braille sin/cos chart
```

Every widget was built against one of these — they double as usage
reference.

## Testing

```sh
zig build test --summary all
```

The input parser is pure (bytes in, events out) so the whole input matrix
is unit-tested with byte fixtures; widgets draw into bare Surfaces with no
terminal involved. Rendering and input are additionally verified end-to-end
in a headless pty:

```sh
(sleep 0.3; printf 'q') | script -qec 'stty rows 24 cols 80; ./zig-out/bin/demo' /tmp/ts.txt
```

## License

Not yet chosen — coming with the first tagged release. Until then, treat
the code as all-rights-reserved reference material.
