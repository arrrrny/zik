const std = @import("std");

/// Terminal input handler for the REPL.
pub const InputHandler = struct {
    stdin: std.fs.File,
    stdout: std.fs.File,
    buf: []u8,
    pos: usize,

    saved_termios: std.posix.termios,
    raw_mode: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        const saved = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch @panic("not a tty");
        return .{
            .stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO },
            .stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO },
            .buf = allocator.alloc(u8, 4096) catch @panic("OOM"),
            .pos = 0,
            .saved_termios = saved,
            .raw_mode = false,
        };
    }

    pub fn enableRawMode(self: *Self) void {
        if (self.raw_mode) return;
        var termios = self.saved_termios;
        termios.lflag.ICANON = false;
        termios.lflag.ECHO = false;
        termios.lflag.ISIG = false;
        termios.iflag.ICRNL = false;
        termios.iflag.INLCR = false;
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, termios) catch {};
        self.raw_mode = true;
    }

    pub fn restoreRawMode(self: *const Self) void {
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.saved_termios) catch {};
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.buf);
    }

    fn p(self: *Self, s: []const u8) void {
        _ = std.posix.write(self.stdout.handle, s) catch {};
    }

    /// Read a line of input. Handles backspace, Ctrl+C, Ctrl+D, Ctrl+U.
    pub fn readLine(self: *Self, allocator: std.mem.Allocator) !?[]const u8 {
        var line_buf: [4096]u8 = undefined;
        var line_len: usize = 0;

        self.p("zik> ");

        var char_buf: [1]u8 = undefined;

        while (true) {
            const n = try self.stdin.read(&char_buf);
            if (n == 0) {
                self.p("\n");
                return null;
            }

            const c = char_buf[0];

            switch (c) {
                13, 10 => {
                    self.p("\n");
                    if (line_len == 0) continue;
                    const owned = try allocator.dupe(u8, line_buf[0..line_len]);
                    return owned;
                },
                8, 127 => {
                    if (line_len > 0) {
                        line_len -= 1;
                        self.p("\x1b[D\x1b[K");
                    }
                },
                3 => {
                    self.p("^C\nzik> ");
                    line_len = 0;
                },
                4 => {
                    self.p("\n");
                    return null;
                },
                21 => {
                    self.p("\r\x1b[Kzik> ");
                    line_len = 0;
                },
                32...126 => {
                    if (line_len < line_buf.len) {
                        line_buf[line_len] = c;
                        line_len += 1;
                        self.p(&char_buf);
                    }
                },
                27 => {
                    var esc_buf: [2]u8 = undefined;
                    _ = self.stdin.read(&esc_buf) catch {};
                },
                else => {},
            }
        }
    }
};

test "InputHandler init/deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var handler = InputHandler.init(allocator);
    defer handler.deinit(allocator);

    try std.testing.expect(handler.pos == 0);
}
