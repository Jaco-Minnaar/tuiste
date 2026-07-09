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
Terminal ─→ Tty, caps, Renderer, Surface, Loop (detectCaps only)
Renderer ─→ Surface, cell, ctlseqs, caps, GraphemePool
Loop     ─→ Tty, input/Parser, event
Parser   ─→ event
Surface  ─→ cell, unicode, GraphemePool
ctlseqs, cell, event, GraphemePool ─→ nothing internal
```

Two invariants carry the design — do not break them:

- **`input/Parser.zig` is pure**: fed bytes, returns events, never touches an fd. This keeps the whole input matrix unit-testable with byte fixtures. `Loop.zig` is the only module that multiplexes input I/O (poll(2) over the tty fd + a SIGWINCH self-pipe).
- **Only `ctlseqs.zig` knows escape-sequence syntax.** Terminal quirks get fixed in one file.

Other structural decisions:

- Key/event types (`event.zig`) are shaped around the kitty keyboard protocol (codepoint + mods + press/repeat/release + shifted/base alternates, functional keys as kitty PUA codepoints); legacy escape input is normalized *into* that shape by the Parser, never the reverse.
- `render()` is allocation-free after init/resize; buffers are sized up front. Keep it that way — it's a stated API commitment.
- Wide graphemes occupy two cells: the glyph cell plus a width-0 spacer cell behind it. The Renderer skips spacers when emitting; `Renderer.invalidate()` fills the front buffer with a never-equal sentinel cell (`len == 0, width == 1`) to force full repaints.
- Cells store grapheme bytes inline (max 15). Longer clusters (ZWJ emoji) intern into the Renderer's `GraphemePool`, shared by both surfaces: the cell stores a u32 index (`len == overflow_len` sentinel, no size growth), equal bytes always intern to the same index, so the diff stays a value compare. Interning happens at `writeText` (draw path, may allocate — render stays allocation-free); on OOM or with a pool-less standalone Surface it degrades to U+FFFD rather than erroring. Resolve pooled cells via `Surface.graphemeOf`, never `Cell.grapheme` (which returns U+FFFD for them). Pool entries live for the Renderer's lifetime.
- Unicode width/segmentation comes from the `zg` dependency, wrapped in `src/unicode.zig` so the rest of the library never imports zg directly — keep it that way so the dep stays swappable.
- Capability detection: `Terminal.detectCaps(&loop, timeout_ms)` writes the queries from `caps.query_sequence` (kitty `CSI ? u`, DECRQM 2026, DA1 last as a fence — every terminal answers DA1, and responses arrive in order), then folds `Event.cap` responses into `term.caps` via `Caps.apply`. User input racing the detection round-trip is stashed with `Loop.pushDeferred` and replayed by later `nextEvent` calls. Detection MUST read via `Loop.pollEvent` (not `nextEvent`): pollEvent bypasses the deferred queue, and detection is the producer of deferred events — reading them back livelocks on the first stashed keypress. A terminal that answers nothing leaves the conservative defaults after the timeout.
- Panic-safe restore is opt-in: applications alias `pub const panic = tuiste.panic;` in their root file (the demo does). It calls `Tty.panicRestore()` — module-global state, raw syscalls only, no allocation, alt-screen exit last so the panic message prints on the real screen — before `std.debug.defaultPanic`. A library cannot install this itself; only the root module's `panic` decl counts.
- Capitalized filenames (`Tty.zig`, `Surface.zig`, …) are Zig's file-is-a-struct idiom; lowercase files (`cell.zig`, `event.zig`, …) are namespaces.

## Zig 0.16 specifics that bite

- Entry point is `pub fn main(init: std.process.Init) !void`; the `Io` instance is `init.io` and must be threaded into anything doing file I/O (`Io.File`, `file.writerStreaming(io, buf)`). `Tty` stores the `Io` it was given.
- `posix.sigaction` handlers take `posix.SIG` (an enum), not `i32`.
- Use `file.writerStreaming` (not `writer`) for the tty — it is not seekable.
- `std.posix.write` no longer exists (only `read` survived the Io migration); use the `std.os.linux.write` syscall directly in contexts that can't take an `Io` (signal handlers, panic handlers).
- `std.time.Timer` is gone; measure elapsed time with `std.Io.Clock.now(.awake, io)` + `durationTo(...).toMilliseconds()`.

## Known TODOs

See `TODO.md` (kept current; items are also marked in source with `TODO` comments).
