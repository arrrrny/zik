const std = @import("std");

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

    fn showCommands(self: *Self, lb: *[4096]u8, ll: usize) void {
        const cmds: []const []const u8 = &.{
            "/help           Show available commands",
            "/status         Session status (model, messages, tokens)",
            "/exit, /quit    Exit the REPL (saves session)",
            "/clear          Clear conversation history",
            "/model          Show current model",
            "/model <name>   Change model",
            "/cost           Token usage and estimated cost",
            "/config         Show effective configuration",
            "/export         Export session to JSON",
            "/compact        Compact conversation (keep last 10)",
            "/history        Show message history summary",
            "/doctor         Diagnostic health check",
            "/session        Session details (ID, messages, provider)",
            "/permissions    Permission mode status",
            "/version        Version info",
            "/diff           Show git workspace changes",
            "/resume         Resume latest session",
            "/resume <id>    Resume specific session",
            "/undo           Undo last operation",
            "/run <cmd>      Execute shell command",
            "/test           Auto-detect and run tests",
            "/build          Auto-detect and run build",
            "/stop           Stop current operation",
            "/retry          Retry last failed operation",
            "/search         Search code for pattern",
            "/files          List workspace files",
            "/explain        Explain selected code",
            "/fix            Fix errors in workspace",
            "/format         Auto-detect and run formatter",
            "/lint           Auto-detect and run linter",
            "/refactor       Refactor code",
            "/review         Code review",
            "/context        Show current context/state",
            "/usage          Show token usage statistics",
            "/tokens         Detailed token breakdown + cost",
            "/plan           Enter planning mode",
            "/reset          Reset session (clear history)",
            "/git <args>     Run git commands",
            "/commit <msg>   Stage and commit all changes",
            "/summary        Conversation summary",
            "/mcp            MCP server management",
            "/plugin         Plugin management",
            "/skills         Skills management",
            "/sandbox        Sandbox mode toggle",
            "/output-style   Response formatting",
            "/max-tokens     Token limit control",
            "/temperature    Temperature control",
            "/effort         Effort/complexity mode",
            "/profile        Profile configuration",
            "/diagnostics    Full system diagnostics",
            "/log            Log viewing",
            "/init           Workspace initialization",
            "/theme          UI theme",
            "/vim            Vim mode toggle",
        };
        self.p("\n");
        for (cmds) |cmd| {
            self.p("  ");
            self.p(cmd);
            self.p("\n");
        }
        self.p("zik> ");
        if (ll > 0) self.p(lb[0..ll]);
    }

    pub fn readLine(self: *Self, allocator: std.mem.Allocator) !?[]const u8 {
        var line_buf: [4096]u8 = undefined;
        var line_len: usize = 0;
        self.p("zik> ");
        var char_buf: [1]u8 = undefined;
        while (true) {
            const n = try self.stdin.read(&char_buf);
            if (n == 0) { self.p("\n"); return null; }
            switch (char_buf[0]) {
                13, 10 => {
                    self.p("\n");
                    if (line_len == 0) continue;
                    return try allocator.dupe(u8, line_buf[0..line_len]);
                },
                8, 127 => {
                    if (line_len > 0) {
                        line_len -= 1;
                        self.p("\x1b[D\x1b[K");
                    }
                },
                3 => { self.p("^C\nzik> "); line_len = 0; },
                4 => { self.p("\n"); return null; },
                21 => { self.p("\r\x1b[Kzik> "); line_len = 0; },
                9 => { self.showCommands(&line_buf, line_len); },
                32...126 => {
                    if (line_len < line_buf.len) {
                        line_buf[line_len] = char_buf[0];
                        line_len += 1;
                        self.p(&char_buf);
                    }
                },
                27 => { var esc: [2]u8 = undefined; _ = self.stdin.read(&esc) catch {}; },
                else => {},
            }
        }
    }
};

test "InputHandler init/deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();
    var h = InputHandler.init(a);
    defer h.deinit(a);
    try std.testing.expect(h.pos == 0);
}
