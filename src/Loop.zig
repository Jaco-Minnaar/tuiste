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

tty: *Tty,
parser: Parser = .{},
buf: [4096]u8 = undefined,
start: usize = 0,
end: usize = 0,

// Global because a signal handler can't capture state. Created once,
// intentionally never closed (handlers may outlive any one Loop).
var winch_pipe: [2]posix.fd_t = .{ -1, -1 };

fn handleWinch(_: posix.SIG) callconv(.c) void {
    if (winch_pipe[1] != -1) _ = linux.write(winch_pipe[1], "w", 1);
}

pub fn init(tty: *Tty) !Loop {
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
    return .{ .tty = tty };
}

/// Block until an event arrives, or return null after `timeout_ms`
/// (null timeout = wait forever).
///
/// TODO: an escape sequence split across two reads is currently parsed
/// eagerly (lone ESC → escape key). Fix with a short ESC-grace poll.
pub fn nextEvent(self: *Loop, timeout_ms: ?i32) !?Event {
    while (true) {
        // Drain buffered bytes before touching the fd again.
        while (self.end > self.start) {
            const r = self.parser.parse(self.buf[self.start..self.end], false);
            if (r.consumed == 0) break; // incomplete sequence: need more bytes
            self.start += r.consumed;
            if (r.event) |ev| return ev;
        }
        if (self.start == self.end) {
            self.start = 0;
            self.end = 0;
        }

        var fds = [_]posix.pollfd{
            .{ .fd = self.tty.fd(), .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = winch_pipe[0], .events = posix.POLL.IN, .revents = 0 },
        };
        const n = try posix.poll(&fds, timeout_ms orelse -1);
        if (n == 0) return null;

        if (fds[1].revents & posix.POLL.IN != 0) {
            var drain: [64]u8 = undefined;
            _ = posix.read(winch_pipe[0], &drain) catch 0;
            return .{ .resize = try self.tty.size() };
        }
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
        }
    }
}
