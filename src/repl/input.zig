const std = @import("std");

pub const Theme = enum { dark, light, minimal };
pub const Colors = struct {
    prompt: []const u8, slash_cmd: []const u8, heading: []const u8, reset: []const u8,
    pub fn dark() Colors { return .{ .prompt = "\x1b[1;36m", .slash_cmd = "\x1b[1;33m", .heading = "\x1b[1;32m", .reset = "\x1b[0m" }; }
    pub fn light() Colors { return .{ .prompt = "\x1b[1;34m", .slash_cmd = "\x1b[1;35m", .heading = "\x1b[1;32m", .reset = "\x1b[0m" }; }
    pub fn minimal() Colors { return .{ .prompt = "", .slash_cmd = "", .heading = "", .reset = "" }; }
};

const CmdInfo = struct { cmd: []const u8, desc: []const u8 };
const ALL_CMDS: []const CmdInfo = &.{
    .{ .cmd = "/help", .desc = "Show available commands" },
    .{ .cmd = "/status", .desc = "Session status (model, messages, tokens)" },
    .{ .cmd = "/exit", .desc = "Exit the REPL (saves session)" },
    .{ .cmd = "/quit", .desc = "Same as /exit" },
    .{ .cmd = "/clear", .desc = "Clear conversation history" },
    .{ .cmd = "/model", .desc = "Show current model" },
    .{ .cmd = "/cost", .desc = "Token usage and estimated cost" },
    .{ .cmd = "/config", .desc = "Show effective configuration" },
    .{ .cmd = "/export", .desc = "Export session to JSON" },
    .{ .cmd = "/compact", .desc = "Compact conversation (keep last 10)" },
    .{ .cmd = "/history", .desc = "Show message history summary" },
    .{ .cmd = "/doctor", .desc = "Diagnostic health check" },
    .{ .cmd = "/session", .desc = "Session details (ID, messages, provider)" },
    .{ .cmd = "/permissions", .desc = "Permission mode status" },
    .{ .cmd = "/version", .desc = "Version info" },
    .{ .cmd = "/diff", .desc = "Show git workspace changes" },
    .{ .cmd = "/resume", .desc = "Resume latest session" },
    .{ .cmd = "/undo", .desc = "Undo last operation" },
    .{ .cmd = "/run", .desc = "Execute shell command" },
    .{ .cmd = "/test", .desc = "Auto-detect and run tests" },
    .{ .cmd = "/build", .desc = "Auto-detect and run build" },
    .{ .cmd = "/stop", .desc = "Stop current operation" },
    .{ .cmd = "/retry", .desc = "Retry last failed operation" },
    .{ .cmd = "/search", .desc = "Search code for pattern" },
    .{ .cmd = "/files", .desc = "List workspace files" },
    .{ .cmd = "/explain", .desc = "Explain selected code" },
    .{ .cmd = "/fix", .desc = "Fix errors in workspace" },
    .{ .cmd = "/format", .desc = "Auto-detect and run formatter" },
    .{ .cmd = "/lint", .desc = "Auto-detect and run linter" },
    .{ .cmd = "/refactor", .desc = "Refactor code" },
    .{ .cmd = "/review", .desc = "Code review" },
    .{ .cmd = "/context", .desc = "Show current context/state" },
    .{ .cmd = "/usage", .desc = "Show token usage statistics" },
    .{ .cmd = "/tokens", .desc = "Detailed token breakdown + cost" },
    .{ .cmd = "/plan", .desc = "Enter planning mode" },
    .{ .cmd = "/reset", .desc = "Reset session (clear history)" },
    .{ .cmd = "/git", .desc = "Run git commands" },
    .{ .cmd = "/commit", .desc = "Stage and commit all changes" },
    .{ .cmd = "/summary", .desc = "Conversation summary" },
    .{ .cmd = "/mcp", .desc = "MCP server management" },
    .{ .cmd = "/plugin", .desc = "Plugin management" },
    .{ .cmd = "/skills", .desc = "Skills management" },
    .{ .cmd = "/sandbox", .desc = "Sandbox mode toggle" },
    .{ .cmd = "/output-style", .desc = "Response formatting" },
    .{ .cmd = "/max-tokens", .desc = "Token limit control" },
    .{ .cmd = "/temperature", .desc = "Temperature control" },
    .{ .cmd = "/effort", .desc = "Effort/complexity mode" },
    .{ .cmd = "/profile", .desc = "Profile configuration" },
    .{ .cmd = "/diagnostics", .desc = "Full system diagnostics" },
    .{ .cmd = "/log", .desc = "Log viewing" },
    .{ .cmd = "/init", .desc = "Workspace initialization" },
    .{ .cmd = "/theme", .desc = "UI theme (dark/light/minimal)" },
    .{ .cmd = "/vim", .desc = "Vim mode toggle" },
    .{ .cmd = "/parallel", .desc = "Toggle parallel execution mode" },
    .{ .cmd = "/cache", .desc = "Cache management (status/clear/stats)" },
    .{ .cmd = "/agent", .desc = "Spawn sub-agent to run task" },
};

pub const InputHandler = struct {
    stdin: std.fs.File, stdout: std.fs.File, buf: []u8, pos: usize,
    saved_termios: std.posix.termios, raw_mode: bool, theme: Theme, colors: Colors,
    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        const saved = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch @panic("not a tty");
        return .{
            .stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO },
            .stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO },
            .buf = allocator.alloc(u8, 4096) catch @panic("OOM"),
            .pos = 0, .saved_termios = saved, .raw_mode = false,
            .theme = .dark, .colors = Colors.dark(),
        };
    }
    pub fn setTheme(self: *Self, t: Theme) void {
        self.theme = t;
        self.colors = switch (t) { .dark => Colors.dark(), .light => Colors.light(), .minimal => Colors.minimal() };
    }
    pub fn enableRawMode(self: *Self) void {
        if (self.raw_mode) return;
        var t = self.saved_termios;
        t.lflag.ICANON = false; t.lflag.ECHO = false; t.lflag.ISIG = false;
        t.iflag.ICRNL = false; t.iflag.INLCR = false;
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, t) catch {};
        self.raw_mode = true;
    }
    pub fn restoreRawMode(self: *const Self) void {
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.saved_termios) catch {};
    }
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void { allocator.free(self.buf); }
    fn p(self: *Self, s: []const u8) void { _ = std.posix.write(self.stdout.handle, s) catch {}; }
    fn prompt(self: *Self) void { self.p(self.colors.prompt); self.p("zik"); self.p(self.colors.reset); self.p("> "); }
    fn clr(self: *Self) void { self.p("\r\x1b[K"); }
    fn redraw(self: *Self, lb: []const u8, ll: usize) void { self.clr(); self.prompt(); if (ll > 0) self.p(lb[0..ll]); }

    fn showAll(self: *Self, lb: []const u8, ll: usize) void {
        self.p("\n");
        self.p(self.colors.heading);
        self.p("  Available Commands:\n");
        self.p(self.colors.reset);
        for (ALL_CMDS) |c| {
            self.p("  "); self.p(self.colors.slash_cmd); self.p(c.cmd);
            self.p(self.colors.reset); self.p("  "); self.p(c.desc); self.p("\n");
        }
        self.redraw(lb, ll);
    }

    fn doTab(self: *Self, lb: *[4096]u8, ll: *usize) bool {
        if (ll.* == 0 or lb[0] != '/') return false;
        const end = std.mem.indexOfScalarPos(u8, lb, 0, ' ') orelse ll.*;
        const prefix = lb[0..end];
        var matches: [64]usize = undefined;
        var mc: usize = 0;
        for (ALL_CMDS, 0..) |c, i| {
            if (std.mem.startsWith(u8, c.cmd, prefix)) { matches[mc] = i; mc += 1; if (mc >= 64) break; }
        }
        if (mc == 0) return false;
        if (mc == 1) {
            const full = ALL_CMDS[matches[0]].cmd;
            var i: usize = 0;
            while (i < full.len and i < lb.len) : (i += 1) lb[i] = full[i];
            ll.* = i;
            self.redraw(lb, ll.*);
            return true;
        }
        self.p("\n");
        self.p(self.colors.heading);
        self.p("  Matching Commands:\n");
        self.p(self.colors.reset);
        var j: usize = 0;
        while (j < mc) : (j += 1) {
            const c = ALL_CMDS[matches[j]];
            self.p("  "); self.p(self.colors.slash_cmd); self.p(c.cmd);
            self.p(self.colors.reset); self.p("  "); self.p(c.desc); self.p("\n");
        }
        self.redraw(lb, ll.*);
        return false;
    }

    pub fn readLine(self: *Self, allocator: std.mem.Allocator) !?[]const u8 {
        var lb: [4096]u8 = undefined;
        var ll: usize = 0;
        self.prompt();
        var cb: [1]u8 = undefined;
        while (true) {
            const n = try self.stdin.read(&cb);
            if (n == 0) { self.p("\n"); return null; }
            switch (cb[0]) {
                13, 10 => { self.p("\n"); if (ll == 0) continue; return try allocator.dupe(u8, lb[0..ll]); },
                8, 127 => { if (ll > 0) { ll -= 1; self.p("\x1b[D\x1b[K"); } },
                3 => { self.p("^C\n"); self.prompt(); ll = 0; },
                4 => { self.p("\n"); return null; },
                21 => { self.p("\r\x1b[K"); self.prompt(); ll = 0; },
                9 => { _ = self.doTab(&lb, &ll); },
                47 => {
                    self.showAll(&lb, ll);
                    if (ll < lb.len) { lb[ll] = '/'; ll += 1; self.p("/"); }
                },
                32...46, 48...57, 65...90, 97...126 => {
                    if (ll < lb.len) { lb[ll] = cb[0]; ll += 1; self.p(&cb); }
                },
                27 => { var esc: [2]u8 = undefined; _ = self.stdin.read(&esc) catch {}; },
                else => {},
            }
        }
    }
};

test "InputHandler init/deinit/theme" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();
    var h = InputHandler.init(a); defer h.deinit(a);
    try std.testing.expect(h.pos == 0);
    try std.testing.expect(h.theme == .dark);
    h.setTheme(.light); try std.testing.expect(h.theme == .light);
    h.setTheme(.minimal); try std.testing.expect(h.theme == .minimal);
}

test "cmd count" {
    try std.testing.expect(ALL_CMDS.len == 57);
}
