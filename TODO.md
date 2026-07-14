# TODO

Known gaps, in rough priority order. Items marked in source with `TODO` comments.

Widget/layout layer — immediate-mode all the way down: rect-splitting layout,
stateless widgets, app-owned state. In-repo under `tuiste.widgets`; layering
rule: widget code uses only the public Surface/cell API, never
Renderer/Terminal internals.

- (initial widget set complete: Block, Paragraph, List, TextField — each
  dogfooded in an example)

Settled widget-layer conventions (documented in `src/widgets.zig`):
state never allocates by default (caller-provided memory; allocator only as
a documented exception; draw never allocates); interactive state exposes
`handleKey(key, ...) bool` with app-bindings-first fall-through; interactive
widgets expose `hitTest(...) ?index`; focus is an app-owned enum routing
keys to the focused widget's `handleKey` (pattern only, no helper yet).

Bigger commitments, design pass first:

- [ ] TextArea v2 candidates (explicitly cut from v1): selections +
      clipboard copy of a range, undo, horizontal no-wrap mode, page up/down

Later candidates: two-pass measure/arrange layout (only if paragraph wrapping
demands it), OSC 52 clipboard *read* (permission-gated in most terminals),
Windows/ConPTY.

## Done

- ~~widget: `widgets.Sparkline` (eighth-height blocks over the full region height, auto/fixed range, tail-keeping) + `.marker = .braille` mode (two samples per cell, btop-style filled area graph) + `.gradient` bottom→top color stops sampled per cell row, dogfooded in the dashboard~~
- ~~widgets: `braille` (dot/line plotting, Surface-as-accumulator merge, no scratch buffer) + `Chart` (line/scatter datasets, bounds mapping, axis labels, legend) + animated chart example~~
- ~~widget: `widgets.TextArea` — contiguous app-owned buffer, wrapped-row cursor motion (sticky column, visual home/end), virtual row after a trailing newline, `handleKey`/`hitTest`, vertical scroll-follow + textarea example~~
- ~~widget: `widgets.Tree` — flat pre-order `[]Node` (app owns expansion), node-index selection that snaps to the collapsing ancestor, user-defined markers/guide lines, `handleKey` (←/→ fold, enter/space toggle) + `hitTest` + tree example~~
- ~~conventions retrofit: `handleKey`/`hitTest` on List and Table (shared State), used by the list/dashboard examples~~
- ~~widget batch 2: Gauge (eighth-block smoothing), Clear, Separator, Spinner (app-owned tick), Scrollbar, Tabs (+`hitTest`), Table (columns via `layout.split`, reuses `List.State`) — all dogfooded in the dashboard example~~
- ~~widget: `widgets.TextField` (caller-provided buffer, grapheme-aware editing, `handleKey`, horizontal scroll-follows-cursor), input example rewritten around it~~
- ~~widget: `widgets.List` (selection marker, full-row highlight, scroll-follows-selection, `List.State`) + list example~~
- ~~widget: `widgets.Paragraph` (word/grapheme wrap, `measure(width)`, app-owned scroll) + paragraph example~~
- ~~widget: `widgets.Block` (border sets, top-edge title, yields inner Region), dogfooded in the demo~~
- ~~layout: `layout.split` (`len`/`pct`/`min`/`fill`), `Rect.inset`/`centered`, dogfooded in the scroll example~~
- ~~widget foundation: `Rect` + `Region` (clipped, offset, region-relative view into a Surface)~~
- ~~OSC 8 `id=` param: derived-by-default (`~<pool idx>`), explicit `.link_id` override~~
- ~~OSC 52 clipboard write: `Terminal.copyToClipboard`, streaming base64, fire-and-forget~~
- ~~OSC 8 hyperlinks: `writeText(.., .{ .link = "https://…" })`, URI interned in the shared pool~~
- ~~bracketed-paste aggregation: single `.paste` event, chunked parsing, split-terminator safety~~
- ~~scroll-region hint API (`Terminal.scrollUp/scrollDown`) + scrolling-log example~~
- ~~text-input example (`examples/input.zig`) dogfooding cursor + grapheme editing~~ (1487722)
- ~~cursor positioning/visibility/shape API (`Terminal.setCursor`)~~ (1eaa896)
- ~~`caps.zig`: verify truecolor via XTGETTCAP~~ (2895a83)
- ~~`Surface.zig`: fold zero-width marks into the previous cell in `writeText`~~ (3f1cac6)

- ~~`Loop.zig`: ESC-grace timeout for escape sequences split across reads~~ (44d3232)
- ~~`caps.zig`: runtime capability detection via query responses~~ (44d3232)
- ~~`Tty.zig`: panic-safe termios restore~~ (ec342f7)
- ~~`cell.zig`: overflow pool for graphemes longer than 15 bytes~~
