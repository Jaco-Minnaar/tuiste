//! Scrollable wrapped text in a bordered block — dogfoods Paragraph
//! (wrapping, measure, app-owned scroll) composed with Block and layout.
//! Scroll with up/down or the mouse wheel; quit with q or ctrl+c.
const std = @import("std");
const tuiste = @import("tuiste");

pub const panic = tuiste.panic;

const teks =
    "tuiste is Afrikaans vir \"home\": 'n tuiste vir terminale UIs.\n" ++
    "\n" ++
    "Hierdie paragraaf-widget vou woorde grafeem-bewus: wye karakters soos " ++
    "宽字符 tel twee kolomme, saamgestelde grafeme soos é en 👨‍👩‍👧‍👦 breek nooit " ++
    "middeldeur nie, en 'n woord wat breër as die venster is, breek hard. " ++
    "Maak die venster smaller of wyer — die vou volg elke hervergroting.\n" ++
    "\n" ++
    "Die wiel of die pyltjies rol; die toepassing besit die rol-afset en " ++
    "klem dit vas met measure(), presies soos die res van die biblioteek: " ++
    "onmiddellike modus, gebruiker-beheerde lus, geen verskuilde toestand nie.\n" ++
    "\n" ++
    "The same, in English, to make the text long enough to scroll: the " ++
    "paragraph widget wraps words grapheme-aware, wide characters count two " ++
    "columns, a word wider than the view hard-breaks, and the application " ++
    "owns the scroll offset — clamped with measure(), redrawn every frame.";

pub fn main(init: std.process.Init) !void {
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_alloc.deinit();
    const gpa = debug_alloc.allocator();

    var term = try tuiste.Terminal.init(gpa, init.io, .{ .mouse = true });
    defer term.deinit();

    var loop = try tuiste.Loop.init(gpa, &term.tty);
    defer loop.deinit();
    _ = try term.detectCaps(&loop, 300);

    var scroll: u16 = 0;

    while (true) {
        const frame = tuiste.Region.full(term.frame());
        var rows: [2]tuiste.Rect = undefined;
        const split = tuiste.layout.split(
            frame.bounds(),
            .vertical,
            &.{ .{ .fill = 1 }, .{ .len = 1 } },
            &rows,
        );

        const block: tuiste.widgets.Block = .{
            .title = " leesstof ",
            .lines = .rounded,
            .style = .{ .fg = .{ .indexed = 244 } },
        };
        const inner = block.draw(frame.sub(split[0]));

        var para: tuiste.widgets.Paragraph = .{ .text = teks };
        const total = para.measure(inner.width());
        const max_scroll = total -| inner.height();
        scroll = @min(scroll, max_scroll);
        para.scroll = scroll;
        _ = para.draw(inner);

        var bar_buf: [96]u8 = undefined;
        const bar = std.fmt.bufPrint(&bar_buf, " rows {d}–{d} of {d} — ↑/↓ or wheel scrolls, q quits ", .{
            scroll + 1,
            @min(scroll + inner.height(), total),
            total,
        }) catch unreachable;
        _ = frame.sub(split[1]).writeText(0, 0, bar, .{ .attrs = .{ .reverse = true } });

        try term.render();

        const ev = (try loop.nextEvent(null)) orelse continue;
        switch (ev) {
            .key => |k| {
                if (k.matches('q', .{}) or k.matches('c', .{ .ctrl = true })) break;
                if (k.matches(tuiste.Key.up, .{})) scroll -|= 1;
                if (k.matches(tuiste.Key.down, .{})) scroll +|= 1;
            },
            .mouse => |m| switch (m.button) {
                .wheel_up => scroll -|= 1,
                .wheel_down => scroll +|= 1,
                else => {},
            },
            .resize => |size| try term.resize(size),
            else => {},
        }
    }
}
