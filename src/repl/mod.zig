const std = @import("std");
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

        // If resuming, try to load the session
        if (resume_session_id) |session_id| {
            const loaded = try loadSession(allocator, session_id);
            if (loaded) |_| {
                // Parse and restore session
                // For now, just set the session ID
                ctx.session_id = resume_session_id.?;
            }
        }

        return Self{
            .allocator = allocator,
            .input = InputHandler.init(allocator),
            .output = StreamOutput.init(),
            .ctx = ctx,
            .provider = try ProviderRouter.init(allocator, model_id),
            .running = true,
            .output_format = .text,
            .model = model_id,
            .workspace_root = wd,
            .resume_session = resume_session_id,
        };
    }

    pub fn deinit(self: *Self) void {
        // Save session before exit
        self.saveSession() catch {};
        self.input.restoreRawMode();
        self.input.deinit(self.allocator);
        self.ctx.deinit();
        self.provider.deinit();
    }

    fn saveSession(self: *Self) !void {
        const session_dir = ".claw/sessions";
        std.fs.cwd().makePath(session_dir) catch {};

        const session_json = try self.ctx.toJsonSession();
        defer self.allocator.free(session_json);

        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.json", .{ session_dir, self.ctx.session_id });
        defer self.allocator.free(path);

        const file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch |err| {
            std.debug.print("Warning: Could not save session: {}\n", .{err});
            return;
        };
        defer file.close();
        try file.writeAll(session_json);
    }

    fn loadSession(allocator: std.mem.Allocator, session_id: []const u8) !?SessionData {
        const session_dir = ".claw/sessions";

        if (std.mem.eql(u8, session_id, "latest")) {
            // Find most recent session
            var dir = std.fs.cwd().openDir(session_dir, .{ .iterate = true }) catch return null;
            defer dir.close();

            var latest_time: i128 = 0;
            var latest_name: ?[]const u8 = null;

            var iter = dir.iterate();
            while (try iter.next()) |entry| {
                if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
                    const stat = try dir.statFile(entry.name);
                    if (stat.mtime > latest_time) {
                        latest_time = stat.mtime;
                        if (latest_name) |old| allocator.free(old);
                        latest_name = try allocator.dupe(u8, entry.name);
                    }
                }
            }

            if (latest_name) |name| {
                defer allocator.free(name);
                return SessionData{ .session_id = name[0..name.len - 5] }; // strip .json
            }
            return null;
        }

        // Load specific session
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ session_dir, session_id });
        defer allocator.free(path);

        const file = std.fs.cwd().openFile(path, .{}) catch return null;
        defer file.close();

        return SessionData{ .session_id = session_id };
    }

    const SessionData = struct {
        session_id: []const u8,
    };

    pub fn run(self: *Self) !void {
        printBanner();
        self.input.enableRawMode();
        if (!self.provider.isConfigured()) {
            try self.output.writeFull("No API credentials found. Set ANTHROPIC_API_KEY, OPENAI_API_KEY, or XAI_API_KEY.");
            return;
        }
        const provider_name = self.provider.providerName() orelse "unknown";
        try self.output.print("Provider: {s} | Model: {s} | Type /help for commands\n\n", .{ provider_name, self.model });
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
        const messages_json = try self.ctx.toJsonArray();
        defer self.allocator.free(messages_json);

        if (self.output_format == .json) {
            try self.output.print("{{\"type\":\"response\",\"model\":\"{s}\",\"messages\":{d}}}\n", .{ self.model, self.ctx.messageCount() });
            try self.output.flush();
            try self.ctx.addAssistantMessage("(json mode response)");
            return;
        }

        if (self.provider.getActiveProvider()) |p| {
            switch (p) {
                .anthropic => try self.callApiAnthropic(messages_json),
                .openai => try self.callApiOpenAI(messages_json),
                .xai => try self.callApiOpenAI(messages_json),
            }
        }
        try self.output.finish();
    }

    fn callApiAnthropic(self: *Self, messages_json: []const u8) !void {
        const api_key = EnvReader.getAnthropicApiKey() orelse {
            try self.output.writeFull("Error: ANTHROPIC_API_KEY not set");
            try self.ctx.addAssistantMessage("(error: no key)");
            return;
        };
        const base_url = EnvReader.getAnthropicBaseUrl();
        const body = try std.fmt.allocPrint(self.allocator,
            "{{\"model\":\"{s}\",\"max_tokens\":4096,\"stream\":true,\"messages\":{s}}}",
            .{ self.model, messages_json });
        defer self.allocator.free(body);

        const url = try std.fmt.allocPrint(self.allocator, "{s}/v1/messages", .{base_url});
        defer self.allocator.free(url);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Authorization: Bearer {s}", .{api_key});
        defer self.allocator.free(auth_header);

        try self.streamCurl(&.{
            "-s", "-N", "--max-time", "120",
            "-H", "Content-Type: application/json",
            "-H", auth_header,
            "-H", "anthropic-version: 2023-06-01",
            "-d", body,
            url,
        }, true);
    }

    fn callApiOpenAI(self: *Self, messages_json: []const u8) !void {
        const api_key = EnvReader.getOpenaiApiKey() orelse EnvReader.getXaiApiKey() orelse {
            try self.output.writeFull("Error: No API key set");
            try self.ctx.addAssistantMessage("(error: no key)");
            return;
        };
        const base_url = EnvReader.getOpenaiBaseUrl();
        const body = try std.fmt.allocPrint(self.allocator,
            "{{\"model\":\"{s}\",\"stream\":true,\"messages\":{s}}}",
            .{ self.model, messages_json });
        defer self.allocator.free(body);

        const url = try std.fmt.allocPrint(self.allocator, "{s}/chat/completions", .{base_url});
        defer self.allocator.free(url);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Authorization: Bearer {s}", .{api_key});
        defer self.allocator.free(auth_header);

        try self.streamCurl(&.{
            "-s", "-N", "--max-time", "120",
            "-H", "Content-Type: application/json",
            "-H", auth_header,
            "-d", body,
            url,
        }, false);
    }

    /// Stream curl output via pipe — reads incrementally as data arrives.
    fn streamCurl(self: *Self, curl_args: []const []const u8, is_anthropic: bool) !void {
        // Build argv: curl + args
        var argv_buf: [32][]const u8 = undefined;
        argv_buf[0] = "curl";
        for (curl_args, 1..) |arg, i| {
            argv_buf[i] = arg;
        }
        const argc = 1 + curl_args.len;

        // Create pipe for stdout
        const pipe = try std.posix.pipe();
        const read_fd = pipe[0];
        const write_fd = pipe[1];
        defer std.posix.close(read_fd);

        // Spawn curl with stdout -> pipe write end
        var child = std.process.Child.init(argv_buf[0..argc], self.allocator);
        child.stdout = .{ .fd = write_fd };
        child.stderr = .{ .action = .ignore };

        try child.spawn();

        // Close write end in parent — we only read
        std.posix.close(write_fd);

        // Stream: read chunks from pipe, parse SSE, display text immediately
        var response_text: [65536]u8 = undefined;
        var response_len: usize = 0;

        var parser_ctx = StreamParserContext{ .output = &self.output, .response_text = &response_text, .response_len = &response_len, .allocator = self.allocator };
        var sse_parser = SSEParser.init(self.allocator, if (is_anthropic) sseCallback else openAICallback, &parser_ctx);
        defer sse_parser.deinit();

        var read_buf: [4096]u8 = undefined;
        while (true) {
            const n = std.posix.read(read_fd, &read_buf) catch 0;
            if (n == 0) break;
            try sse_parser.parseChunk(read_buf[0..n]);
        }

        // Wait for curl to finish
        _ = try child.wait();

        if (response_len > 0) {
            try self.ctx.addAssistantMessage(response_text[0..response_len]);
        } else {
            try self.ctx.addAssistantMessage("(empty response)");
        }
    }

    const StreamParserContext = struct {
        output: *StreamOutput,
        response_text: *[65536]u8,
        response_len: *usize,
        allocator: std.mem.Allocator,
    };

    fn sseCallback(event_type: []const u8, data: []const u8, user_data: *anyopaque) void {
        const ctx: *StreamParserContext = @ptrCast(@alignCast(user_data));
        _ = event_type;
        if (extractDeltaText(data, ctx.allocator) catch null) |text| {
            ctx.output.writeChunk(text) catch return;
            const remaining = ctx.response_text.len - ctx.response_len.*;
            if (remaining >= text.len) {
                @memcpy((ctx.response_text.*)[ctx.response_len.*..][0..text.len], text);
                ctx.response_len.* += text.len;
            }
        }
    }

    fn openAICallback(event_type: []const u8, data: []const u8, user_data: *anyopaque) void {
        const ctx: *StreamParserContext = @ptrCast(@alignCast(user_data));
        _ = event_type;
        if (extractOpenAIChoiceDelta(data, ctx.allocator) catch null) |text| {
            ctx.output.writeChunk(text) catch return;
            const remaining = ctx.response_text.len - ctx.response_len.*;
            if (remaining >= text.len) {
                @memcpy((ctx.response_text.*)[ctx.response_len.*..][0..text.len], text);
                ctx.response_len.* += text.len;
            }
        }
    }
}

fn handleCommand(self: *Self, command: []const u8) !void {
    if (std.mem.eql(u8, command, "/help")) {
                \\  /status        Session status (model, messages, provider, tokens)
                \\  /exit, /quit   Exit the REPL (saves session)
                \\  /clear         Clear conversation history
                \\  /model         Show current model
                \\  /model <name>  Change model
                \\  /cost          Show token usage and estimated cost
                \\  /config        Show effective configuration
                \\  /export        Export session to JSON
                \\  /compact       Compact conversation (remove old messages)
                \\  /history       Show message history summary
                \\
            );
        } else if (std.mem.eql(u8, command, "/exit") or std.mem.eql(u8, command, "/quit")) {
            self.running = false;
        } else if (std.mem.eql(u8, command, "/clear")) {
            self.ctx.clear();
            try self.output.writeFull("Conversation cleared.");
        } else if (std.mem.eql(u8, command, "/status")) {
            const usage = self.ctx.getTokenUsage();
            try self.output.print(
                \\Model: {s}
                \\Messages: {d}
                \\Provider: {s}
                \\Session: {s}
                \\Tokens: input={} output={} total={}
                \\
            , .{
                self.model, self.ctx.messageCount(),
                self.provider.providerName() orelse "none",
                self.ctx.session_id,
                usage.input, usage.output, usage.total(),
            });
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/model")) {
            try self.output.print("Current model: {s}\n", .{self.model});
            try self.output.flush();
        } else if (std.mem.startsWith(u8, command, "/model ")) {
            self.model = command["/model ".len..];
            self.provider.setModel(self.model);
            try self.output.print("Model set to: {s}\n", .{self.model});
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/cost")) {
            const usage = self.ctx.getTokenUsage();
            // Rough pricing for Claude Sonnet: $3/M input, $15/M output
            const input_cost_cents = (usage.input * 3) / 1_000_000;
            const output_cost_cents = (usage.output * 15) / 1_000_000;
            const total_cost_cents = input_cost_cents + output_cost_cents;
            try self.output.print(
                \\Token Usage:
                \\  Input tokens:  {}
                \\  Output tokens: {}
                \\  Cache read:    {}
                \\  Cache write:   {}
                \\  Total tokens:  {}
                \\  Est. cost:     ~{d} cents (Sonnet pricing)
                \\
            , .{
                usage.input, usage.output,
                usage.cache_read, usage.cache_creation,
                usage.total(),
                total_cost_cents,
            });
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/config")) {
            try self.output.print(
                \\Effective Configuration:
                \\  Model: {s}
                \\  Provider: {s}
                \\  Output format: {s}
                \\  Workspace: {s}
                \\  Base URL: {s}
                \\
            , .{
                self.model,
                self.provider.providerName() orelse "none",
                if (self.output_format == .text) "text" else "json",
                self.workspace_root,
                EnvReader.getAnthropicBaseUrl(),
            });
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/export")) {
            // Save session and show path
            try self.saveSession();
            try self.output.print("Session exported: .claw/sessions/{s}.json\n", .{self.ctx.session_id});
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/compact")) {
            // Keep last 10 messages, clear the rest
            const keep = @min(@as(usize, 10), self.ctx.message_count);
            if (self.ctx.message_count > keep) {
                // Free removed messages
                for (self.ctx.messages[0 .. self.ctx.message_count - keep]) |msg| {
                    self.allocator.free(msg.content);
                }
                // Shift remaining messages to start
                const remaining = self.ctx.message_count - keep;
                var i: usize = 0;
                while (i < keep) : (i += 1) {
                    self.ctx.messages[i] = self.ctx.messages[remaining + i];
                }
                self.ctx.message_count = keep;
                try self.output.print("Compacted to {d} messages.\n", .{keep});
            } else {
                try self.output.print("No compaction needed ({d} messages).\n", .{self.ctx.message_count});
            }
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/history")) {
            try self.output.print("Message history ({d} messages):\n", .{self.ctx.message_count});
            for (self.ctx.messages[0..self.ctx.message_count], 0..) |msg, i| {
                const role_str = switch (msg.role) {
                    .user => "U",
                    .assistant => "A",
                    .system => "S",
                    .tool => "T",
                };
                const preview_len = @min(@as(usize, 60), msg.content.len);
                try self.output.print("  {d}. [{s}] {s}{s}\n", .{
                    i + 1, role_str,
                    msg.content[0..preview_len],
                    if (msg.content.len > preview_len) "..." else "",
                });
            }
            try self.output.flush();
        } else {
            try self.output.print("Unknown command: {s}\n", .{command});
            try self.output.flush();
        }
    }
};

fn printBanner() void {
    std.debug.print("  ___      _ _\n / __\\___ _| | |_\n \\__ \\ _\\/ | | __|\n / __/\\ \\ | | | |_\n \\____\\/ \\_|\\_\\\\__|\n        /__/\n\n", .{});
}

const CurlResult = struct { stdout: []const u8, stderr: []const u8, exit_code: i32 };

fn execCurl(allocator: std.mem.Allocator, extra_args: []const []const u8) !CurlResult {
    const stdout_path = "/tmp/.claw_curl_out";
    const stderr_path = "/tmp/.claw_curl_err";

    // Build argv with output redirection
    var argv: [36][]const u8 = undefined;
    var argc: usize = 0;
    argv[argc] = "curl"; argc += 1;
    for (extra_args) |arg| { argv[argc] = arg; argc += 1; }
    argv[argc] = "-o"; argc += 1;
    argv[argc] = stdout_path; argc += 1;
    argv[argc] = "--stderr"; argc += 1;
    argv[argc] = stderr_path; argc += 1;

    var child = std.process.Child.init(argv[0..argc], allocator);
    const term = try child.spawnAndWait();
    const exit_code: i32 = if (term == .Exited) @intCast(term.Exited) else 1;

    // Read output files
    const stdout_content = readFileSafely(allocator, stdout_path, 131072) catch "";
    const stderr_content = readFileSafely(allocator, stderr_path, 4096) catch "";

    // Cleanup
    std.fs.cwd().deleteFile(stdout_path) catch {};
    std.fs.cwd().deleteFile(stderr_path) catch {};

    return CurlResult{
        .stdout = stdout_content,
        .stderr = stderr_content,
        .exit_code = exit_code,
    };
}

fn readFileSafely(allocator: std.mem.Allocator, path: []const u8, max_size: usize) ![]const u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch return "";
    defer file.close();
    return file.readToEndAlloc(allocator, max_size) catch "";
}

const StreamParserContext = struct {
    output: *StreamOutput,
    response_text: *[65536]u8,
    response_len: *usize,
    allocator: std.mem.Allocator,
};

fn sseCallback(event_type: []const u8, data: []const u8, user_data: *anyopaque) void {
    const ctx: *StreamParserContext = @ptrCast(@alignCast(user_data));
    _ = event_type;
    if (extractDeltaText(data, ctx.allocator) catch null) |text| {
        ctx.output.writeChunk(text) catch return;
        const remaining = ctx.response_text.len - ctx.response_len.*;
        if (remaining >= text.len) {
            @memcpy((ctx.response_text.*)[ctx.response_len.*..][0..text.len], text);
            ctx.response_len.* += text.len;
        }
    }
}

fn openAICallback(event_type: []const u8, data: []const u8, user_data: *anyopaque) void {
    const ctx: *StreamParserContext = @ptrCast(@alignCast(user_data));
    _ = event_type;
    if (extractOpenAIChoiceDelta(data, ctx.allocator) catch null) |text| {
        ctx.output.writeChunk(text) catch return;
        const remaining = ctx.response_text.len - ctx.response_len.*;
        if (remaining >= text.len) {
            @memcpy((ctx.response_text.*)[ctx.response_len.*..][0..text.len], text);
            ctx.response_len.* += text.len;
        }
    }
}
