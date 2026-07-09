//! Scaffold demo: draws styled text, echoes input events, handles resize.
//! Quit with q or ctrl+c.
const std = @import("std");
const tuiste = @import("tuiste");

/// Restore the terminal before panic output (try it: press p).
pub const panic = tuiste.panic;

pub fn main(init: std.process.Init) !void {
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_alloc.deinit();
    const gpa = debug_alloc.allocator();

    var term = try tuiste.Terminal.init(gpa, init.io, .{ .mouse = true });
    defer term.deinit();

    var loop = try tuiste.Loop.init(&term.tty);
    const caps = try term.detectCaps(&loop, 300);

    var last_buf: [128]u8 = undefined;
    var last: []const u8 = "(none yet — press keys, click, resize)";
    var events: u64 = 0;

    while (true) {
        var frame = term.frame();
        _ = frame.writeText(2, 1, "tuiste scaffold demo", .{ .attrs = .{ .bold = true } });
        _ = frame.writeText(2, 2, "press q or ctrl+c to quit", .{ .fg = .{ .indexed = 244 } });
        _ = frame.writeText(2, 4, "unicode: héllo 宽字符 👍 👨‍👩‍👧‍👦", .{ .fg = .{ .ansi = 2 } });

        var line_buf: [64]u8 = undefined;
        const status = std.fmt.bufPrint(&line_buf, "size: {d}x{d}   events: {d}", .{
            frame.width, frame.height, events,
        }) catch unreachable;
        _ = frame.writeText(2, 5, status, .{ .fg = .{ .indexed = 244 } });

        var caps_buf: [64]u8 = undefined;
        const caps_line = std.fmt.bufPrint(&caps_buf, "caps: kitty={} sync={}", .{
            caps.kitty_keyboard, caps.synchronized_output,
        }) catch unreachable;
        _ = frame.writeText(2, 6, caps_line, .{ .fg = .{ .indexed = 244 } });

        _ = frame.writeText(2, 7, "last event: ", .{});
        _ = frame.writeText(14, 7, last, .{ .fg = .{ .rgb = .{ 0xff, 0xaf, 0x00 } } });
        try term.render();

        const ev = (try loop.nextEvent(null)) orelse continue;
        events += 1;
        switch (ev) {
            .key => |k| {
                if (k.matches('q', .{}) or k.matches('c', .{ .ctrl = true })) break;
                if (k.matches('p', .{})) @panic("deliberate demo panic — the terminal should be usable now");
                last = std.fmt.bufPrint(&last_buf, "key cp={d} '{u}' ctrl={} alt={} shift={}", .{
                    k.codepoint,
                    if (k.codepoint >= ' ' and k.codepoint != 127) k.codepoint else ' ',
                    k.mods.ctrl,
                    k.mods.alt,
                    k.mods.shift,
                }) catch last;
            },
            .mouse => |m| {
                last = std.fmt.bufPrint(&last_buf, "mouse {s} {s} at {d},{d}", .{
                    @tagName(m.button), @tagName(m.kind), m.col, m.row,
                }) catch last;
            },
            .resize => |size| {
                try term.resize(size);
                last = std.fmt.bufPrint(&last_buf, "resize to {d}x{d}", .{
                    size.cols, size.rows,
                }) catch last;
            },
            else => {
                last = std.fmt.bufPrint(&last_buf, "{s}", .{@tagName(ev)}) catch last;
            },
        }
    }
}
