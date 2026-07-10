//! Dashboard — dogfoods the second widget batch in one screen: Tabs switch
//! between an overview pane (Spinner, Gauge, Separator, Paragraph) and a
//! task pane (Table + Scrollbar); 'm' opens a modal (Clear + Block) over
//! everything. 1/2 or tab or a mouse click switches tabs, j/k or arrows
//! move the table selection, q or ctrl+c quits.
const std = @import("std");
const tuiste = @import("tuiste");
const widgets = tuiste.widgets;

pub const panic = tuiste.panic;

const take = [_][]const []const u8{
    &.{ "1", "koeksisters vleg", "besig" },
    &.{ "2", "melktert bak", "wag" },
    &.{ "3", "boerewors draai", "klaar" },
    &.{ "4", "potjie pak", "besig" },
    &.{ "5", "biltong sny", "klaar" },
    &.{ "6", "vetkoek vorm", "wag" },
    &.{ "7", "sosaties ryg", "besig" },
    &.{ "8", "beskuit droog", "wag" },
    &.{ "9", "malva meng", "klaar" },
    &.{ "10", "bobotie kerrie", "besig" },
    &.{ "11", "bredie prut", "wag" },
    &.{ "12", "snoek braai", "wag" },
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

    var tab: usize = 0;
    var tick: usize = 0;
    var modal = false;
    var table_state: widgets.Table.State = .{ .selected = 0 };
    var tabs_at: tuiste.Rect = .{};
    const tab_titles: []const []const u8 = &.{ " oorsig ", " take " };

    while (true) {
        const frame = tuiste.Region.full(term.frame());
        var rows: [3]tuiste.Rect = undefined;
        const split = tuiste.layout.split(
            frame.bounds(),
            .vertical,
            &.{ .{ .len = 1 }, .{ .fill = 1 }, .{ .len = 1 } },
            &rows,
        );

        const tabs: widgets.Tabs = .{ .titles = tab_titles, .selected = tab };
        const tab_region = frame.sub(split[0]);
        tabs.draw(tab_region);
        tabs_at = tab_region.rect;

        const pane = (widgets.Block{
            .lines = .rounded,
            .style = .{ .fg = .{ .indexed = 244 } },
        }).draw(frame.sub(split[1]));

        switch (tab) {
            0 => {
                (widgets.Spinner{ .tick = tick, .opts = .{ .fg = .{ .ansi = 6 } } })
                    .draw(pane.sub(.{ .x = 1, .width = 2, .height = 1 }));
                _ = pane.writeText(3, 0, "kombuis draai op volle sterkte", .{});

                const vordering: f32 = @floatFromInt(tick % 100);
                (widgets.Gauge{
                    .ratio = vordering / 100.0,
                    .opts = .{ .fg = .{ .ansi = 2 } },
                }).draw(pane.sub(.{ .x = 1, .y = 2, .width = pane.width() -| 2, .height = 1 }));

                (widgets.Separator{ .label = " vandag ", .style = .{ .fg = .{ .indexed = 244 } } })
                    .draw(pane.sub(.{ .y = 4, .width = pane.width(), .height = 1 }));

                // btop-style rolling area graph: braille packs two samples
                // per cell, so feed it double the columns
                var pols: [160]f64 = undefined;
                for (0..pols.len) |i| {
                    const t = @as(f64, @floatFromInt(tick * 2 + i)) * 0.18;
                    pols[i] = @abs(@sin(t)) + 0.2 * @abs(@sin(t * 3.7));
                }
                (widgets.Sparkline{
                    .values = &pols,
                    .style = .{ .fg = .{ .ansi = 6 } },
                    .marker = .braille,
                }).draw(pane.sub(.{ .x = 1, .y = 5, .width = pane.width() -| 2, .height = 2 }));

                _ = (widgets.Paragraph{
                    .text = "Alles hierbo leef in een teken-lus: die spinner en die " ++
                        "meter loop op 'n toepassings-eie tik-teller, die skeier " ++
                        "hergebruik die raam se lynstyle, en die tabel op die " ++
                        "tweede oortjie deel sy keuse-logika met die lys-widget.",
                }).draw(pane.sub(.{ .x = 1, .y = 8, .width = pane.width() -| 2, .height = pane.height() -| 8 }));
            },
            else => {
                const body_h = pane.height() -| widgets.Table.header_height;
                const table_region = pane.sub(.{ .width = pane.width() -| 2, .height = pane.height() });
                (widgets.Table{
                    .columns = &.{
                        .{ .header = "nr", .width = .{ .len = 3 } },
                        .{ .header = "taak", .width = .{ .fill = 1 } },
                        .{ .header = "status", .width = .{ .len = 6 } },
                    },
                    .rows = &take,
                    .selected_opts = .{ .fg = .{ .ansi = 0 }, .bg = .{ .ansi = 6 } },
                }).draw(table_region, &table_state);

                (widgets.Scrollbar{
                    .total = take.len,
                    .window = body_h,
                    .offset = table_state.offset,
                    .style = .{ .fg = .{ .indexed = 244 } },
                }).draw(pane.sub(.{
                    .x = pane.width() -| 1,
                    .y = widgets.Table.header_height,
                    .width = 1,
                    .height = body_h,
                }));
            },
        }

        _ = frame.sub(split[2]).writeText(0, 0, " 1/2 of tab wissel, j/k kies, m boodskap, q sluit ", .{ .attrs = .{ .reverse = true } });

        if (modal) {
            const box = frame.bounds().centered(36, 5);
            (widgets.Clear{}).draw(frame.sub(box));
            const inner = (widgets.Block{
                .title = " boodskap ",
                .lines = .double,
                .style = .{ .fg = .{ .ansi = 3 } },
            }).draw(frame.sub(box));
            _ = (widgets.Paragraph{
                .text = "Die kombuis is oop! Enige knoppie maak hierdie boodskap toe.",
            }).draw(inner.sub(.{ .x = 1, .width = inner.width() -| 2, .height = inner.height() }));
        }

        try term.render();

        const ev = (try loop.nextEvent(120)) orelse {
            tick += 1;
            continue;
        };
        switch (ev) {
            .key => |k| {
                if (k.kind == .release) continue;
                if (modal) {
                    modal = false;
                    continue;
                }
                if (k.matches('q', .{}) or k.matches('c', .{ .ctrl = true })) break;
                if (k.matches('m', .{})) modal = true;
                if (k.matches('1', .{})) tab = 0;
                if (k.matches('2', .{})) tab = 1;
                if (k.matches(tuiste.Key.tab, .{})) tab = (tab + 1) % 2;
                // app bindings first, then the table's standard ones
                if (k.matches('j', .{})) {
                    table_state.selectNext(take.len);
                } else if (k.matches('k', .{})) {
                    table_state.selectPrev(take.len);
                } else {
                    _ = table_state.handleKey(k, take.len);
                }
            },
            .mouse => |m| {
                if (m.kind == .press and m.button == .left and tabs_at.contains(m.col, m.row)) {
                    const bar: widgets.Tabs = .{ .titles = tab_titles };
                    if (bar.hitTest(m.col - tabs_at.x)) |i| tab = i;
                }
            },
            .resize => |size| try term.resize(size),
            else => {},
        }
    }
}
