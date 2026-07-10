//! A selectable list in a bordered block — dogfoods List (app-owned
//! selection/scroll state) with keyboard and mouse. Up/down or j/k moves,
//! click selects, the wheel scrolls, enter "orders"; q or ctrl+c quits.
const std = @import("std");
const tuiste = @import("tuiste");

pub const panic = tuiste.panic;

const disse = [_][]const u8{
    "bobotie",
    "melktert",
    "koeksisters",
    "boerewors met pap",
    "potjiekos",
    "biltong",
    "vetkoek met maalvleis",
    "bunny chow",
    "sosaties",
    "malva poeding",
    "frikkadelle",
    "waterblommetjiebredie",
    "snoek op die kole",
    "beskuit",
    "hertzoggies",
};

pub fn main(init: std.process.Init) !void {
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_alloc.deinit();
    const gpa = debug_alloc.allocator();

    var term = try tuiste.Terminal.init(gpa, init.io, .{ .mouse = true });
    defer term.deinit();

    var loop = try tuiste.Loop.init(gpa, &term.tty);
    defer loop.deinit();
    _ = try term.detectCaps(&loop, 300);

    var state: tuiste.widgets.List.State = .{ .selected = 0 };
    var bestel: ?usize = null; // last "ordered" dish

    const list: tuiste.widgets.List = .{
        .items = &disse,
        .marker = "> ",
        .selected_opts = .{ .fg = .{ .ansi = 0 }, .bg = .{ .ansi = 3 } },
    };

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
            .title = " spyskaart ",
            .lines = .rounded,
            .style = .{ .fg = .{ .indexed = 244 } },
        };
        const inner = block.draw(frame.sub(split[0]));
        list.draw(inner, &state);

        var bar_buf: [96]u8 = undefined;
        const bar = std.fmt.bufPrint(&bar_buf, " {s} — ↑/↓ kies, enter bestel, q sluit ", .{
            if (bestel) |b| disse[b] else "niks bestel nie",
        }) catch unreachable;
        _ = frame.sub(split[1]).writeText(0, 0, bar, .{ .attrs = .{ .reverse = true } });

        try term.render();

        const ev = (try loop.nextEvent(null)) orelse continue;
        switch (ev) {
            .key => |k| {
                if (k.matches('q', .{}) or k.matches('c', .{ .ctrl = true })) break;
                // app bindings first, then the widget's standard ones
                if (k.matches('j', .{})) {
                    state.selectNext(disse.len);
                } else if (k.matches('k', .{})) {
                    state.selectPrev(disse.len);
                } else if (k.matches(tuiste.Key.enter, .{})) {
                    bestel = state.selected;
                } else {
                    _ = state.handleKey(k, disse.len);
                }
            },
            .mouse => |m| switch (m.button) {
                // draw keeps the selection visible, so scrolling moves it
                .wheel_down => state.selectNext(disse.len),
                .wheel_up => state.selectPrev(disse.len),
                .left => if (m.kind == .press and inner.rect.contains(m.col, m.row)) {
                    if (list.hitTest(state, m.row - inner.rect.y)) |hit| state.selected = hit;
                },
                else => {},
            },
            .resize => |size| try term.resize(size),
            else => {},
        }
    }
}
