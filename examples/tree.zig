//! An expand/collapse tree — dogfoods widgets.Tree: the app owns a flat
//! pre-order node array (and its expanded flags), markers and guide lines
//! are user-defined, and selection survives collapses elsewhere.
//! Arrows navigate (right expands/steps in, left collapses/steps out),
//! enter or space toggles, a mouse click selects, q or ctrl+c quits.
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

    // The app owns the tree: a flat pre-order array, expansion included.
    var nodes = [_]widgets.Tree.Node{
        .{ .label = "resepte", .depth = 0 },
        .{ .label = "soet", .depth = 1 },
        .{ .label = "melktert.md", .depth = 2 },
        .{ .label = "koeksisters.md", .depth = 2 },
        .{ .label = "malva-poeding.md", .depth = 2 },
        .{ .label = "sout", .depth = 1 },
        .{ .label = "bobotie.md", .depth = 2 },
        .{ .label = "potjiekos.md", .depth = 2 },
        .{ .label = "braai", .depth = 2, .expanded = false },
        .{ .label = "sosaties.md", .depth = 3 },
        .{ .label = "snoek.md", .depth = 3 },
        .{ .label = "drank", .depth = 1, .expanded = false },
        .{ .label = "moerkoffie.md", .depth = 2 },
        .{ .label = "notas.txt", .depth = 0 },
    };

    var state: widgets.Tree.State = .{ .selected = 0 };
    var tree_at: tuiste.Rect = .{};

    while (true) {
        const frame = tuiste.Region.full(term.frame());
        var rows: [2]tuiste.Rect = undefined;
        const split = tuiste.layout.split(
            frame.bounds(),
            .vertical,
            &.{ .{ .fill = 1 }, .{ .len = 1 } },
            &rows,
        );

        const tree: widgets.Tree = .{
            .nodes = &nodes,
            // User-defined markers: tree(1)-style guide lines.
            .markers = .{
                .collapsed = "▸ ",
                .expanded = "▾ ",
                .leaf = "· ",
                .continues = "│ ",
                .done = "  ",
            },
            .selected_opts = .{ .fg = .{ .ansi = 0 }, .bg = .{ .ansi = 2 } },
        };
        const inner = (widgets.Block{
            .title = " lêers ",
            .lines = .rounded,
            .style = .{ .fg = .{ .indexed = 244 } },
        }).draw(frame.sub(split[0]));
        tree.draw(inner, &state);
        tree_at = inner.rect;

        _ = frame.sub(split[1]).writeText(0, 0, " pyle beweeg, ←/→ vou, enter wissel, q sluit ", .{ .attrs = .{ .reverse = true } });

        try term.render();

        const ev = (try loop.nextEvent(null)) orelse continue;
        switch (ev) {
            .key => |k| {
                if (k.kind == .release) continue;
                if (k.matches('q', .{}) or k.matches('c', .{ .ctrl = true })) break;
                _ = state.handleKey(k, &nodes);
            },
            .mouse => |m| {
                if (m.kind == .press and m.button == .left and tree_at.contains(m.col, m.row)) {
                    if (tree.hitTest(state, m.row - tree_at.y)) |hit| state.selected = hit;
                }
            },
            .resize => |size| try term.resize(size),
            else => {},
        }
    }
}
