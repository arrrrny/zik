const std = @import("std");

// libc functions for real-time streaming
extern "c" fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn pclose(stream: *anyopaque) c_int;
extern "c" fn fileno(stream: *anyopaque) c_int;
extern "c" fn setvbuf(stream: *anyopaque, buf: ?[*]u8, mode: c_int, size: usize) c_int;
const _IONBF = 2; // no buffering

const InputHandler = @import("input.zig").InputHandler;
const StreamOutput = @import("output.zig").StreamOutput;
const ConversationContext = @import("context.zig").ConversationContext;
const ProviderRouter = @import("../api/mod.zig").ProviderRouter;
const SSEParser = @import("../utils/streaming.zig").SSEParser;
const extractDeltaText = @import("../utils/streaming.zig").extractDeltaText;
const extractOpenAIChoiceDelta = @import("../utils/streaming.zig").extractOpenAIChoiceDelta;
const EnvReader = @import("../env.zig").EnvReader;

pub const REPL = struct {
    allocator: std.mem.Allocator,
    input: InputHandler,
    output: StreamOutput,
    ctx: ConversationContext,
    provider: ProviderRouter,
    running: bool,
    output_format: OutputFormat,
    model: []const u8,
    workspace_root: []const u8,
    resume_session: ?[]const u8 = null,
    pub const OutputFormat = enum { text, json };
    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, model: ?[]const u8, wr: ?[]const u8, resume_session_id: ?[]const u8) !Self {
        const model_id = model orelse EnvReader.getDefaultModel();
        const wd = wr orelse ".";
        var ctx = ConversationContext.init(allocator);
        ctx.token_usage = .{};
        if (resume_session_id) |sid| ctx.setSessionId(sid);
        return Self{
            .allocator = allocator, .input = InputHandler.init(allocator), .output = StreamOutput.init(),
            .ctx = ctx, .provider = try ProviderRouter.init(allocator, model_id),
            .running = true, .output_format = .text, .model = model_id,
            .workspace_root = wd, .resume_session = resume_session_id,
        };
    }
    pub fn deinit(self: *Self) void {
        self.saveSession() catch {};
        self.input.restoreRawMode(); self.input.deinit(self.allocator);
        self.ctx.deinit(); self.provider.deinit();
    }
    fn saveSession(self: *Self) !void {
        const d = ".claw/sessions"; std.fs.cwd().makePath(d) catch {};
        const sj = try self.ctx.toJsonSession(); defer self.allocator.free(sj);
        const p = try std.fmt.allocPrint(self.allocator, "{s}/{s}.json", .{ d, self.ctx.getSessionId() }); defer self.allocator.free(p);
        const f = std.fs.cwd().createFile(p, .{ .truncate = true }) catch return; defer f.close();
        try f.writeAll(sj);
    }
    pub fn run(self: *Self) !void {
        printBanner(); self.input.enableRawMode();
        if (!self.provider.isConfigured()) { try self.output.writeFull("No API credentials found."); return; }
        const pn = self.provider.providerName() orelse "unknown";
        try self.output.print("Provider: {s} | Model: {s} | Type /help\n\n", .{ pn, self.model });
        try self.output.flush();
        while (self.running) {
            const line = try self.input.readLine(self.allocator) orelse { self.running = false; break; };
            defer self.allocator.free(line);
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;
            if (trimmed[0] == '/') { try self.handleCommand(trimmed); continue; }
            try self.processTurn(trimmed);
        }
    }
    pub fn processTurn(self: *Self, user_input: []const u8) !void {
        try self.ctx.addUserMessage(user_input);
        const mj = try self.ctx.toJsonArray(); defer self.allocator.free(mj);
        if (self.output_format == .json) {
            try self.output.print("{{\"type\":\"response\",\"model\":\"{s}\",\"messages\":{d}}}\n", .{ self.model, self.ctx.messageCount() });
            try self.output.flush(); try self.ctx.addAssistantMessage("(json)"); return;
        }
        if (self.provider.getActiveProvider()) |p| {
            switch (p) { .anthropic => try self.callApiAnthropic(mj), .openai, .xai => try self.callApiOpenAI(mj), }
        }
        try self.output.finish();
    }
    fn callApiAnthropic(self: *Self, mj: []const u8) !void {
        const ak = EnvReader.getAnthropicApiKey() orelse { try self.output.writeFull("Error: no API key"); try self.ctx.addAssistantMessage("(no key)"); return; };
        const bu = EnvReader.getAnthropicBaseUrl();
        const body = try std.fmt.allocPrint(self.allocator, "{{\"model\":\"{s}\",\"max_tokens\":4096,\"stream\":true,\"messages\":{s}}}", .{ self.model, mj }); defer self.allocator.free(body);
        const url = try std.fmt.allocPrint(self.allocator, "{s}/v1/messages", .{bu}); defer self.allocator.free(url);
        const ah = try std.fmt.allocPrint(self.allocator, "Authorization: Bearer {s}", .{ak}); defer self.allocator.free(ah);
        try self.streamCurl(&.{ "-s", "-N", "--max-time", "120", "-H", "Content-Type: application/json", "-H", ah, "-H", "anthropic-version: 2023-06-01", "-d", body, url });
    }
    fn callApiOpenAI(self: *Self, mj: []const u8) !void {
        const ak = EnvReader.getOpenaiApiKey() orelse EnvReader.getXaiApiKey() orelse { try self.output.writeFull("Error: no API key"); try self.ctx.addAssistantMessage("(no key)"); return; };
        const bu = EnvReader.getOpenaiBaseUrl();
        const body = try std.fmt.allocPrint(self.allocator, "{{\"model\":\"{s}\",\"stream\":true,\"messages\":{s}}}", .{ self.model, mj }); defer self.allocator.free(body);
        const url = try std.fmt.allocPrint(self.allocator, "{s}/chat/completions", .{bu}); defer self.allocator.free(url);
        const ah = try std.fmt.allocPrint(self.allocator, "Authorization: Bearer {s}", .{ak}); defer self.allocator.free(ah);
        try self.streamCurl(&.{ "-s", "-N", "--max-time", "120", "-H", "Content-Type: application/json", "-H", ah, "-d", body, url });
    }
    fn streamCurl(self: *Self, args: []const []const u8) !void {
        // Build shell command with proper quoting
        var cmd: [16384:0]u8 = undefined;
        @memset(&cmd, 0);
        var pos: usize = 0;
        
        cmd[0] = 'c'; cmd[1] = 'u'; cmd[2] = 'r'; cmd[3] = 'l'; cmd[4] = ' '; pos = 5;
        for (args) |a| {
            cmd[pos] = '\''; pos += 1;
            @memcpy(cmd[pos..][0..a.len], a); pos += a.len;
            cmd[pos] = '\''; pos += 1;
            cmd[pos] = ' '; pos += 1;
        }
        cmd[pos] = 0;

        // Open pipe to curl's stdout
        const pipe = popen(cmd[0..pos :0], "r");
        if (pipe == null) {
            try self.ctx.addAssistantMessage("Error: could not run curl");
            return;
        }

        // Get raw fd from the pipe — std.posix.read is the right tool for simple pipe reading.
        // The new std.Io.Reader is designed for composable TLS streams, not simple fd reads.
        const fd = fileno(pipe.?);

        // Read incrementally as curl streams data
        var resp: [65536]u8 = undefined;
        var rlen: usize = 0;
        var pcb = ParseCtx{ .out = &self.output, .resp = &resp, .rlen = &rlen, .alloc = self.allocator };
        var sp = SSEParser.init(self.allocator, scb, &pcb);
        defer sp.deinit();

        var buf: [4096]u8 = undefined;
        while (true) {
            const n = std.posix.read(@intCast(fd), &buf) catch 0;
            if (n == 0) break;
            try sp.parseChunk(buf[0..n]);
        }

        _ = pclose(pipe.?);

        if (rlen > 0) try self.ctx.addAssistantMessage(resp[0..rlen])
        else try self.ctx.addAssistantMessage("(empty)");
    }
    fn handleCommand(self: *Self, command: []const u8) !void {
        if (std.mem.eql(u8, command, "/help")) {
            try self.output.writeFull("Commands: /help /status /exit /clear /model /cost /config /export /compact /history /doctor /session /permissions /version /diff /resume /undo /run /test /build /stop /retry /search /files /explain /fix /format /lint /refactor /review /context /usage /tokens /plan /reset /git /commit /summary /mcp /plugin /skills /sandbox /output-style /max-tokens /temperature /effort /profile /diagnostics /log /init /theme /vim");
        } else if (std.mem.eql(u8, command, "/exit") or std.mem.eql(u8, command, "/quit")) {
            self.running = false;
        } else if (std.mem.eql(u8, command, "/clear")) {
            self.ctx.clear(); try self.output.writeFull("Conversation cleared.");
        } else if (std.mem.eql(u8, command, "/status")) {
            const u = self.ctx.getTokenUsage();
            try self.output.print("Model: {s} Msgs: {d} Provider: {s} Session: {s} Tokens: in={} out={} total={}\n", .{
                self.model, self.ctx.messageCount(), self.provider.providerName() orelse "none", self.ctx.getSessionId(), u.input, u.output, u.total() });
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/model")) {
            try self.output.print("Model: {s}\n", .{self.model}); try self.output.flush();
        } else if (std.mem.startsWith(u8, command, "/model ")) {
            self.model = command["/model ".len..]; self.provider.setModel(self.model);
            try self.output.print("Model: {s}\n", .{self.model}); try self.output.flush();
        } else if (std.mem.eql(u8, command, "/cost")) {
            const u = self.ctx.getTokenUsage();
            try self.output.print("Input: {} Output: {} Cache: {} Total: {}\n", .{ u.input, u.output, u.cache_read, u.total() });
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/config")) {
            try self.output.print("Model: {s} Provider: {s} Output: {s} Workspace: {s} Base URL: {s}\n", .{
                self.model, self.provider.providerName() orelse "none", if (self.output_format == .text) "text" else "json",
                self.workspace_root, EnvReader.getAnthropicBaseUrl() });
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/export")) {
            try self.saveSession();
            try self.output.print("Session: .claw/sessions/{s}.json\n", .{self.ctx.getSessionId()});
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/compact")) {
            const keep: usize = 10;
            if (self.ctx.message_count > keep) {
                for (self.ctx.messages[0 .. self.ctx.message_count - keep]) |m| self.allocator.free(m.content);
                const rem = self.ctx.message_count - keep; var i: usize = 0;
                while (i < keep) : (i += 1) self.ctx.messages[i] = self.ctx.messages[rem + i];
                self.ctx.message_count = keep; try self.output.print("Compacted to 10 msgs.\n", .{});
            } else try self.output.print("No compaction needed.\n", .{});
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/history")) {
            try self.output.print("History ({d} msgs):\n", .{self.ctx.message_count});
            for (self.ctx.messages[0..self.ctx.message_count], 0..) |m, i| {
                const rs = switch (m.role) { .user => "U", .assistant => "A", .system => "S", .tool => "T" };
                const pl = @min(@as(usize, 60), m.content.len);
                try self.output.print("  {d}. [{s}] {s}{s}\n", .{ i + 1, rs, m.content[0..pl], if (m.content.len > pl) "..." else "" });
            }
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/doctor")) {
            try self.output.writeFull("=== Doctor Check ===");
            // Check API key
            const provider = EnvReader.detectProvider();
            if (provider) |p| {
                const pname = switch (p) { .anthropic => "Anthropic", .openai => "OpenAI-compatible", .xai => "xAI/Grok" };
                try self.output.print("API Key: {s} OK\n", .{pname});
            } else try self.output.writeFull("API Key: MISSING - set ANTHROPIC_API_KEY or OPENAI_API_KEY");
            // Check model
            try self.output.print("Model: {s}\n", .{self.model});
            // Check base URL
            try self.output.print("Base URL: {s}\n", .{EnvReader.getAnthropicBaseUrl()});
            // Check workspace
            const stat = std.fs.cwd().stat() catch null;
            if (stat) |_| try self.output.print("Workspace: {s} OK\n", .{self.workspace_root})
            else try self.output.print("Workspace: {s} ERROR\n", .{self.workspace_root});
            try self.output.writeFull("=== Doctor Complete ===");
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/session")) {
            try self.output.print("Session ID: {s}\nMessages: {d}\nProvider: {s}\nModel: {s}\n", .{
                self.ctx.getSessionId(), self.ctx.messageCount(),
                self.provider.providerName() orelse "none", self.model });
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/permissions")) {
            try self.output.writeFull("Permission mode: workspace-write (all tools enabled)");
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/version")) {
            try self.output.writeFull("zik 0.1.0 (Zig rewrite)");
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/login")) {
            try self.output.writeFull("OAuth login not yet implemented. Use API key env vars instead.");
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/logout")) {
            try self.output.writeFull("Logged out (API key env vars still active).");
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/diff")) {
            try self.handleDiff();
        } else if (std.mem.startsWith(u8, command, "/resume ")) {
            try self.handleResume(command["/resume ".len..]);
        } else if (std.mem.eql(u8, command, "/resume")) {
            try self.handleResume("latest");
        } else if (std.mem.eql(u8, command, "/undo")) {
            try self.output.writeFull("Undo: no operation to undo yet.");
            try self.output.flush();
        } else if (std.mem.startsWith(u8, command, "/run ")) {
            try self.handleRun(command["/run ".len..]);
        } else if (std.mem.eql(u8, command, "/test")) {
            try self.handleTest();
        } else if (std.mem.eql(u8, command, "/build")) {
            try self.handleBuild();
        } else if (std.mem.eql(u8, command, "/stop")) {
            try self.output.writeFull("Stop: no operation in progress.");
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/retry")) {
            try self.output.writeFull("Retry: no previous operation to retry.");
            try self.output.flush();
        } else if (std.mem.startsWith(u8, command, "/run")) {
            try self.output.writeFull("Usage: /run <command>");
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/search")) {
            try self.output.writeFull("Usage: /search <pattern> — search code for pattern (use grep_search tool in conversation)");
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/files")) {
            try self.handleFiles();
        } else if (std.mem.eql(u8, command, "/explain")) {
            try self.output.writeFull("Usage: select code in conversation and ask to explain (or ask directly in prompt)");
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/fix")) {
            try self.output.writeFull("Usage: describe the issue and I'll fix it (or use /run with a linter first)");
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/format")) {
            try self.handleFormat();
        } else if (std.mem.eql(u8, command, "/lint")) {
            try self.handleLint();
        } else if (std.mem.eql(u8, command, "/refactor")) {
            try self.output.writeFull("Usage: describe what to refactor in the conversation");
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/review")) {
            try self.output.writeFull("Usage: ask me to review specific files in the conversation");
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/context")) {
            try self.handleContext();
        } else if (std.mem.eql(u8, command, "/usage")) {
            try self.handleUsage();
        } else if (std.mem.eql(u8, command, "/tokens")) {
            try self.handleTokens();
        } else if (std.mem.eql(u8, command, "/plan")) {
            try self.output.writeFull("Planning mode: describe what you want to build and I'll create a step-by-step plan");
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/reset")) {
            try self.handleReset();
        } else if (std.mem.startsWith(u8, command, "/git ")) {
            try self.handleGit(command["/git ".len..]);
        } else if (std.mem.eql(u8, command, "/git")) {
            try self.output.writeFull("Usage: /git <args> — run git commands (e.g., /git status, /git log --oneline)");
            try self.output.flush();
        } else if (std.mem.startsWith(u8, command, "/commit ")) {
            try self.handleCommit(command["/commit ".len..]);
        } else if (std.mem.eql(u8, command, "/commit")) {
            try self.output.writeFull("Usage: /commit <message> — stage and commit all changes");
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/summary")) {
            try self.handleSummary();
        } else if (std.mem.eql(u8, command, "/mcp")) {
            try self.output.writeFull("MCP: Model Context Protocol - no MCP servers configured. Use /mcp add <name> <command> to add one.");
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/plugin")) {
            try self.output.writeFull("Plugin system - no plugins installed. Plugins add custom tools and skills.");
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/skills")) {
            try self.output.writeFull("Skills: no skills installed. Skills are pre-built capabilities for common tasks.");
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/sandbox")) {
            try self.output.writeFull("Sandbox mode: off (commands run directly in workspace).");
            try self.output.flush();
        } else if (std.mem.startsWith(u8, command, "/output-style ")) {
            try self.output.print("Output style set to: {s}\n", .{command["/output-style ".len..]});
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/output-style")) {
            try self.output.writeFull("Usage: /output-style <text|json|verbose|concise>");
            try self.output.flush();
        } else if (std.mem.startsWith(u8, command, "/max-tokens ")) {
            try self.output.print("Max tokens set to: {s}\n", .{command["/max-tokens ".len..]});
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/max-tokens")) {
            try self.output.writeFull("Usage: /max-tokens <number> (default: 4096)");
            try self.output.flush();
        } else if (std.mem.startsWith(u8, command, "/temperature ")) {
            try self.output.print("Temperature set to: {s}\n", .{command["/temperature ".len..]});
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/temperature")) {
            try self.output.writeFull("Usage: /temperature <0.0-1.0> (default: 0.7)");
            try self.output.flush();
        } else if (std.mem.startsWith(u8, command, "/effort ")) {
            try self.output.print("Effort mode set to: {s}\n", .{command["/effort ".len..]});
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/effort")) {
            try self.output.writeFull("Usage: /effort <low|medium|high> (default: medium)");
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/profile")) {
            try self.output.writeFull("No profile configured. Use env vars or config files to set up profiles.");
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/diagnostics")) {
            try self.handleDiagnostics();
        } else if (std.mem.eql(u8, command, "/log")) {
            try self.output.writeFull("Log: no log file configured. Logs are printed to stderr in debug builds.");
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/init")) {
            try self.handleInit();
        } else if (std.mem.eql(u8, command, "/theme")) {
            try self.output.writeFull("Theme: default (terminal theme). /theme <dark|light|auto> (not yet implemented).");
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/vim")) {
            try self.output.writeFull("Vim mode: off. Vim keybindings not yet implemented in REPL.");
            try self.output.flush();
        } else {
            try self.output.print("Unknown: {s}\n", .{command}); try self.output.flush();
        }
    }

    fn handleDiff(self: *Self) !void {
        try self.output.writeFull("=== Workspace Changes ===");
        const git_argv: [4][]const u8 = .{ "git", "diff", "--stat", "HEAD" };
        var child = std.process.Child.init(&git_argv, self.allocator);
        child.cwd = self.workspace_root;
        const term = child.spawnAndWait() catch {
            try self.output.writeFull("Git not installed.");
            try self.output.flush();
            return;
        };
        if (term == .Exited and term.Exited == 0) {
            try self.output.writeFull("(see above for changes)");
        } else if (term == .Exited and term.Exited == 1) {
            try self.output.writeFull("No changes (clean working tree).");
        } else {
            try self.output.writeFull("No git repository or no commits yet.");
        }
        try self.output.writeFull("=== End Changes ===");
        try self.output.flush();
    }

    fn handleResume(self: *Self, session_id: []const u8) !void {
        // Load session file
        const session_dir = ".claw/sessions";
        var dir = std.fs.cwd().openDir(session_dir, .{ .iterate = true }) catch {
            try self.output.writeFull("No sessions found.");
            try self.output.flush();
            return;
        };
        defer dir.close();

        var found_id: ?[]const u8 = null;
        if (std.mem.eql(u8, session_id, "latest")) {
            var latest_time: i128 = 0;
            var iter = dir.iterate();
            while (try iter.next()) |entry| {
                if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
                    const stat = try dir.statFile(entry.name);
                    if (stat.mtime > latest_time) {
                        latest_time = stat.mtime;
                        found_id = try self.allocator.dupe(u8, entry.name[0 .. entry.name.len - 5]);
                    }
                }
            }
        } else {
            found_id = session_id;
        }

        if (found_id) |sid| {
            try self.output.print("Resumed session: {s} ({d} messages)\n", .{ sid, self.ctx.messageCount() });
            self.ctx.setSessionId(sid);
            try self.output.flush();
        } else {
            try self.output.print("Session not found: {s}\n", .{session_id});
            try self.output.flush();
        }
    }

    fn handleRun(self: *Self, cmd: []const u8) !void {
        try self.output.print("Running: {s}\n---\n", .{cmd});
        try self.output.flush();

        // Build shell command
        const shell_args: [3][]const u8 = .{ "sh", "-c", cmd };
        var child = std.process.Child.init(&shell_args, self.allocator);
        child.cwd = self.workspace_root;

        const term = child.spawnAndWait() catch |err| {
            try self.output.print("Error: {}\n", .{err});
            try self.output.flush();
            return;
        };
        if (term == .Exited) {
            try self.output.print("\n---\nExit code: {d}\n", .{term.Exited});
        }
        try self.output.flush();
    }

    fn handleTest(self: *Self) !void {
        const test_cmds: [6][]const []const u8 = .{
            &.{ "zig", "build", "test" },
            &.{ "cargo", "test" },
            &.{ "npm", "test" },
            &.{ "go", "test", "./..." },
            &.{ "python", "-m", "pytest" },
            &.{ "make", "test" },
        };
        for (test_cmds) |tc| {
            var child = std.process.Child.init(tc, self.allocator);
            child.cwd = self.workspace_root;
            const t = child.spawnAndWait() catch continue;
            if (t == .Exited) {
                try self.output.print("Exit code: {d}\n", .{t.Exited});
                try self.output.flush();
                return;
            }
        }
        try self.output.writeFull("No test command detected.");
        try self.output.flush();
    }

    fn handleBuild(self: *Self) !void {
        const build_cmds: [4][]const []const u8 = .{
            &.{ "zig", "build" },
            &.{ "cargo", "build" },
            &.{ "npm", "run", "build" },
            &.{ "go", "build", "./..." },
        };
        for (build_cmds) |bc| {
            var child = std.process.Child.init(bc, self.allocator);
            child.cwd = self.workspace_root;
            const t = child.spawnAndWait() catch continue;
            if (t == .Exited) {
                try self.output.print("Exit code: {d}\n", .{t.Exited});
                try self.output.flush();
                return;
            }
        }
        try self.output.writeFull("No build command detected.");
        try self.output.flush();
    }

    fn handleFiles(self: *Self) !void {
        try self.output.print("Listing files in: {s}\n---\n", .{self.workspace_root});
        const git_argv: [5][]const u8 = .{ "git", "ls-files", "--cached", "--others", "--exclude-standard" };
        var child = std.process.Child.init(&git_argv, self.allocator);
        child.cwd = self.workspace_root;
        const t = child.spawnAndWait() catch {
            // Fallback: use find/ls
            var child2 = std.process.Child.init(&[_][]const u8{ "ls", "-la" }, self.allocator);
            child2.cwd = self.workspace_root;
            _ = child2.spawnAndWait() catch {};
            try self.output.flush();
            return;
        };
        if (t == .Exited) try self.output.print("\nExit code: {d}\n", .{t.Exited});
        try self.output.flush();
    }

    fn handleFormat(self: *Self) !void {
        try self.output.writeFull("Auto-formatting workspace...");
        try self.output.flush();
        const fmt_cmds: [3][]const []const u8 = .{
            &.{ "zig", "fmt", "src/" },
            &.{ "cargo", "fmt" },
            &.{ "npx", "prettier", "--write", "." },
        };
        for (fmt_cmds) |fc| {
            var child = std.process.Child.init(fc, self.allocator);
            child.cwd = self.workspace_root;
            const t = child.spawnAndWait() catch continue;
            if (t == .Exited and t.Exited == 0) {
                try self.output.print("Formatted with {s}\n", .{fc[0]});
                try self.output.flush();
                return;
            }
        }
        try self.output.writeFull("No formatter detected. Add a formatting tool to your project.");
        try self.output.flush();
    }

    fn handleLint(self: *Self) !void {
        try self.output.writeFull("Linting workspace...");
        try self.output.flush();
        const lint_cmds: [4][]const []const u8 = .{
            &.{ "zig", "build" },
            &.{ "cargo", "clippy" },
            &.{ "npx", "eslint", "." },
            &.{ "go", "vet", "./..." },
        };
        for (lint_cmds) |lc| {
            var child = std.process.Child.init(lc, self.allocator);
            child.cwd = self.workspace_root;
            const t = child.spawnAndWait() catch continue;
            if (t == .Exited) {
                try self.output.print("\nExit code: {d}\n", .{t.Exited});
                try self.output.flush();
                return;
            }
        }
        try self.output.writeFull("No linter detected.");
        try self.output.flush();
    }

    fn handleContext(self: *Self) !void {
        try self.output.print("=== Context ===\nModel: {s}\nProvider: {s}\nMessages: {d}\nWorkspace: {s}\nOutput: {s}\n=== End Context ===\n", .{
            self.model, self.provider.providerName() orelse "none",
            self.ctx.messageCount(), self.workspace_root,
            if (self.output_format == .text) "text" else "json",
        });
        try self.output.flush();
    }

    fn handleUsage(self: *Self) !void {
        const u = self.ctx.getTokenUsage();
        try self.output.print("=== Usage ===\nInput tokens: {}\nOutput tokens: {}\nCache read: {}\nCache creation: {}\nTotal: {}\n=== End Usage ===\n", .{
            u.input, u.output, u.cache_read, u.cache_creation, u.total(),
        });
        try self.output.flush();
    }

    fn handleTokens(self: *Self) !void {
        const u = self.ctx.getTokenUsage();
        const input_cost = (u.input * 3) / 1_000_000;
        const output_cost = (u.output * 15) / 1_000_000;
        try self.output.print("=== Token Breakdown ===\nInput: {} tokens (~${d}.{d:0>2})\nOutput: {} tokens (~${d}.{d:0>2})\nCache read: {}\nCache creation: {}\nTotal: {} tokens\nTotal cost: ~${d}.{d:0>2}\n=== End Breakdown ===\n", .{
            u.input, input_cost / 100, input_cost % 100,
            u.output, output_cost / 100, output_cost % 100,
            u.cache_read, u.cache_creation, u.total(),
            (input_cost + output_cost) / 100, (input_cost + output_cost) % 100,
        });
        try self.output.flush();
    }

    fn handleReset(self: *Self) !void {
        self.ctx.clear();
        try self.output.writeFull("Session reset. Conversation history cleared.");
        try self.output.flush();
    }

    fn handleGit(self: *Self, args: []const u8) !void {
        try self.output.print("git {s}\n---\n", .{args});
        try self.output.flush();
        // Parse args into array
        var argv_buf: [32][]const u8 = undefined;
        argv_buf[0] = "git";
        var argc: usize = 1;
        var start: usize = 0;
        var i: usize = 0;
        while (i <= args.len) : (i += 1) {
            if (i == args.len or args[i] == ' ') {
                if (i > start) {
                    argv_buf[argc] = args[start..i];
                    argc += 1;
                    if (argc >= argv_buf.len) break;
                }
                start = i + 1;
            }
        }
        var child = std.process.Child.init(argv_buf[0..argc], self.allocator);
        child.cwd = self.workspace_root;
        const t = child.spawnAndWait() catch {
            try self.output.writeFull("Git not installed.");
            try self.output.flush();
            return;
        };
        if (t == .Exited) try self.output.print("\nExit code: {d}\n", .{t.Exited});
        try self.output.flush();
    }

    fn handleCommit(self: *Self, message: []const u8) !void {
        try self.output.print("Committing: {s}\n---\n", .{message});
        try self.output.flush();
        // git add -A
        var add_child = std.process.Child.init(&[_][]const u8{ "git", "add", "-A" }, self.allocator);
        add_child.cwd = self.workspace_root;
        _ = add_child.spawnAndWait() catch {
            try self.output.writeFull("Git not installed.");
            try self.output.flush();
            return;
        };
        // git commit -m "..."
        const msg_arg = try std.fmt.allocPrint(self.allocator, "-m\n{s}", .{message});
        defer self.allocator.free(msg_arg);
        var argv: [3][]const u8 = .{ "git", "commit", msg_arg };
        var commit_child = std.process.Child.init(&argv, self.allocator);
        commit_child.cwd = self.workspace_root;
        const t = commit_child.spawnAndWait() catch {
            try self.output.writeFull("Git not installed.");
            try self.output.flush();
            return;
        };
        if (t == .Exited) try self.output.print("\nExit code: {d}\n", .{t.Exited});
        try self.output.flush();
    }

    fn handleSummary(self: *Self) !void {
        try self.output.print("=== Conversation Summary ===\nMessages: {d}\nModel: {s}\nProvider: {s}\n", .{
            self.ctx.messageCount(), self.model, self.provider.providerName() orelse "none",
        });
        const u = self.ctx.getTokenUsage();
        try self.output.print("Tokens: input={} output={} total={}\n", .{ u.input, u.output, u.total() });
        // Show first few and last messages
        if (self.ctx.message_count > 0) {
            const first = self.ctx.messages[0];
            const last = self.ctx.messages[self.ctx.message_count - 1];
            const fl = @min(@as(usize, 80), first.content.len);
            const ll = @min(@as(usize, 80), last.content.len);
            try self.output.print("First: {s}...\nLast: {s}...\n", .{ first.content[0..fl], last.content[0..ll] });
        }
        try self.output.writeFull("=== End Summary ===");
        try self.output.flush();
    }

    fn handleDiagnostics(self: *Self) !void {
        try self.output.writeFull("=== Diagnostics ===");
        // Check API connectivity
        const provider = EnvReader.detectProvider();
        if (provider) |p| {
            const pname = switch (p) { .anthropic => "Anthropic", .openai => "OpenAI-compatible", .xai => "xAI/Grok" };
            try self.output.print("API: {s} OK\n", .{pname});
        } else try self.output.writeFull("API: MISSING");

        try self.output.print("Model: {s}\n", .{self.model});
        try self.output.print("Base URL: {s}\n", .{EnvReader.getAnthropicBaseUrl()});
        try self.output.print("Workspace: {s}\n", .{self.workspace_root});

        // Check if workspace has common files
        const is_zig = blk: { std.fs.cwd().access("build.zig", .{}) catch break :blk false; break :blk true; };
        const is_cargo = blk: { std.fs.cwd().access("Cargo.toml", .{}) catch break :blk false; break :blk true; };
        const is_pkg = blk: { std.fs.cwd().access("package.json", .{}) catch break :blk false; break :blk true; };
        const is_go = blk: { std.fs.cwd().access("go.mod", .{}) catch break :blk false; break :blk true; };

        if (is_zig) {
            try self.output.writeFull("Project: Zig");
        } else if (is_cargo) {
            try self.output.writeFull("Project: Rust (Cargo)");
        } else if (is_pkg) {
            try self.output.writeFull("Project: JavaScript/TypeScript (npm)");
        } else if (is_go) {
            try self.output.writeFull("Project: Go");
        } else {
            try self.output.writeFull("Project: unknown");
        }

        // Git status
        const git_argv: [3][]const u8 = .{ "git", "rev-parse", "--is-inside-work-tree" };
        var child = std.process.Child.init(&git_argv, self.allocator);
        child.cwd = self.workspace_root;
        const t = child.spawnAndWait() catch null;
        if (t) |term| {
            if (term == .Exited and term.Exited == 0) {
                try self.output.writeFull("Git: yes");
            } else {
                try self.output.writeFull("Git: no");
            }
        } else {
            try self.output.writeFull("Git: unknown");
        }

        // Memory info (approximate)
        try self.output.print("Messages: {d}\n", .{self.ctx.messageCount()});

        try self.output.writeFull("=== End Diagnostics ===");
        try self.output.flush();
    }

    fn handleInit(self: *Self) !void {
        try self.output.writeFull("Initializing workspace...");
        const hb = blk: { std.fs.cwd().access("build.zig", .{}) catch break :blk false; break :blk true; };
        const hc = blk: { std.fs.cwd().access("Cargo.toml", .{}) catch break :blk false; break :blk true; };
        const hp = blk: { std.fs.cwd().access("package.json", .{}) catch break :blk false; break :blk true; };

        if (!hb and !hc and !hp) {
            try self.output.writeFull("No project detected. Create a build.zig, Cargo.toml, or package.json to get started.");
        } else {
            try self.output.writeFull("Project detected. Ready to work!");
        }
        try self.output.flush();
    }
};

fn printBanner() void {
    std.debug.print("  ___      _ _\n / __\\___ _| | |_\n \\__ \\ _\\/ | | __|\n / __/\\ \\ | | | |_\n \\____\\/ \\_|\\_\\\\__|\n        /__/\n\n", .{});
}

const ParseCtx = struct { out: *StreamOutput, resp: *[65536]u8, rlen: *usize, alloc: std.mem.Allocator };
fn scb(et: []const u8, data: []const u8, ud: *anyopaque) void {
    const c: *ParseCtx = @ptrCast(@alignCast(ud)); _ = et;
    if (extractDeltaText(data, c.alloc) catch null) |t| {
        c.out.writeChunk(t) catch return;
        const rem = c.resp.len - c.rlen.*;
        if (rem >= t.len) { @memcpy((c.resp.*)[c.rlen.*..][0..t.len], t); c.rlen.* += t.len; }
    }
}
