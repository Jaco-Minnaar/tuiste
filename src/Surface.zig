//! A 2D grid of cells that user code draws into each frame.
//! All writes are clipped to the surface bounds — drawing off-screen is a no-op.
const Surface = @This();

const std = @import("std");
const cell_mod = @import("cell.zig");
const Cell = cell_mod.Cell;
const Style = cell_mod.Style;
const unicode = @import("unicode.zig");
const GraphemePool = @import("GraphemePool.zig");
const Rect = @import("Rect.zig");

width: u16,
height: u16,
cells: []Cell,
/// Where graphemes too long for a Cell's inline buffer get interned.
/// Without one (standalone surfaces) they degrade to U+FFFD. The Renderer
/// points both of its surfaces at the same pool.
pool: ?*GraphemePool = null,

pub fn init(gpa: std.mem.Allocator, width: u16, height: u16) std.mem.Allocator.Error!Surface {
    const cells = try gpa.alloc(Cell, @as(usize, width) * height);
    @memset(cells, .{});
    return .{ .width = width, .height = height, .cells = cells };
}

pub fn deinit(self: *Surface, gpa: std.mem.Allocator) void {
    gpa.free(self.cells);
    self.* = undefined;
}

pub fn resize(self: *Surface, gpa: std.mem.Allocator, width: u16, height: u16) std.mem.Allocator.Error!void {
    const new_cells = try gpa.realloc(self.cells, @as(usize, width) * height);
    self.cells = new_cells;
    self.width = width;
    self.height = height;
    self.clear();
}

/// Reset every cell to the default (styled space).
pub fn clear(self: *Surface) void {
    @memset(self.cells, .{});
}

pub fn fill(self: *Surface, c: Cell) void {
    @memset(self.cells, c);
}

/// The whole surface as a rectangle.
pub fn bounds(self: *const Surface) Rect {
    return .{ .width = self.width, .height = self.height };
}

pub fn cellAt(self: *const Surface, x: u16, y: u16) ?*Cell {
    if (x >= self.width or y >= self.height) return null;
    return &self.cells[@as(usize, y) * self.width + x];
}

pub fn writeCell(self: *Surface, x: u16, y: u16, c: Cell) void {
    const dst = self.cellAt(x, y) orelse return;
    dst.* = c;
}

/// Everything `writeText` can apply to the text: the visual style plus an
/// optional OSC 8 hyperlink. Anonymous literals with only style fields
/// coerce unchanged, so plain styled writes look the same as before.
pub const Options = struct {
    fg: cell_mod.Color = .default,
    bg: cell_mod.Color = .default,
    attrs: cell_mod.Attrs = .{},
    /// Hyperlink target (e.g. "https://…"), interned like oversized
    /// graphemes. Dropped — never an error — without a pool, on OOM, or if
    /// it contains bytes a URI can't carry raw (controls, spaces, DEL+).
    link: ?[]const u8 = null,
    /// Explicit OSC 8 link id: cells with the same URI *and* id are one
    /// link to the terminal, so use distinct ids for same-URI links that
    /// should hover separately. Without one, the Renderer derives an id
    /// from the URI (all writes of a URI hover as one link). Invalid ids
    /// (empty, `;`/`:`/`~`, non-printable-ASCII, oversized) fall back to
    /// the derived id rather than dropping the link.
    link_id: ?[]const u8 = null,

    fn style(self: Options) Style {
        return .{ .fg = self.fg, .bg = self.bg, .attrs = self.attrs };
    }
};

/// Write UTF-8 text starting at (x, y), grapheme- and width-aware.
/// Wide graphemes take two cells (the second becomes a spacer). Text is
/// clipped at the right edge; a wide grapheme that would straddle it is
/// dropped. Returns the number of columns written.
pub fn writeText(self: *Surface, x: u16, y: u16, text: []const u8, opts: Options) u16 {
    return self.writeTextClipped(self.bounds(), x, y, text, opts);
}

/// `writeText` clipped to `clip` instead of the surface edges — the plumbing
/// under `Region.writeText`. Coordinates stay surface-absolute; `clip` must
/// lie within the surface and (x, y) must not be left of it. Zero-width
/// folding also respects the clip, so a mark never composes onto a glyph
/// outside it.
pub fn writeTextClipped(self: *Surface, clip: Rect, x: u16, y: u16, text: []const u8, opts: Options) u16 {
    if (y < clip.y or y >= @as(u32, clip.y) + clip.height) return 0;
    const style = opts.style();
    const link = self.internLink(opts.link, opts.link_id);
    var col: u16 = x;
    var iter = unicode.graphemeIterator(text);
    while (iter.next()) |g| {
        const bytes = g.bytes(text);
        const w = unicode.graphemeWidth(bytes);
        if (w == 0) {
            // A zero-width cluster of its own (bare combining mark, ZWSP…):
            // compose it onto the glyph to the left of the write position.
            self.foldZeroWidth(clip, col, y, bytes);
            continue;
        }
        if (@as(u32, col) + w > @as(u32, clip.x) + clip.width) break;
        var c = self.makeCell(bytes, w, style);
        c.link = link;
        self.writeCell(col, y, c);
        if (w == 2) {
            var sp = Cell.spacer;
            sp.style = style;
            sp.link = link;
            self.writeCell(col + 1, y, sp);
        }
        col += w;
    }
    return col -| x;
}

/// Longest explicit-id link entry (`uri + \n + id`) built on the stack.
/// Past it the id degrades to derived — links themselves have no length cap.
const max_link_entry_bytes = 2048;

/// Intern a hyperlink, returning the `Cell.link` value (index + 1, or 0 for
/// none). A bare URI interns as itself; an explicit id interns as one
/// combined `uri\nid` entry, so the (URI, id) pair — the link's identity to
/// the terminal — is a single index and the diff stays a value compare.
/// Follows the pool's degradation rule: an unusable id falls back to the
/// derived one, anything else that can't be interned becomes "no link".
fn internLink(self: *Surface, uri: ?[]const u8, id: ?[]const u8) u32 {
    const uri_bytes = uri orelse return 0;
    const pool = self.pool orelse return 0;
    // Only printable ASCII may ride inside the OSC payload raw; anything
    // else (controls, the ST/BEL terminators, spaces) must have been
    // percent-encoded by the caller or the sequence would tear.
    for (uri_bytes) |b| {
        if (b < 0x21 or b > 0x7e) return 0;
    }
    if (validLinkId(id)) |id_bytes| {
        var buf: [max_link_entry_bytes]u8 = undefined;
        if (uri_bytes.len + 1 + id_bytes.len <= buf.len) {
            @memcpy(buf[0..uri_bytes.len], uri_bytes);
            buf[uri_bytes.len] = '\n';
            @memcpy(buf[uri_bytes.len + 1 ..][0..id_bytes.len], id_bytes);
            const entry = buf[0 .. uri_bytes.len + 1 + id_bytes.len];
            const idx = pool.intern(entry) orelse return 0;
            return idx + 1;
        }
    }
    const idx = pool.intern(uri_bytes) orelse return 0;
    return idx + 1;
}

/// An id usable inside the OSC 8 params: printable ASCII minus the params
/// separators (`;`, `:`) and `~`, which is reserved to prefix derived ids
/// so they can never collide with explicit ones.
fn validLinkId(id: ?[]const u8) ?[]const u8 {
    const bytes = id orelse return null;
    if (bytes.len == 0) return null;
    for (bytes) |b| {
        if (b < 0x21 or b > 0x7e or b == ';' or b == ':' or b == '~') return null;
    }
    return bytes;
}

/// Cap on a composed grapheme (base + folded marks). Past this we drop
/// further marks — a bound against pathological mark stacking (Zalgo text).
const max_fold_bytes = 128;

/// Append a zero-width mark's bytes to the glyph cell left of `col`,
/// stepping over a wide glyph's spacer, without reaching left of `clip`.
/// Degradation always keeps the base glyph: at worst the mark is dropped
/// (no cell to the left, spacer-only, fold cap hit, or pool unavailable
/// for an overflowing combination).
fn foldZeroWidth(self: *Surface, clip: Rect, col: u16, y: u16, mark: []const u8) void {
    if (col <= clip.x) return;
    var cx = col - 1;
    var target = self.cellAt(cx, y) orelse return;
    if (target.width == 0 and cx > clip.x) { // spacer: the glyph is one further left
        cx -= 1;
        target = self.cellAt(cx, y) orelse return;
    }
    if (target.width == 0) return;

    var buf: [max_fold_bytes]u8 = undefined;
    const base = self.graphemeOf(target.*);
    if (base.len + mark.len > buf.len) return;
    @memcpy(buf[0..base.len], base);
    @memcpy(buf[base.len..][0..mark.len], mark);
    const combined = buf[0 .. base.len + mark.len];

    const link = target.link;
    if (combined.len <= Cell.max_grapheme_bytes) {
        target.* = Cell.init(combined, target.width, target.style);
        target.link = link;
    } else if (self.pool) |pool| {
        if (pool.intern(combined)) |idx| {
            target.* = Cell.initPooled(idx, target.width, target.style);
            target.link = link;
        }
    }
}

/// Build a cell for one grapheme, interning through the pool when it
/// doesn't fit inline. Degrades to U+FFFD without a pool (or on OOM) so
/// the draw path never fails.
fn makeCell(self: *Surface, bytes: []const u8, width: u2, style: Style) Cell {
    if (bytes.len > Cell.max_grapheme_bytes) {
        if (self.pool) |pool| {
            if (pool.intern(bytes)) |idx| return Cell.initPooled(idx, width, style);
        }
    }
    return Cell.init(bytes, width, style);
}

/// Resolve a cell's grapheme, following the pool for overflowed cells.
pub fn graphemeOf(self: *const Surface, c: Cell) []const u8 {
    if (c.poolIndex()) |idx| {
        if (self.pool) |pool| return pool.get(idx);
    }
    return c.grapheme();
}

/// Resolve a cell's hyperlink URI, or null for unlinked cells.
pub fn linkOf(self: *const Surface, c: Cell) ?[]const u8 {
    const entry = self.linkEntryOf(c) orelse return null;
    const sep = std.mem.indexOfScalar(u8, entry, '\n') orelse return entry;
    return entry[0..sep];
}

/// A cell's explicit link id, or null (unlinked, or a derived-id link —
/// derivation is the Renderer's business).
pub fn linkIdOf(self: *const Surface, c: Cell) ?[]const u8 {
    const entry = self.linkEntryOf(c) orelse return null;
    const sep = std.mem.indexOfScalar(u8, entry, '\n') orelse return null;
    return entry[sep + 1 ..];
}

fn linkEntryOf(self: *const Surface, c: Cell) ?[]const u8 {
    if (c.link == 0) return null;
    const pool = self.pool orelse return null;
    return pool.get(c.link - 1);
}

test "writeText basic" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 10, 3);
    defer s.deinit(gpa);

    const n = s.writeText(1, 0, "hi", .{});
    try std.testing.expectEqual(@as(u16, 2), n);
    try std.testing.expectEqualStrings("h", s.cellAt(1, 0).?.grapheme());
    try std.testing.expectEqualStrings("i", s.cellAt(2, 0).?.grapheme());
    // untouched neighbors stay default
    try std.testing.expectEqualStrings(" ", s.cellAt(0, 0).?.grapheme());
}

test "writeText wide grapheme leaves a spacer" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 10, 1);
    defer s.deinit(gpa);

    const n = s.writeText(0, 0, "宽x", .{});
    try std.testing.expectEqual(@as(u16, 3), n);
    try std.testing.expectEqual(@as(u2, 2), s.cellAt(0, 0).?.width);
    try std.testing.expectEqual(@as(u2, 0), s.cellAt(1, 0).?.width);
    try std.testing.expectEqualStrings("x", s.cellAt(2, 0).?.grapheme());
}

test "writeText clips at the right edge" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 4, 1);
    defer s.deinit(gpa);

    const n = s.writeText(2, 0, "ab宽", .{});
    // "ab" fits (cols 2,3); wide grapheme would straddle the edge → dropped
    try std.testing.expectEqual(@as(u16, 2), n);
}

test "writeText interns oversized graphemes through the pool" {
    const gpa = std.testing.allocator;
    var pool = GraphemePool.init(gpa);
    defer pool.deinit();
    var s = try Surface.init(gpa, 10, 1);
    defer s.deinit(gpa);
    s.pool = &pool;

    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}";
    const n = s.writeText(0, 0, family, .{});
    try std.testing.expectEqual(@as(u16, 2), n);
    const c = s.cellAt(0, 0).?.*;
    try std.testing.expect(c.poolIndex() != null);
    try std.testing.expectEqualStrings(family, s.graphemeOf(c));
    // second write of the same grapheme produces an equal cell (same index)
    var s2 = try Surface.init(gpa, 10, 1);
    defer s2.deinit(gpa);
    s2.pool = &pool;
    _ = s2.writeText(0, 0, family, .{});
    try std.testing.expect(c.eql(s2.cellAt(0, 0).?.*));
}

test "writeText without a pool degrades to replacement char" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 10, 1);
    defer s.deinit(gpa);

    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}";
    _ = s.writeText(0, 0, family, .{});
    try std.testing.expectEqualStrings("\u{FFFD}", s.graphemeOf(s.cellAt(0, 0).?.*));
}

test "zero-width mark folds into the previous cell across calls" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 10, 1);
    defer s.deinit(gpa);

    _ = s.writeText(0, 0, "e", .{});
    const n = s.writeText(1, 0, "\u{301}x", .{}); // bare acute, then 'x'
    try std.testing.expectEqualStrings("e\u{301}", s.graphemeOf(s.cellAt(0, 0).?.*));
    try std.testing.expectEqualStrings("x", s.cellAt(1, 0).?.grapheme());
    try std.testing.expectEqual(@as(u16, 1), n); // mark took no column
}

test "zero-width cluster mid-string folds left" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 10, 1);
    defer s.deinit(gpa);

    const n = s.writeText(0, 0, "a\u{200B}b", .{}); // ZWSP is its own cluster
    try std.testing.expectEqual(@as(u16, 2), n);
    try std.testing.expectEqualStrings("a\u{200B}", s.graphemeOf(s.cellAt(0, 0).?.*));
    try std.testing.expectEqualStrings("b", s.cellAt(1, 0).?.grapheme());
}

test "zero-width mark skips a wide glyph's spacer" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 10, 1);
    defer s.deinit(gpa);

    _ = s.writeText(0, 0, "宽", .{});
    _ = s.writeText(2, 0, "\u{301}", .{});
    try std.testing.expectEqualStrings("宽\u{301}", s.graphemeOf(s.cellAt(0, 0).?.*));
    try std.testing.expectEqual(@as(u2, 0), s.cellAt(1, 0).?.width); // spacer intact
}

test "fold overflowing inline capacity re-interns through the pool" {
    const gpa = std.testing.allocator;
    var pool = GraphemePool.init(gpa);
    defer pool.deinit();
    var s = try Surface.init(gpa, 10, 1);
    defer s.deinit(gpa);
    s.pool = &pool;

    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}";
    _ = s.writeText(0, 0, family, .{});
    _ = s.writeText(2, 0, "\u{301}", .{});
    try std.testing.expectEqualStrings(family ++ "\u{301}", s.graphemeOf(s.cellAt(0, 0).?.*));
}

test "fold degradation keeps the base glyph" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 10, 1);
    defer s.deinit(gpa);

    // 14-byte single cluster; +2-byte mark would need the (absent) pool.
    const flag = "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}";
    _ = s.writeText(0, 0, flag, .{});
    _ = s.writeText(2, 0, "\u{301}", .{});
    try std.testing.expectEqualStrings(flag, s.graphemeOf(s.cellAt(0, 0).?.*));

    // A mark with nothing to its left is dropped, not a crash.
    _ = s.writeText(0, 0, "\u{301}", .{});
}

test "writeText interns hyperlinks and linkOf resolves them" {
    const gpa = std.testing.allocator;
    var pool = GraphemePool.init(gpa);
    defer pool.deinit();
    var s = try Surface.init(gpa, 10, 1);
    defer s.deinit(gpa);
    s.pool = &pool;

    _ = s.writeText(0, 0, "zig 宽", .{ .link = "https://ziglang.org" });
    try std.testing.expectEqualStrings("https://ziglang.org", s.linkOf(s.cellAt(0, 0).?.*).?);
    // the wide glyph's spacer carries the link too
    try std.testing.expectEqualStrings("https://ziglang.org", s.linkOf(s.cellAt(5, 0).?.*).?);

    // same URI in another write → equal cells (same interned index)
    var s2 = try Surface.init(gpa, 10, 1);
    defer s2.deinit(gpa);
    s2.pool = &pool;
    _ = s2.writeText(0, 0, "zig", .{ .link = "https://ziglang.org" });
    try std.testing.expect(s.cellAt(0, 0).?.eql(s2.cellAt(0, 0).?.*));

    // unlinked text stays link-free
    _ = s.writeText(0, 0, "zig", .{});
    try std.testing.expectEqual(@as(?[]const u8, null), s.linkOf(s.cellAt(0, 0).?.*));
}

test "hyperlinks degrade to no link" {
    const gpa = std.testing.allocator;
    var pool = GraphemePool.init(gpa);
    defer pool.deinit();

    // no pool: dropped
    var bare = try Surface.init(gpa, 4, 1);
    defer bare.deinit(gpa);
    _ = bare.writeText(0, 0, "x", .{ .link = "https://ziglang.org" });
    try std.testing.expectEqual(@as(u32, 0), bare.cellAt(0, 0).?.link);

    // bytes that would tear the OSC payload: dropped
    var s = try Surface.init(gpa, 4, 1);
    defer s.deinit(gpa);
    s.pool = &pool;
    _ = s.writeText(0, 0, "x", .{ .link = "https://bad.example/\x1b\\" });
    try std.testing.expectEqual(@as(u32, 0), s.cellAt(0, 0).?.link);
    _ = s.writeText(0, 0, "x", .{ .link = "not a uri" });
    try std.testing.expectEqual(@as(u32, 0), s.cellAt(0, 0).?.link);
}

test "explicit link ids intern as a distinct identity" {
    const gpa = std.testing.allocator;
    var pool = GraphemePool.init(gpa);
    defer pool.deinit();
    var s = try Surface.init(gpa, 10, 1);
    defer s.deinit(gpa);
    s.pool = &pool;

    _ = s.writeText(0, 0, "a", .{ .link = "https://ziglang.org", .link_id = "one" });
    _ = s.writeText(1, 0, "b", .{ .link = "https://ziglang.org", .link_id = "two" });
    _ = s.writeText(2, 0, "c", .{ .link = "https://ziglang.org" });

    const a = s.cellAt(0, 0).?.*;
    const b = s.cellAt(1, 0).?.*;
    const c = s.cellAt(2, 0).?.*;
    // URI resolves identically everywhere; identities all differ
    for ([_]Cell{ a, b, c }) |cl|
        try std.testing.expectEqualStrings("https://ziglang.org", s.linkOf(cl).?);
    try std.testing.expect(a.link != b.link and a.link != c.link and b.link != c.link);
    try std.testing.expectEqualStrings("one", s.linkIdOf(a).?);
    try std.testing.expectEqualStrings("two", s.linkIdOf(b).?);
    try std.testing.expectEqual(@as(?[]const u8, null), s.linkIdOf(c));

    // same (URI, id) pair → same identity
    var s2 = try Surface.init(gpa, 10, 1);
    defer s2.deinit(gpa);
    s2.pool = &pool;
    _ = s2.writeText(0, 0, "x", .{ .link = "https://ziglang.org", .link_id = "one" });
    try std.testing.expectEqual(a.link, s2.cellAt(0, 0).?.link);
}

test "invalid link ids fall back to the derived id" {
    const gpa = std.testing.allocator;
    var pool = GraphemePool.init(gpa);
    defer pool.deinit();
    var s = try Surface.init(gpa, 10, 1);
    defer s.deinit(gpa);
    s.pool = &pool;

    _ = s.writeText(0, 0, "a", .{ .link = "https://ziglang.org" });
    const plain = s.cellAt(0, 0).?.link;
    for ([_][]const u8{ "", "has;semi", "has:colon", "has~tilde", "spa ce" }) |bad| {
        _ = s.writeText(0, 0, "a", .{ .link = "https://ziglang.org", .link_id = bad });
        try std.testing.expectEqual(plain, s.cellAt(0, 0).?.link);
    }
}

test "zero-width fold keeps the target cell's link" {
    const gpa = std.testing.allocator;
    var pool = GraphemePool.init(gpa);
    defer pool.deinit();
    var s = try Surface.init(gpa, 10, 1);
    defer s.deinit(gpa);
    s.pool = &pool;

    _ = s.writeText(0, 0, "e", .{ .link = "https://ziglang.org" });
    _ = s.writeText(1, 0, "\u{301}", .{});
    const c = s.cellAt(0, 0).?.*;
    try std.testing.expectEqualStrings("e\u{301}", s.graphemeOf(c));
    try std.testing.expectEqualStrings("https://ziglang.org", s.linkOf(c).?);
}

test "writes outside bounds are no-ops" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 4, 2);
    defer s.deinit(gpa);

    s.writeCell(99, 0, .{});
    try std.testing.expectEqual(@as(u16, 0), s.writeText(0, 99, "nope", .{}));
}
