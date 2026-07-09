# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**tuiste** (Afrikaans for "home") is an immediate-mode terminal UI library for Zig 0.16.0. Linux-first, no terminfo — modern ANSI plus runtime capability queries. The public module is `tuiste` (rooted at `src/root.zig`); the package name in build.zig.zon is `.tuiste`.

## Commands

```sh
zig build test --summary all   # run all library tests
zig build                      # compile demo exe (zig-out/bin/demo)
zig build run                  # run the demo interactively
```

There is no per-file test runner wired up; to iterate on one module's tests use `zig test src/<file>.zig` only for pure modules (cell, event) — anything importing `unicode.zig` needs the zg module mapping that only `zig build test` provides.

**Important:** `zig build test` passing is NOT sufficient verification. The test root uses `refAllDecls`, which does not analyze function bodies, so type errors in the I/O modules (Tty, Loop, Terminal) slip through. Always also run `zig build` — compiling the demo is what exercises those bodies.

**Headless smoke test** (verifies rendering + input end-to-end without an interactive terminal):

```sh
(sleep 0.3; printf 'q') | script -qec 'stty rows 24 cols 80; ./zig-out/bin/demo' /tmp/ts.txt
```

The `stty` inside is mandatory — `script`'s pty defaults to a 0x0 winsize, so without it the surfaces are empty and nothing renders. Inspect `/tmp/ts.txt` with `cat -v` to check the emitted escape sequences; the demo exits 0 and its DebugAllocator reports leaks on failure.

## Architecture

Immediate mode with a diffed double buffer: user code redraws the whole frame into the back `Surface` each pass; `Renderer` diffs it against the front surface (what's on screen) and emits the minimal escape delta. The event loop is user-owned — the library never takes control flow. Core loop shape: `term.frame()` → draw → `term.render()` → `loop.nextEvent()`.

Dependency arrows (what may import what):

```
Terminal ─→ Tty, caps, Renderer, Surface
Renderer ─→ Surface, cell, ctlseqs, caps
Loop     ─→ Tty, input/Parser, event
Parser   ─→ event
Surface  ─→ cell, unicode
ctlseqs, cell, event ─→ nothing internal
```

Two invariants carry the design — do not break them:

- **`input/Parser.zig` is pure**: fed bytes, returns events, never touches an fd. This keeps the whole input matrix unit-testable with byte fixtures. `Loop.zig` is the only module that multiplexes input I/O (poll(2) over the tty fd + a SIGWINCH self-pipe).
- **Only `ctlseqs.zig` knows escape-sequence syntax.** Terminal quirks get fixed in one file.

Other structural decisions:

- Key/event types (`event.zig`) are shaped around the kitty keyboard protocol (codepoint + mods + press/repeat/release + shifted/base alternates, functional keys as kitty PUA codepoints); legacy escape input is normalized *into* that shape by the Parser, never the reverse.
- `render()` is allocation-free after init/resize; buffers are sized up front. Keep it that way — it's a stated API commitment.
- Wide graphemes occupy two cells: the glyph cell plus a width-0 spacer cell behind it. The Renderer skips spacers when emitting; `Renderer.invalidate()` fills the front buffer with a never-equal sentinel cell (`len == 0, width == 1`) to force full repaints.
- Cells store grapheme bytes inline (max 15); oversized clusters degrade to U+FFFD (overflow pool is a known TODO in `cell.zig`).
- Unicode width/segmentation comes from the `zg` dependency, wrapped in `src/unicode.zig` so the rest of the library never imports zg directly — keep it that way so the dep stays swappable.
- `caps.zig` defaults are conservative; runtime detection (DA1 / kitty `CSI ? u` responses surfaced as Parser events) is a known TODO. `Caps.assume_modern` exists for tests/demos.
- Capitalized filenames (`Tty.zig`, `Surface.zig`, …) are Zig's file-is-a-struct idiom; lowercase files (`cell.zig`, `event.zig`, …) are namespaces.

## Zig 0.16 specifics that bite

- Entry point is `pub fn main(init: std.process.Init) !void`; the `Io` instance is `init.io` and must be threaded into anything doing file I/O (`Io.File`, `file.writerStreaming(io, buf)`). `Tty` stores the `Io` it was given.
- `posix.sigaction` handlers take `posix.SIG` (an enum), not `i32`.
- Use `file.writerStreaming` (not `writer`) for the tty — it is not seekable.

## Known TODOs (marked in source)

- `Loop.zig`: an escape sequence split across two reads is parsed eagerly (lone ESC → escape key); needs a short ESC-grace poll.
- `caps.zig`: wire capability query responses through the Parser as events.
- `cell.zig`: overflow storage for graphemes longer than 15 bytes (ZWJ emoji).
- `Tty.zig`: panic-safe termios restore (opt-in root panic handler).
