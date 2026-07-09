//! Owns /dev/tty: raw mode, size queries, and buffered output. Restores the
//! termios state it found on deinit — and, if the application opts into
//! `tuiste.panic` in its root file, on panic too (see `panicRestore`).
const Tty = @This();

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const linux = std.os.linux;
const event = @import("event.zig");
const ctlseqs = @import("ctlseqs.zig");

io: Io,
file: Io.File,
file_writer: Io.File.Writer,
write_buf: []u8,
saved_termios: ?posix.termios = null,

const write_buf_size = 32 * 1024;

/// What `panicRestore` needs. A module-level global (not a Tty field)
/// because a panic handler has no way to reach an instance; one terminal
/// per process is assumed.
var panic_restore_state: ?struct {
    fd: posix.fd_t,
    termios: posix.termios,
} = null;

/// Best-effort terminal restore for panic (or signal) context: no
/// allocation, no `Io`, raw fd writes only. Unwinds every mode the library
/// may have set — the sequences are harmless if a mode wasn't active.
/// No-op unless `makeRaw` is currently in effect. Safe to call twice.
pub fn panicRestore() void {
    const state = panic_restore_state orelse return;
    panic_restore_state = null;
    // Alt screen last, so whatever gets printed next (the panic message)
    // lands on the user's real screen, after the cursor is visible again.
    const unwind = ctlseqs.kitty_kb_pop ++ ctlseqs.mouse_off ++
        ctlseqs.bracketed_paste_off ++ ctlseqs.focus_off ++
        ctlseqs.sgr_reset ++ ctlseqs.cursor_shape_reset ++
        ctlseqs.show_cursor ++ ctlseqs.exit_alt_screen;
    // Raw syscall: std.posix has no write wrapper in 0.16, and panic context
    // wants the most primitive path anyway.
    var written: usize = 0;
    while (written < unwind.len) {
        const rc = linux.write(state.fd, unwind[written..].ptr, unwind.len - written);
        if (posix.errno(rc) != .SUCCESS) break;
        written += rc;
    }
    posix.tcsetattr(state.fd, .FLUSH, state.termios) catch {};
}

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
    panic_restore_state = .{ .fd = self.fd(), .termios = orig };

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
    panic_restore_state = null;
}

pub fn size(self: *const Tty) !event.Size {
    var ws: posix.winsize = undefined;
    const rc = linux.ioctl(self.fd(), linux.T.IOCGWINSZ, @intFromPtr(&ws));
    if (posix.errno(rc) != .SUCCESS) return error.WinsizeQueryFailed;
    return .{ .cols = ws.col, .rows = ws.row };
}
