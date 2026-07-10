//! An editable single-line text field — dogfoods widgets.TextField: the
//! buffer/cursor/scroll state is app-owned, editing is grapheme-aware
//! (é, 宽, 👍 move and delete as units), the field scrolls horizontally,
//! and bracketed paste inserts through the same state. ctrl+y copies the
//! field via OSC 52. Quit with Escape or ctrl+c.
const std = @import("std");
const tuiste = @import("tuiste");

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

    var field_buf: [1024]u8 = undefined;
    var field = tuiste.widgets.TextField.State.init(&field_buf);
    var pasted_bytes: usize = 0;

    const tf: tuiste.widgets.TextField = .{
        .placeholder = "tik iets…",
    };

    while (true) {
        const frame = tuiste.Region.full(term.frame());
        _ = frame.writeText(2, 1, "tuiste input example", .{ .attrs = .{ .bold = true } });
        _ = frame.writeText(2, 2, "arrows, home/end, backspace/delete, ctrl+u clears, ctrl+y copies — esc or ctrl+c quits", .{ .fg = .{ .indexed = 244 } });

        const block: tuiste.widgets.Block = .{
            .lines = .rounded,
            .style = .{ .fg = .{ .indexed = 244 } },
        };
        const inner = block.draw(frame.sub(.{ .x = 2, .y = 4, .width = frame.width() -| 4, .height = 3 }));
        if (tf.draw(inner, &field)) |cur| {
            term.setCursor(.{ .x = cur.x, .y = cur.y, .shape = .bar });
        }

        var status_buf: [96]u8 = undefined;
        const status = std.fmt.bufPrint(&status_buf, "bytes: {d}   columns: {d}   cursor byte: {d}   last paste: {d}B", .{
            field.len,
            tuiste.unicode.strWidth(field.text()),
            field.cursor,
            pasted_bytes,
        }) catch unreachable;
        _ = frame.writeText(2, 8, status, .{ .fg = .{ .indexed = 244 } });

        try term.render();

        const ev = (try loop.nextEvent(null)) orelse continue;
        switch (ev) {
            .key => |k| {
                if (k.kind == .release) continue;
                if (k.matches(tuiste.Key.escape, .{}) or k.matches('c', .{ .ctrl = true })) break;
                if (k.matches('y', .{ .ctrl = true })) {
                    try term.copyToClipboard(field.text());
                } else {
                    _ = field.handleKey(k);
                }
            },
            .paste => |text| {
                field.insert(text);
                pasted_bytes = text.len;
            },
            .resize => |size| try term.resize(size),
            else => {},
        }
    }
}
