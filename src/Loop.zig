//! poll(2)-based event multiplexer over the tty fd and a SIGWINCH self-pipe.
//! User code owns the while-loop and calls `nextEvent`; this is the only
//! module that does input I/O.
const Loop = @This();

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Tty = @import("Tty.zig");
const Parser = @import("input/Parser.zig");
const event = @import("event.zig");
const Event = event.Event;
const Key = event.Key;

gpa: std.mem.Allocator,
tty: *Tty,
parser: Parser = .{},
/// Aggregates bracketed-paste chunks into the single `.paste` event the
/// application sees. Cleared when the next paste begins, which is also the
/// lifetime of the slice a `.paste` event carries.
paste_buf: std.ArrayList(u8) = .empty,
/// How long to wait for the rest of a split escape sequence before
/// committing to the "user pressed Escape" interpretation.
esc_grace_ms: i32 = 20,
buf: [4096]u8 = undefined,
start: usize = 0,
end: usize = 0,
deferred: [16]Event = undefined,
deferred_head: usize = 0,
deferred_len: usize = 0,

// Global because a signal handler can't capture state. Created once,
// intentionally never closed (handlers may outlive any one Loop).
var winch_pipe: [2]posix.fd_t = .{ -1, -1 };

fn handleWinch(_: posix.SIG) callconv(.c) void {
    if (winch_pipe[1] != -1) _ = linux.write(winch_pipe[1], "w", 1);
}

pub fn init(gpa: std.mem.Allocator, tty: *Tty) !Loop {
    if (winch_pipe[0] == -1) {
        var fds: [2]i32 = undefined;
        const rc = linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true });
        if (posix.errno(rc) != .SUCCESS) return error.PipeFailed;
        winch_pipe = fds;
    }
    posix.sigaction(.WINCH, &.{
        .handler = .{ .handler = handleWinch },
        .mask = posix.sigemptyset(),
        .flags = 0,
    }, null);
    return .{ .gpa = gpa, .tty = tty };
}

pub fn deinit(self: *Loop) void {
    self.paste_buf.deinit(self.gpa);
    self.* = undefined;
}

/// Re-queue an event to be returned by a later `nextEvent` call, ahead of
/// new input. Capability detection uses this so user input arriving during
/// the query round-trip isn't swallowed. Full queue drops the event.
pub fn pushDeferred(self: *Loop, ev: Event) void {
    if (self.deferred_len == self.deferred.len) return;
    self.deferred[(self.deferred_head + self.deferred_len) % self.deferred.len] = ev;
    self.deferred_len += 1;
}

/// Block until an event arrives, or return null after `timeout_ms`
/// (null timeout = wait forever). Events re-queued via `pushDeferred` are
/// returned first.
pub fn nextEvent(self: *Loop, timeout_ms: ?i32) !?Event {
    if (self.deferred_len > 0) {
        const ev = self.deferred[self.deferred_head];
        self.deferred_head = (self.deferred_head + 1) % self.deferred.len;
        self.deferred_len -= 1;
        return ev;
    }
    return self.pollEvent(timeout_ms);
}

/// `nextEvent` minus the deferred queue. Capability detection MUST use this:
/// it is the producer of deferred events, so consuming them here would
/// livelock on the first stashed keypress.
pub fn pollEvent(self: *Loop, timeout_ms: ?i32) !?Event {
    while (true) {
        parsing: while (self.end > self.start) {
            // Optimistically assume more bytes may follow, so an incomplete
            // sequence reports consumed == 0 instead of misparsing.
            const r = self.parser.parse(self.buf[self.start..self.end], true);
            if (r.consumed > 0) {
                self.start += r.consumed;
                if (r.event) |ev| {
                    if (try self.foldPaste(ev)) |out| return out;
                }
                continue :parsing;
            }
            // Incomplete. Give the rest of the sequence a grace window to
            // arrive before resolving the ambiguity.
            switch (try self.fill(self.esc_grace_ms)) {
                .bytes => continue :parsing,
                .resize => |size| return .{ .resize = size },
                .timeout => {
                    // Mid-paste there is no ambiguity to resolve: a held-back
                    // partial terminator completes only with more bytes, and
                    // the terminal is guaranteed to still be sending them.
                    // Wait with the caller's timeout instead of the grace one.
                    // Returning early keeps start/end, so the held bytes
                    // survive into the next call.
                    if (self.parser.in_paste) {
                        switch (try self.fill(timeout_ms)) {
                            .bytes => continue :parsing,
                            .resize => |size| return .{ .resize = size },
                            .timeout => return null,
                        }
                    }
                    // Nothing came: resolve with more = false (lone ESC
                    // becomes an Escape keypress).
                    const r2 = self.parser.parse(self.buf[self.start..self.end], false);
                    if (r2.consumed > 0) {
                        self.start += r2.consumed;
                        if (r2.event) |ev| {
                            if (try self.foldPaste(ev)) |out| return out;
                        }
                        continue :parsing;
                    }
                    // Still unresolvable (truncated CSI, torn UTF-8): commit
                    // the first byte so we can't loop forever.
                    const b = self.buf[self.start];
                    self.start += 1;
                    if (b == 0x1b) return .{ .key = .{ .codepoint = Key.escape } };
                    continue :parsing; // undecodable byte: drop it
                },
            }
        }
        self.start = 0;
        self.end = 0;

        switch (try self.fill(timeout_ms)) {
            .bytes => {},
            .resize => |size| return .{ .resize = size },
            .timeout => return null,
        }
    }
}

/// Fold the Parser's low-level paste events into `paste_buf`. Returns the
/// event to surface, or null when the event was aggregation bookkeeping.
/// This runs below the deferred queue on purpose: `.paste_chunk` slices
/// point into `buf`, which the next fill() compacts, so they must be copied
/// out before anything else can happen — only the aggregated `.paste`
/// (backed by stable `paste_buf` memory) may ever escape or be deferred.
fn foldPaste(self: *Loop, ev: Event) !?Event {
    switch (ev) {
        .paste_start => self.paste_buf.clearRetainingCapacity(),
        .paste_chunk => |bytes| try self.paste_buf.appendSlice(self.gpa, bytes),
        .paste_end => return .{ .paste = self.paste_buf.items },
        else => return ev,
    }
    return null;
}

const Filled = union(enum) {
    bytes,
    resize: event.Size,
    timeout,
};

/// Wait up to `timeout_ms` (null = forever) for input; on tty readability
/// appends to `buf`. Returns what happened so the caller decides how to react.
fn fill(self: *Loop, timeout_ms: ?i32) !Filled {
    var fds = [_]posix.pollfd{
        .{ .fd = self.tty.fd(), .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = winch_pipe[0], .events = posix.POLL.IN, .revents = 0 },
    };
    const n = try posix.poll(&fds, timeout_ms orelse -1);
    if (n == 0) return .timeout;

    if (fds[1].revents & posix.POLL.IN != 0) {
        var drain: [64]u8 = undefined;
        _ = posix.read(winch_pipe[0], &drain) catch 0;
        return .{ .resize = try self.tty.size() };
    }
    if (fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) return error.TtyClosed;
    if (fds[0].revents & posix.POLL.IN != 0) {
        // Compact leftover partial sequence to the front, then append.
        if (self.start > 0) {
            std.mem.copyForwards(u8, &self.buf, self.buf[self.start..self.end]);
            self.end -= self.start;
            self.start = 0;
        }
        const got = try posix.read(self.tty.fd(), self.buf[self.end..]);
        if (got == 0) return error.TtyClosed;
        self.end += got;
        return .bytes;
    }
    return .timeout;
}
