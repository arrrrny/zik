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

        if (resume_session_id) |sid| {
            ctx.session_id = sid;
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
        self.saveSession() catch {};
        self.input.restoreRawMode();
        self.input.deinit(self.allocator);
        self.ctx.deinit();
        self.provider.deinit();
    }

    fn saveSession(self: *Self) !void {
        const dir = ".claw/sessions";
        std.fs.cwd().makePath(dir) catch {};
        const sj = try self.ctx.toJsonSession();
        defer self.allocator.free(sj);
        const p = try std.fmt.allocPrint(self.allocator, "{s}/{s}.json", .{ dir, self.ctx.session_id });
        defer self.allocator.free(p);
        const f = std.fs.cwd().createFile(p, .{ .truncate = true }) catch return;
        defer f.close();
        try f.writeAll(sj);
    }

    pub fn run(self: *Self) !void {
        printBanner();
        self.input.enableRawMode();
        if (!self.provider.isConfigured()) {
            try self.output.writeFull("No API credentials found.");
            return;
        }
        const pn = self.provider.providerName() orelse "unknown";
        try self.output.print("Provider: {s} | Model: {s} | Type /help for commands\n\n", .{ pn, self.model });
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
        const mj = try self.ctx.toJsonArray();
        defer self.allocator.free(mj);
        if (self.output_format == .json) {
            try self.output.print("{{\"type\":\"response\",\"model\":\"{s}\",\"messages\":{d}}}\n", .{ self.model, self.ctx.messageCount() });
            try self.output.flush();
            try self.ctx.addAssistantMessage("(json mode response)");
            return;
        }
        if (self.provider.getActiveProvider()) |p| {
            switch (p) {
                .anthropic => try self.callApiAnthropic(mj),
                .openai => try self.callApiOpenAI(mj),
                .xai => try self.callApiOpenAI(mj),
            }
        }
        try self.output.finish();
    }

    fn callApiAnthropic(self: *Self, mj: []const u8) !void {
        const ak = EnvReader.getAnthropicApiKey() orelse {
            try self.output.writeFull("Error: ANTHROPIC_API_KEY not set");
            try self.ctx.addAssistantMessage("(error: no key)");
            return;
        };
        const bu = EnvReader.getAnthropicBaseUrl();
        const body = try std.fmt.allocPrint(self.allocator,
            "{{\"model\":\"{s}\",\"max_tokens\":4096,\"stream\":true,\"messages\":{s}}}",
            .{ self.model, mj });
        defer self.allocator.free(body);
        const url = try std.fmt.allocPrint(self.allocator, "{s}/v1/messages", .{bu});
        defer self.allocator.free(url);
        const ah = try std.fmt.allocPrint(self.allocator, "Authorization: Bearer {s}", .{ak});
        defer self.allocator.free(ah);
        try self.streamCurl(&.{ "-s", "-N", "--max-time", "120", "-H", "Content-Type: application/json", "-H", ah, "-H", "anthropic-version: 2023-06-01", "-d", body, url }, true);
    }

    fn callApiOpenAI(self: *Self, mj: []const u8) !void {
        const ak = EnvReader.getOpenaiApiKey() orelse EnvReader.getXaiApiKey() orelse {
            try self.output.writeFull("Error: No API key set");
            try self.ctx.addAssistantMessage("(error: no key)");
            return;
        };
        const bu = EnvReader.getOpenaiBaseUrl();
        const body = try std.fmt.allocPrint(self.allocator,
            "{{\"model\":\"{s}\",\"stream\":true,\"messages\":{s}}}",
            .{ self.model, mj });
        defer self.allocator.free(body);
        const url = try std.fmt.allocPrint(self.allocator, "{s}/chat/completions", .{bu});
        defer self.allocator.free(url);
        const ah = try std.fmt.allocPrint(self.allocator, "Authorization: Bearer {s}", .{ak});
        defer self.allocator.free(ah);
        try self.streamCurl(&.{ "-s", "-N", "--max-time", "120", "-H", "Content-Type: application/json", "-H", ah, "-d", body, url }, false);
    }

    fn streamCurl(self: *Self, args: []const []const u8, is_anthropic: bool) !void {
        const out_path = "/tmp/.zik_stream_out";
        var argv: [40][]const u8 = undefined;
        argv[0] = "curl";
        var argc: usize = 1;
        for (args) |a| { argv[argc] = a; argc += 1; }
        argv[argc] = "-o"; argc += 1;
        argv[argc] = out_path; argc += 1;
        argv[argc] = "--stderr"; argc += 1;
        argv[argc] = "/dev/null"; argc += 1;

        var child = std.process.Child.init(argv[0..argc], self.allocator);
        _ = try child.spawnAndWait();

        // Read the response and stream it through SSE parser
        const f = std.fs.cwd().openFile(out_path, .{}) catch {
            try self.ctx.addAssistantMessage("(no response)");
            return;
        };
        defer f.close();
        std.fs.cwd().deleteFile(out_path) catch {};

        var resp: [65536]u8 = undefined;
        var rlen: usize = 0;
        var pcb = ParseCtx{ .out = &self.output, .resp = &resp, .rlen = &rlen, .alloc = self.allocator };
        var sp = SSEParser.init(self.allocator, if (is_anthropic) scb else ocb, &pcb);
        defer sp.deinit();

        var buf: [4096]u8 = undefined;
        while (true) {
            const n = f.read(&buf) catch 0;
            if (n == 0) break;
            try sp.parseChunk(buf[0..n]);
        }

        if (rlen > 0) try self.ctx.addAssistantMessage(resp[0..rlen])
        else try self.ctx.addAssistantMessage("(empty response)");
    }

    const ParseCtx = struct { out: *StreamOutput, resp: *[65536]u8, rlen: *usize, alloc: std.mem.Allocator };

    fn scb(et: []const u8, data: []const u8, ud: *anyopaque) void {
        const c: *ParseCtx = @ptrCast(@alignCast(ud));
        _ = et;
        if (extractDeltaText(data, c.alloc) catch null) |t| {
            c.out.writeChunk(t) catch return;
            const rem = c.resp.len - c.rlen.*;
            if (rem >= t.len) { @memcpy((c.resp.*)[c.rlen.*..][0..t.len], t); c.rlen.* += t.len; }
        }
    }

    fn ocb(et: []const u8, data: []const u8, ud: *anyopaque) void {
        const c: *ParseCtx = @ptrCast(@alignCast(ud));
        _ = et;
        if (extractOpenAIChoiceDelta(data, c.alloc) catch null) |t| {
            c.out.writeChunk(t) catch return;
            const rem = c.resp.len - c.rlen.*;
            if (rem >= t.len) { @memcpy((c.resp.*)[c.rlen.*..][0..t.len], t); c.rlen.* += t.len; }
        }
    }

    fn handleCommand(self: *Self, command: []const u8) !void {
        if (std.mem.eql(u8, command, "/help")) {
            try self.output.writeFull("Commands: /help /status /exit /clear /model /cost /config /export /compact /history");
        } else if (std.mem.eql(u8, command, "/exit") or std.mem.eql(u8, command, "/quit")) {
            self.running = false;
        } else if (std.mem.eql(u8, command, "/clear")) {
            self.ctx.clear();
            try self.output.writeFull("Conversation cleared.");
        } else if (std.mem.eql(u8, command, "/status")) {
            const u = self.ctx.getTokenUsage();
            try self.output.print("Model: {s} Messages: {d} Provider: {s} Session: {s} Tokens: in={} out={} total={}\n", .{
                self.model, self.ctx.messageCount(), self.provider.providerName() orelse "none",
                self.ctx.session_id, u.input, u.output, u.total(),
            });
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/model")) {
            try self.output.print("Model: {s}\n", .{self.model});
            try self.output.flush();
        } else if (std.mem.startsWith(u8, command, "/model ")) {
            self.model = command["/model ".len..];
            self.provider.setModel(self.model);
            try self.output.print("Model: {s}\n", .{self.model});
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/cost")) {
            const u = self.ctx.getTokenUsage();
            try self.output.print("Input: {} Output: {} Cache: {}\n", .{ u.input, u.output, u.cache_read });
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/config")) {
            try self.output.print("Model: {s} Provider: {s} Output: {s}\n", .{
                self.model, self.provider.providerName() orelse "none",
                if (self.output_format == .text) "text" else "json",
            });
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/export")) {
            try self.saveSession();
            try self.output.print("Session saved: .claw/sessions/{s}.json\n", .{self.ctx.session_id});
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/compact")) {
            const keep: usize = 10;
            if (self.ctx.message_count > keep) {
                for (self.ctx.messages[0 .. self.ctx.message_count - keep]) |m| self.allocator.free(m.content);
                const rem = self.ctx.message_count - keep;
                var i: usize = 0;
                while (i < keep) : (i += 1) self.ctx.messages[i] = self.ctx.messages[rem + i];
                self.ctx.message_count = keep;
                try self.output.print("Compacted to 10 messages.\n", .{});
            } else try self.output.print("No compaction needed.\n", .{});
            try self.output.flush();
        } else if (std.mem.eql(u8, command, "/history")) {
            try self.output.print("History ({d} messages):\n", .{self.ctx.message_count});
            for (self.ctx.messages[0..self.ctx.message_count], 0..) |m, i| {
                const rs = switch (m.role) { .user => "U", .assistant => "A", .system => "S", .tool => "T" };
                const pl = @min(@as(usize, 60), m.content.len);
                try self.output.print("  {d}. [{s}] {s}{s}\n", .{ i + 1, rs, m.content[0..pl], if (m.content.len > pl) "..." else "" });
            }
            try self.output.flush();
        } else {
            try self.output.print("Unknown: {s}\n", .{command});
            try self.output.flush();
        }
    }
};

fn printBanner() void {
    std.debug.print("  ___      _ _\n / __\\___ _| | |_\n \\__ \\ _\\/ | | __|\n / __/\\ \\ | | | |_\n \\____\\/ \\_|\\_\\\\__|\n        /__/\n\n", .{});
}
