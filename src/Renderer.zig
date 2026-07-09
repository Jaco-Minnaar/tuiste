//! Double buffer + diff. Compares the freshly drawn back surface against the
//! front surface (what's on screen), emits the minimal escape output, and
//! copies changed cells forward. Allocation-free after init/resize.
const Renderer = @This();

const std = @import("std");
const Io = std.Io;
const Surface = @import("Surface.zig");
const cell_mod = @import("cell.zig");
const Cell = cell_mod.Cell;
const Style = cell_mod.Style;
const ctlseqs = @import("ctlseqs.zig");
const Caps = @import("caps.zig").Caps;
const GraphemePool = @import("GraphemePool.zig");

/// What is currently on screen.
front: Surface,
/// What user code draws into for the next frame (via `Terminal.frame`).
back: Surface,
/// Shared by both surfaces so pooled cells diff by index. Heap-allocated
/// because the surfaces hold pointers to it and Renderer moves by value.
pool: *GraphemePool,

/// A cell that can never equal a drawn cell (back cells always have len >= 1
/// except spacers, which carry width 0 in both buffers consistently).
const invalid_cell: Cell = .{ .len = 0, .width = 1 };

pub fn init(gpa: std.mem.Allocator, cols: u16, rows: u16) !Renderer {
    const pool = try gpa.create(GraphemePool);
    errdefer gpa.destroy(pool);
    pool.* = GraphemePool.init(gpa);
    errdefer pool.deinit();

    var front = try Surface.init(gpa, cols, rows);
    errdefer front.deinit(gpa);
    var back = try Surface.init(gpa, cols, rows);
    front.fill(invalid_cell);
    front.pool = pool;
    back.pool = pool;
    return .{ .front = front, .back = back, .pool = pool };
}

pub fn deinit(self: *Renderer, gpa: std.mem.Allocator) void {
    self.front.deinit(gpa);
    self.back.deinit(gpa);
    self.pool.deinit();
    gpa.destroy(self.pool);
    self.* = undefined;
}

pub fn resize(self: *Renderer, gpa: std.mem.Allocator, cols: u16, rows: u16) !void {
    try self.front.resize(gpa, cols, rows);
    try self.back.resize(gpa, cols, rows);
    self.invalidate();
}

/// Force the next render to redraw every cell.
pub fn invalidate(self: *Renderer) void {
    self.front.fill(invalid_cell);
}

/// Diff back against front and write the delta. The caller flushes.
pub fn render(self: *Renderer, writer: *Io.Writer, caps: Caps) !void {
    if (caps.synchronized_output) try writer.writeAll(ctlseqs.sync_begin);

    var last_style: ?Style = null;
    // Cursor position after the last write; start impossible to force a CUP.
    var cx: u32 = std.math.maxInt(u32);
    var cy: u32 = std.math.maxInt(u32);

    var y: u16 = 0;
    while (y < self.back.height) : (y += 1) {
        var x: u16 = 0;
        while (x < self.back.width) : (x += 1) {
            const b = self.back.cellAt(x, y).?.*;
            const f = self.front.cellAt(x, y).?;
            if (b.eql(f.*)) continue;
            f.* = b;
            // Spacers carry no glyph; the wide cell to their left draws them.
            if (b.width == 0) continue;

            if (cx != x or cy != y) try ctlseqs.cup(writer, y + 1, x + 1);
            if (last_style == null or !last_style.?.eql(b.style)) {
                try ctlseqs.sgr(writer, b.style);
                last_style = b.style;
            }
            try writer.writeAll(self.back.graphemeOf(b));
            cx = @as(u32, x) + b.width;
            cy = y;
        }
    }

    if (last_style != null) try writer.writeAll(ctlseqs.sgr_reset);
    if (caps.synchronized_output) try writer.writeAll(ctlseqs.sync_end);
}

test "render diffs only changed cells" {
    const gpa = std.testing.allocator;
    var r = try Renderer.init(gpa, 4, 2);
    defer r.deinit(gpa);

    // First frame: everything invalid → full paint of the (blank) back buffer.
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try r.render(&w, .{});
    try std.testing.expect(w.buffered().len > 0);

    // Nothing changed → nothing emitted.
    var w2: Io.Writer = .fixed(&buf);
    try r.render(&w2, .{});
    try std.testing.expectEqualStrings("", w2.buffered());

    // One cell changed → exactly one CUP, one glyph.
    _ = r.back.writeText(1, 1, "A", .{});
    var w3: Io.Writer = .fixed(&buf);
    try r.render(&w3, .{});
    const out = w3.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[2;2H") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "A") != null);
}

test "pooled graphemes render full bytes and diff stable" {
    const gpa = std.testing.allocator;
    var r = try Renderer.init(gpa, 6, 1);
    defer r.deinit(gpa);

    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try r.render(&w, .{}); // settle first frame

    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}";
    _ = r.back.writeText(0, 0, family, .{});
    var w2: Io.Writer = .fixed(&buf);
    try r.render(&w2, .{});
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), family) != null);

    // Redrawing the identical frame emits nothing: pooled cells diff by index.
    r.back.clear();
    _ = r.back.writeText(0, 0, family, .{});
    var w3: Io.Writer = .fixed(&buf);
    try r.render(&w3, .{});
    try std.testing.expectEqualStrings("", w3.buffered());
}

test "adjacent cells reuse cursor position" {
    const gpa = std.testing.allocator;
    var r = try Renderer.init(gpa, 8, 1);
    defer r.deinit(gpa);

    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try r.render(&w, .{}); // settle first frame

    _ = r.back.writeText(2, 0, "ab", .{});
    var w2: Io.Writer = .fixed(&buf);
    try r.render(&w2, .{});
    // one cursor move for the run of two cells
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, w2.buffered(), "\x1b["[0..2]) - std.mem.count(u8, w2.buffered(), "\x1b[0"),
    );
}
