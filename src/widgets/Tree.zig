//! An expand/collapse hierarchy. The application owns the tree as a flat
//! pre-order array of nodes (label + depth + expanded flag) and mutates
//! `expanded` itself — or lets `State.handleKey` do it. "Has children" is
//! derived (the next node is deeper), the widget skips the descendants of
//! collapsed nodes, and `State.selected` is a *node index*, so it stays
//! stable when unrelated branches collapse; a selection hidden by a
//! collapse snaps to the ancestor that swallowed it. Markers and per-level
//! guide lines are user-definable via `Markers`.
const Tree = @This();

const std = @import("std");
const Region = @import("../Region.zig");
const Surface = @import("../Surface.zig");
const cell_mod = @import("../cell.zig");
const Cell = cell_mod.Cell;
const Key = @import("../event.zig").Key;

nodes: []const Node = &.{},
opts: Surface.Options = .{},
selected_opts: Surface.Options = .{ .attrs = .{ .reverse = true } },
markers: Markers = .{},

pub const Node = struct {
    label: []const u8,
    /// Pre-order nesting depth; a node is a child of the nearest earlier
    /// node with a smaller depth.
    depth: u16 = 0,
    expanded: bool = true,
};

/// What gets drawn left of each label. Defaults are plain indentation;
/// set `continues`/`done` to "│ "/"  " for tree(1)-style guide lines.
/// Pieces may be any width (including multi-column or styledless text);
/// keep the four indent-level pieces equally wide for aligned columns.
pub const Markers = struct {
    /// Before an expandable node that is currently collapsed / expanded.
    collapsed: []const u8 = "▸ ",
    expanded: []const u8 = "▾ ",
    /// Before a leaf, normally as wide as the two above.
    leaf: []const u8 = "  ",
    /// One piece per ancestor level: `continues` when that ancestor has a
    /// later sibling (the branch keeps going below), `done` when it was
    /// the last of its siblings.
    continues: []const u8 = "  ",
    done: []const u8 = "  ",
};

pub const State = struct {
    /// Index into `nodes` — not a row number.
    selected: ?usize = null,
    /// Visible-row ordinal of the first drawn row.
    offset: usize = 0,

    /// Move to the next/previous *visible* node.
    pub fn selectNext(self: *State, nodes: []const Node) void {
        if (nodes.len == 0) return;
        const sel = self.resolve(nodes) orelse {
            self.selected = firstVisible(nodes);
            return;
        };
        var it: VisibleIter = .{ .nodes = nodes };
        while (it.next()) |idx| {
            if (idx == sel) {
                self.selected = it.next() orelse sel;
                return;
            }
        }
    }

    pub fn selectPrev(self: *State, nodes: []const Node) void {
        if (nodes.len == 0) return;
        const sel = self.resolve(nodes) orelse {
            self.selected = lastVisible(nodes);
            return;
        };
        var prev: ?usize = null;
        var it: VisibleIter = .{ .nodes = nodes };
        while (it.next()) |idx| {
            if (idx == sel) {
                self.selected = prev orelse sel;
                return;
            }
            prev = idx;
        }
    }

    /// Standard tree bindings: up/down/home/end navigate, right expands
    /// (or steps into the first child), left collapses (or steps to the
    /// parent), enter and space toggle. Takes the mutable node array
    /// because expansion lives in the application's data.
    pub fn handleKey(self: *State, k: Key, nodes: []Node) bool {
        if (k.kind == .release) return false;
        if (k.matches(Key.up, .{})) {
            self.selectPrev(nodes);
        } else if (k.matches(Key.down, .{})) {
            self.selectNext(nodes);
        } else if (k.matches(Key.home, .{})) {
            self.selected = firstVisible(nodes);
        } else if (k.matches(Key.end, .{})) {
            self.selected = lastVisible(nodes);
        } else if (k.matches(Key.right, .{})) {
            const sel = self.resolve(nodes) orelse return false;
            if (!hasChildren(nodes, sel)) return true;
            if (nodes[sel].expanded) self.selectNext(nodes) else nodes[sel].expanded = true;
        } else if (k.matches(Key.left, .{})) {
            const sel = self.resolve(nodes) orelse return false;
            if (nodes[sel].expanded and hasChildren(nodes, sel)) {
                nodes[sel].expanded = false;
            } else if (parentOf(nodes, sel)) |p| {
                self.selected = p;
            }
        } else if (k.matches(Key.enter, .{}) or k.matches(Key.space, .{})) {
            const sel = self.resolve(nodes) orelse return false;
            if (hasChildren(nodes, sel)) nodes[sel].expanded = !nodes[sel].expanded;
        } else {
            return false;
        }
        return true;
    }

    /// The selection clamped into range and snapped to a visible node.
    fn resolve(self: *State, nodes: []const Node) ?usize {
        const s = @min(self.selected orelse return null, nodes.len - 1);
        const v = visibleAncestor(nodes, s);
        self.selected = v;
        return v;
    }
};

/// Whether node `i` has children: pre-order means its children follow
/// immediately, one level deeper.
pub fn hasChildren(nodes: []const Node, i: usize) bool {
    return i + 1 < nodes.len and nodes[i + 1].depth > nodes[i].depth;
}

/// The parent of node `i`: the nearest earlier node with a smaller depth.
pub fn parentOf(nodes: []const Node, i: usize) ?usize {
    var j = i;
    while (j > 0) {
        j -= 1;
        if (nodes[j].depth < nodes[i].depth) return j;
    }
    return null;
}

/// `i` itself when no ancestor is collapsed, else the outermost collapsed
/// ancestor (which is the node that visually swallowed it).
fn visibleAncestor(nodes: []const Node, i: usize) usize {
    var result = i;
    var j = i;
    while (parentOf(nodes, j)) |p| {
        if (!nodes[p].expanded) result = p;
        j = p;
    }
    return result;
}

fn firstVisible(nodes: []const Node) ?usize {
    var it: VisibleIter = .{ .nodes = nodes };
    return it.next();
}

fn lastVisible(nodes: []const Node) ?usize {
    var it: VisibleIter = .{ .nodes = nodes };
    var last: ?usize = null;
    while (it.next()) |idx| last = idx;
    return last;
}

/// Yields the indices of visible nodes in order, skipping the descendants
/// of collapsed nodes.
pub const VisibleIter = struct {
    nodes: []const Node,
    i: usize = 0,
    hide_below: ?u16 = null,

    pub fn next(self: *VisibleIter) ?usize {
        while (self.i < self.nodes.len) {
            const idx = self.i;
            const n = self.nodes[idx];
            self.i += 1;
            if (self.hide_below) |d| {
                if (n.depth > d) continue;
                self.hide_below = null;
            }
            if (!n.expanded and hasChildren(self.nodes, idx)) self.hide_below = n.depth;
            return idx;
        }
        return null;
    }
};

/// Whether the ancestor of `idx` at depth `level` has a later sibling —
/// i.e. whether a guide line at that level should keep going.
fn levelContinues(nodes: []const Node, idx: usize, level: u16) bool {
    var j = idx + 1;
    while (j < nodes.len) : (j += 1) {
        if (nodes[j].depth <= level) return nodes[j].depth == level;
    }
    return false;
}

pub fn draw(self: Tree, region: Region, state: *State) void {
    const w = region.width();
    const h: usize = region.height();
    if (w == 0 or h == 0) return;
    if (self.nodes.len == 0) {
        state.selected = null;
        state.offset = 0;
        return;
    }

    _ = state.resolve(self.nodes);

    // Pass 1: total visible rows and the selection's row ordinal.
    var total: usize = 0;
    var sel_ord: ?usize = null;
    var count_it: VisibleIter = .{ .nodes = self.nodes };
    while (count_it.next()) |idx| {
        if (state.selected) |sel| {
            if (sel == idx) sel_ord = total;
        }
        total += 1;
    }
    if (sel_ord) |so| {
        if (so < state.offset) state.offset = so;
        if (so >= state.offset + h) state.offset = so - h + 1;
    }
    state.offset = @min(state.offset, total -| h);

    // Pass 2: draw the window.
    var row: u16 = 0;
    var ord: usize = 0;
    var it: VisibleIter = .{ .nodes = self.nodes };
    while (it.next()) |idx| {
        if (ord < state.offset) {
            ord += 1;
            continue;
        }
        if (row >= h) break;
        ord += 1;
        const n = self.nodes[idx];
        const is_selected = if (state.selected) |sel| sel == idx else false;
        const o = if (is_selected) self.selected_opts else self.opts;
        if (is_selected) {
            var bg: Cell = .{};
            bg.style = .{ .fg = o.fg, .bg = o.bg, .attrs = o.attrs };
            region.sub(.{ .y = row, .width = w, .height = 1 }).fill(bg);
        }
        var x: u16 = 0;
        var lvl: u16 = 0;
        while (lvl < n.depth) : (lvl += 1) {
            const piece = if (levelContinues(self.nodes, idx, lvl)) self.markers.continues else self.markers.done;
            x += region.writeText(x, row, piece, o);
        }
        const marker = if (!hasChildren(self.nodes, idx))
            self.markers.leaf
        else if (n.expanded)
            self.markers.expanded
        else
            self.markers.collapsed;
        x += region.writeText(x, row, marker, o);
        _ = region.writeText(x, row, n.label, o);
        row += 1;
    }
}

/// The node index at region-relative `row`, or null past the last visible
/// row — feed it `m.row - region.rect.y` on mouse press.
pub fn hitTest(self: Tree, state: State, row: u16) ?usize {
    var skip = state.offset + row;
    var it: VisibleIter = .{ .nodes = self.nodes };
    while (it.next()) |idx| {
        if (skip == 0) return idx;
        skip -= 1;
    }
    return null;
}

// --- tests ------------------------------------------------------------

// resepte/           0
// ├─ soet/           1
// │  ├─ melktert     2
// │  └─ koeksisters  2
// └─ sout/           1
//    └─ bobotie      2
// notas              0
fn testNodes() [7]Node {
    return .{
        .{ .label = "resepte", .depth = 0 },
        .{ .label = "soet", .depth = 1 },
        .{ .label = "melktert", .depth = 2 },
        .{ .label = "koeksisters", .depth = 2 },
        .{ .label = "sout", .depth = 1 },
        .{ .label = "bobotie", .depth = 2 },
        .{ .label = "notas", .depth = 0 },
    };
}

test "collapsed nodes hide their descendants" {
    var nodes = testNodes();
    nodes[1].expanded = false; // collapse "soet"

    var it: VisibleIter = .{ .nodes = &nodes };
    var seen: [8]usize = undefined;
    var n: usize = 0;
    while (it.next()) |idx| : (n += 1) seen[n] = idx;
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 4, 5, 6 }, seen[0..n]);
}

test "draw renders markers and user-defined guide lines" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 20, 7);
    defer s.deinit(gpa);

    var nodes = testNodes();
    var state: State = .{};
    (Tree{
        .nodes = &nodes,
        .markers = .{ .leaf = "· ", .continues = "│ ", .done = "  " },
    }).draw(Region.full(&s), &state);

    // row 0: "▾ resepte" — expanded marker, no indent
    try std.testing.expectEqualStrings("▾", s.cellAt(0, 0).?.grapheme());
    // row 2 (melktert, depth 2): "resepte" continues (│), "soet" continues (│), leaf marker
    try std.testing.expectEqualStrings("│", s.cellAt(0, 2).?.grapheme());
    try std.testing.expectEqualStrings("│", s.cellAt(2, 2).?.grapheme());
    try std.testing.expectEqualStrings("·", s.cellAt(4, 2).?.grapheme());
    try std.testing.expectEqualStrings("m", s.cellAt(6, 2).?.grapheme());
    // row 5 (bobotie): "resepte" continues, "sout" was the last child → blank
    try std.testing.expectEqualStrings("│", s.cellAt(0, 5).?.grapheme());
    try std.testing.expectEqualStrings(" ", s.cellAt(2, 5).?.grapheme());
    // row 6 (notas, depth 0 leaf)
    try std.testing.expectEqualStrings("·", s.cellAt(0, 6).?.grapheme());
}

test "hidden selection snaps to the collapsing ancestor" {
    var nodes = testNodes();
    var state: State = .{ .selected = 2 }; // melktert
    try std.testing.expect(state.handleKey(.{ .codepoint = Key.left }, &nodes)); // to parent "soet"
    try std.testing.expectEqual(@as(?usize, 1), state.selected);
    try std.testing.expect(state.handleKey(.{ .codepoint = Key.left }, &nodes)); // collapse "soet"
    try std.testing.expect(!nodes[1].expanded);

    // a selection left inside a collapsed branch resolves to the ancestor
    state.selected = 3;
    state.selectNext(&nodes); // resolves 3 → 1 ("soet"), then steps to "sout"
    try std.testing.expectEqual(@as(?usize, 4), state.selected);
}

test "navigation walks visible nodes only" {
    var nodes = testNodes();
    nodes[1].expanded = false;
    var state: State = .{};
    state.selectNext(&nodes); // none → first
    try std.testing.expectEqual(@as(?usize, 0), state.selected);
    state.selectNext(&nodes); // "soet" (collapsed, still visible itself)
    try std.testing.expectEqual(@as(?usize, 1), state.selected);
    state.selectNext(&nodes); // skips hidden 2,3 → "sout"
    try std.testing.expectEqual(@as(?usize, 4), state.selected);
    state.selectPrev(&nodes);
    try std.testing.expectEqual(@as(?usize, 1), state.selected);

    var fresh: State = .{};
    fresh.selectPrev(&nodes); // none → last visible
    try std.testing.expectEqual(@as(?usize, 6), fresh.selected);
}

test "right expands then steps in; enter toggles" {
    var nodes = testNodes();
    nodes[1].expanded = false;
    var state: State = .{ .selected = 1 };

    try std.testing.expect(state.handleKey(.{ .codepoint = Key.right }, &nodes));
    try std.testing.expect(nodes[1].expanded); // first right: expand
    try std.testing.expect(state.handleKey(.{ .codepoint = Key.right }, &nodes));
    try std.testing.expectEqual(@as(?usize, 2), state.selected); // second: first child

    try std.testing.expect(state.handleKey(.{ .codepoint = Key.enter }, &nodes));
    try std.testing.expect(nodes[2].expanded); // leaf: toggle is a no-op
    state.selected = 0;
    try std.testing.expect(state.handleKey(.{ .codepoint = Key.space }, &nodes));
    try std.testing.expect(!nodes[0].expanded);
}

test "scroll follows the selection ordinal and hitTest inverts it" {
    const gpa = std.testing.allocator;
    var s = try Surface.init(gpa, 20, 3);
    defer s.deinit(gpa);

    var nodes = testNodes();
    const t: Tree = .{ .nodes = &nodes };
    var state: State = .{ .selected = 6 }; // "notas", ordinal 6 of 7
    t.draw(Region.full(&s), &state);
    try std.testing.expectEqual(@as(usize, 4), state.offset);
    try std.testing.expectEqualStrings("n", s.cellAt(2, 2).?.grapheme()); // notas on the last row

    try std.testing.expectEqual(@as(?usize, 4), t.hitTest(state, 0)); // "sout"
    try std.testing.expectEqual(@as(?usize, 6), t.hitTest(state, 2));
    try std.testing.expectEqual(@as(?usize, null), t.hitTest(state, 3));

    // empty tree resets state
    var st2: State = .{ .selected = 3, .offset = 2 };
    (Tree{}).draw(Region.full(&s), &st2);
    try std.testing.expectEqual(@as(?usize, null), st2.selected);
}