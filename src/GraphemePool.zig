//! Interning storage for byte strings a Cell can't hold inline: grapheme
//! clusters past the inline buffer (ZWJ emoji sequences, mostly) and OSC 8
//! hyperlink URIs. Equal byte sequences intern to the same index, so pooled
//! cells compare by index and the Renderer's diff stays a value comparison.
//! Entries live for the pool's lifetime — the variety of long graphemes and
//! link targets an app draws is small and bounded in practice.
const GraphemePool = @This();

const std = @import("std");

gpa: std.mem.Allocator,
/// Backing storage for interned bytes. An arena gives stable pointers, so
/// `entries` slices and `map` keys stay valid across growth.
arena: std.heap.ArenaAllocator,
entries: std.ArrayList([]const u8) = .empty,
map: std.StringHashMapUnmanaged(u32) = .empty,

pub fn init(gpa: std.mem.Allocator) GraphemePool {
    return .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
}

pub fn deinit(self: *GraphemePool) void {
    self.entries.deinit(self.gpa);
    self.map.deinit(self.gpa);
    self.arena.deinit();
    self.* = undefined;
}

/// Intern `bytes`, returning a stable index; the same bytes always return
/// the same index. Null on allocation failure — callers degrade to U+FFFD
/// rather than erroring, so the draw path stays infallible.
pub fn intern(self: *GraphemePool, bytes: []const u8) ?u32 {
    if (self.map.get(bytes)) |idx| return idx;
    const copy = self.arena.allocator().dupe(u8, bytes) catch return null;
    const idx: u32 = @intCast(self.entries.items.len);
    self.entries.append(self.gpa, copy) catch return null;
    self.map.put(self.gpa, copy, idx) catch {
        _ = self.entries.pop();
        return null;
    };
    return idx;
}

pub fn get(self: *const GraphemePool, idx: u32) []const u8 {
    return self.entries.items[idx];
}

test "intern dedupes and round-trips" {
    var pool = GraphemePool.init(std.testing.allocator);
    defer pool.deinit();

    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}";
    const a = pool.intern(family).?;
    const b = pool.intern(family).?;
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqualStrings(family, pool.get(a));

    const other = pool.intern("\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}").?;
    try std.testing.expect(other != a);
}
