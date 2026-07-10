//! Scrolling log pane above a fixed status bar — exercises the scroll-region
//! hint API. A new line arrives every 50ms (driven by the nextEvent timeout);
//! once the pane is full, each frame scrolls the pane with a hardware scroll
//! and repaints only the new bottom line. Quit with q or ctrl+c.
const std = @import("std");
const tuiste = @import("tuiste");

pub const panic = tuiste.panic;

const ring_size = 256;
const line_cap = 64;

pub fn main(init: std.process.Init) !void {
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_alloc.deinit();
    const gpa = debug_alloc.allocator();

    var term = try tuiste.Terminal.init(gpa, init.io, .{});
    defer term.deinit();

    var loop = try tuiste.Loop.init(gpa, &term.tty);
    defer loop.deinit();
    _ = try term.detectCaps(&loop, 300);

    var ring: [ring_size][line_cap]u8 = undefined;
    var ring_lens: [ring_size]usize = undefined;
    var total: usize = 0;
    var scrolled = false;

    while (true) {
        const frame = tuiste.Region.full(term.frame());
        // Log pane above a one-row status bar.
        var rows: [2]tuiste.Rect = undefined;
        const split = tuiste.layout.split(
            frame.bounds(),
            .vertical,
            &.{ .{ .fill = 1 }, .{ .len = 1 } },
            &rows,
        );
        const pane = frame.sub(split[0]);
        const bar = frame.sub(split[1]);
        const pane_rows: usize = pane.height();

        const visible = @min(total, @min(pane_rows, ring_size));
        for (0..visible) |i| {
            const idx = (total - visible + i) % ring_size;
            _ = pane.writeText(0, @intCast(i), ring[idx][0..ring_lens[idx]], .{});
        }

        var status_buf: [96]u8 = undefined;
        const status = std.fmt.bufPrint(&status_buf, " {d} lines — q quits ", .{total}) catch unreachable;
        _ = bar.writeText(0, 0, status, .{ .attrs = .{ .reverse = true } });

        if (scrolled and pane_rows > 0) {
            term.scrollUp(0, pane.height() - 1, 1);
            scrolled = false;
        }
        try term.render();

        const ev = (try loop.nextEvent(50)) orelse {
            // Timeout: a new log line arrives.
            const slot = total % ring_size;
            ring_lens[slot] = (std.fmt.bufPrint(&ring[slot], "{d:>6}  the quick brown fox jumps over the lazy dog", .{
                total,
            }) catch unreachable).len;
            // The pane's content shifts only once it was already full.
            scrolled = total >= pane_rows;
            total += 1;
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
