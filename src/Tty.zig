//! Owns /dev/tty: raw mode, size queries, and buffered output. Restores the
//! termios state it found on deinit.
//! TODO: hook the restore into a panic handler so a crash never leaves the
//! user's terminal raw (needs an opt-in override of the root panic fn).
const Tty = @This();

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const linux = std.os.linux;
const event = @import("event.zig");

io: Io,
file: Io.File,
file_writer: Io.File.Writer,
write_buf: []u8,
saved_termios: ?posix.termios = null,

const write_buf_size = 32 * 1024;

pub fn init(gpa: std.mem.Allocator, io: Io) !Tty {
    const file = try Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_write });
    errdefer file.close(io);
    const write_buf = try gpa.alloc(u8, write_buf_size);
    return .{
        .io = io,
        .file = file,
        .file_writer = file.writerStreaming(io, write_buf),
        .write_buf = write_buf,
    };
}

pub fn deinit(self: *Tty, gpa: std.mem.Allocator) void {
    self.restore();
    self.file.close(self.io);
    gpa.free(self.write_buf);
    self.* = undefined;
}

pub fn fd(self: *const Tty) posix.fd_t {
    return self.file.handle;
}

/// The buffered writer everything renders through. Call `flush` to emit.
pub fn writer(self: *Tty) *Io.Writer {
    return &self.file_writer.interface;
}

pub fn flush(self: *Tty) !void {
    try self.file_writer.interface.flush();
}

/// Enter raw mode, saving the current termios for `restore`.
pub fn makeRaw(self: *Tty) !void {
    const orig = try posix.tcgetattr(self.fd());
    self.saved_termios = orig;

    var raw = orig;
    raw.iflag.IGNBRK = false;
    raw.iflag.BRKINT = false;
    raw.iflag.PARMRK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.INLCR = false;
    raw.iflag.IGNCR = false;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;
    raw.oflag.OPOST = false;
    raw.lflag.ECHO = false;
    raw.lflag.ECHONL = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.cflag.CSIZE = .CS8;
    raw.cflag.PARENB = false;
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    try posix.tcsetattr(self.fd(), .FLUSH, raw);
}

/// Put the terminal back the way `makeRaw` found it. Idempotent.
pub fn restore(self: *Tty) void {
    if (self.saved_termios) |t| {
        posix.tcsetattr(self.fd(), .FLUSH, t) catch {};
        self.saved_termios = null;
    }
}

pub fn size(self: *const Tty) !event.Size {
    var ws: posix.winsize = undefined;
    const rc = linux.ioctl(self.fd(), linux.T.IOCGWINSZ, @intFromPtr(&ws));
    if (posix.errno(rc) != .SUCCESS) return error.WinsizeQueryFailed;
    return .{ .cols = ws.col, .rows = ws.row };
}
