//! An animated XY chart — dogfoods widgets.Chart and the braille plotting
//! under it: two line datasets (sin and cos) drift across labeled axes,
//! with a legend in the plot corner. Quit with q or ctrl+c.
const std = @import("std");
const tuiste = @import("tuiste");
const widgets = tuiste.widgets;

pub const panic = tuiste.panic;

const samples = 120;

pub fn main(init: std.process.Init) !void {
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_alloc.deinit();
    const gpa = debug_alloc.allocator();

    var term = try tuiste.Terminal.init(gpa, init.io, .{});
    defer term.deinit();

    var loop = try tuiste.Loop.init(gpa, &term.tty);
    defer loop.deinit();
    _ = try term.detectCaps(&loop, 300);

    var tick: usize = 0;
    var sin_pts: [samples][2]f64 = undefined;
    var cos_pts: [samples][2]f64 = undefined;

    while (true) {
        const phase = @as(f64, @floatFromInt(tick)) * 0.15;
        for (0..samples) |i| {
            const x = @as(f64, @floatFromInt(i));
            const t = x * 4.0 * std.math.pi / samples + phase;
            sin_pts[i] = .{ x, @sin(t) };
            cos_pts[i] = .{ x, @cos(t) };
        }

        const frame = tuiste.Region.full(term.frame());
        const inner = (widgets.Block{
            .title = " sin & cos ",
            .lines = .rounded,
            .style = .{ .fg = .{ .indexed = 244 } },
        }).draw(frame);

        (widgets.Chart{
            .datasets = &.{
                .{ .name = "sin", .points = &sin_pts, .style = .{ .fg = .{ .ansi = 2 } } },
                .{ .name = "cos", .points = &cos_pts, .style = .{ .fg = .{ .ansi = 5 } } },
            },
            .x_bounds = .{ 0, samples - 1 },
            .y_bounds = .{ -1, 1 },
            .x_labels = &.{ "0", "2π", "4π" },
            .y_labels = &.{ "-1", "0", "1" },
            .axis_style = .{ .fg = .{ .indexed = 244 } },
        }).draw(inner);

        try term.render();

        const ev = (try loop.nextEvent(80)) orelse {
            tick += 1;
            continue;
        };
        switch (ev) {
            .key => |k| {
                if (k.matches('q', .{}) or k.matches('c', .{ .ctrl = true })) break;
            },
            .resize => |size| try term.resize(size),
            else => {},
        }
    }
}
