//! A multi-line editor — dogfoods widgets.TextArea: contiguous app-owned
//! buffer, word-wrapped display, cursor motion over wrapped rows with a
//! sticky column, click-to-place, paste, and OSC 52 copy (ctrl+y copies
//! the whole buffer). Quit with Escape or ctrl+c.
const std = @import("std");
const tuiste = @import("tuiste");
const widgets = tuiste.widgets;

pub const panic = tuiste.panic;

pub fn main(init: std.process.Init) !void {
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_alloc.deinit();
    const gpa = debug_alloc.allocator();

    var term = try tuiste.Terminal.init(gpa, init.io, .{ .mouse = true });
    defer term.deinit();

    var loop = try tuiste.Loop.init(gpa, &term.tty);
    defer loop.deinit();
    _ = try term.detectCaps(&loop, 300);

    var text_buf: [8192]u8 = undefined;
    var ta_state = widgets.TextArea.State.init(&text_buf);
    ta_state.insert("Tik hier. Woorde vou grafeem-bewus; pyle beweeg oor die " ++
        "gevoude reëls met 'n klewerige kolom.\n\nPlak werk ook — probeer dit.");
    ta_state.cursor = 0;

    const ta: widgets.TextArea = .{};
    var editor_at: tuiste.Rect = .{};

    while (true) {
        const frame = tuiste.Region.full(term.frame());
        var rows: [2]tuiste.Rect = undefined;
        const split = tuiste.layout.split(
            frame.bounds(),
            .vertical,
            &.{ .{ .fill = 1 }, .{ .len = 1 } },
            &rows,
        );

        const inner = (widgets.Block{
            .title = " notas ",
            .lines = .rounded,
            .style = .{ .fg = .{ .indexed = 244 } },
        }).draw(frame.sub(split[0]));
        editor_at = inner.rect;

        var cursor_col: u16 = 0;
        var cursor_row: u16 = 0;
        if (ta.draw(inner, &ta_state)) |cur| {
            cursor_col = cur.x - inner.rect.x;
            cursor_row = cur.y - inner.rect.y;
            term.setCursor(.{ .x = cur.x, .y = cur.y, .shape = .bar });
        }

        var bar_buf: [96]u8 = undefined;
        const bar = std.fmt.bufPrint(&bar_buf, " {d}B  reël {d} kol {d} — ctrl+y kopieer, esc sluit ", .{
            ta_state.len,
            ta_state.scroll + cursor_row + 1,
            cursor_col + 1,
        }) catch unreachable;
        _ = frame.sub(split[1]).writeText(0, 0, bar, .{ .attrs = .{ .reverse = true } });

        try term.render();

        const ev = (try loop.nextEvent(null)) orelse continue;
        switch (ev) {
            .key => |k| {
                if (k.kind == .release) continue;
                if (k.matches(tuiste.Key.escape, .{}) or k.matches('c', .{ .ctrl = true })) break;
                if (k.matches('y', .{ .ctrl = true })) {
                    try term.copyToClipboard(ta_state.text());
                } else {
                    _ = ta_state.handleKey(k);
                }
            },
            .paste => |text| ta_state.insert(text),
            .mouse => |m| {
                if (m.kind == .press and m.button == .left and editor_at.contains(m.col, m.row)) {
                    if (ta.hitTest(ta_state, m.col - editor_at.x, m.row - editor_at.y)) |off| {
                        ta_state.cursor = off;
                        ta_state.desired_col = null;
                    }
                }
            },
            .resize => |size| try term.resize(size),
            else => {},
        }
    }
}
