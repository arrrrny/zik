const std = @import("std");

/// Message in the conversation context.
pub const Message = struct {
    role: Role,
    content: []const u8,

    pub const Role = enum { user, assistant, system, tool };
};

/// Token usage tracking
pub const TokenUsage = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_creation: u64 = 0,

    pub fn total(self: TokenUsage) u64 {
        return self.input + self.output + self.cache_read + self.cache_creation;
    }
};

/// ConversationContext maintains the message history sent to the API.
pub const ConversationContext = struct {
    allocator: std.mem.Allocator,
    messages: []Message = &.{},
    message_count: usize = 0,
    message_capacity: usize = 0,
    system_prompt: []const u8,
    token_usage: TokenUsage,
    session_id: [32]u8 = undefined,
    session_id_len: usize = 0,
    created_at: [32]u8 = undefined,
    created_at_len: usize = 0,
    updated_at: [32]u8 = undefined,
    updated_at_len: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        const ts = getCurrentTimestamp(allocator);
        var self = Self{ .allocator = allocator, .system_prompt = "You are a helpful coding assistant running in a terminal CLI.", .token_usage = TokenUsage{} };
        self.session_id_len = @min(ts.len, 31);
        @memcpy(self.session_id[0..self.session_id_len], ts[0..self.session_id_len]);
        @memcpy(self.created_at[0..self.session_id_len], ts[0..self.session_id_len]);
        self.created_at_len = self.session_id_len;
        @memcpy(self.updated_at[0..self.session_id_len], ts[0..self.session_id_len]);
        self.updated_at_len = self.session_id_len;
        allocator.free(ts);
        self.token_usage = TokenUsage{};
        return self;
    }

    pub fn getSessionId(self: *const Self) []const u8 {
        return self.session_id[0..self.session_id_len];
    }

    pub fn setSessionId(self: *Self, id: []const u8) void {
        self.session_id_len = @min(id.len, 31);
        @memcpy(self.session_id[0..self.session_id_len], id[0..self.session_id_len]);
    }

    fn getCreatedAt(self: *const Self) []const u8 {
        return self.created_at[0..self.created_at_len];
    }

    fn getUpdatedAt(self: *const Self) []const u8 {
        return self.updated_at[0..self.updated_at_len];
    }

    pub fn deinit(self: *Self) void {
        for (self.messages[0..self.message_count]) |msg| {
            self.allocator.free(msg.content);
        }
        if (self.message_capacity > 0) {
            self.allocator.free(self.messages);
        }
        // No need to free session_id/created_at/updated_at — they're fixed buffers
    }

    fn ensureCapacity(self: *Self, needed: usize) !void {
        if (needed <= self.message_capacity) return;
        const new_cap = @max(needed, self.message_capacity * 2 + 4);
        const new_msgs = try self.allocator.realloc(self.messages, new_cap);
        self.messages = new_msgs;
        self.message_capacity = new_cap;
    }

    pub fn addUserMessage(self: *Self, content: []const u8) !void {
        try self.ensureCapacity(self.message_count + 1);
        self.messages[self.message_count] = .{
            .role = .user,
            .content = try self.allocator.dupe(u8, content),
        };
        self.message_count += 1;
        { const ts = getCurrentTimestamp(self.allocator); self.updated_at_len = @min(ts.len, 31); @memcpy(self.updated_at[0..self.updated_at_len], ts[0..self.updated_at_len]); self.allocator.free(ts); }
    }

    pub fn addAssistantMessage(self: *Self, content: []const u8) !void {
        try self.ensureCapacity(self.message_count + 1);
        self.messages[self.message_count] = .{
            .role = .assistant,
            .content = try self.allocator.dupe(u8, content),
        };
        self.message_count += 1;
        { const ts = getCurrentTimestamp(self.allocator); self.updated_at_len = @min(ts.len, 31); @memcpy(self.updated_at[0..self.updated_at_len], ts[0..self.updated_at_len]); self.allocator.free(ts); }
    }

    /// Serialize messages to JSON array for API.
    pub fn toJsonArray(self: *const Self) ![]const u8 {
        var result = try std.fmt.allocPrint(
            self.allocator,
            "[{{\"role\":\"system\",\"content\":\"{s}\"}}",
            .{self.system_prompt},
        );

        for (self.messages[0..self.message_count]) |msg| {
            const role_str = switch (msg.role) {
                .user => "user",
                .assistant => "assistant",
                .system => "system",
                .tool => "tool",
            };
            const entry = try std.fmt.allocPrint(
                self.allocator,
                ",{{\"role\":\"{s}\",\"content\":\"{s}\"}}",
                .{ role_str, msg.content },
            );
            const combined = try std.fmt.allocPrint(
                self.allocator,
                "{s}{s}",
                .{ result, entry },
            );
            self.allocator.free(result);
            self.allocator.free(entry);
            result = combined;
        }

        const final = try std.fmt.allocPrint(self.allocator, "{s}]", .{result});
        self.allocator.free(result);
        return final;
    }

    /// Serialize full session state for persistence.
    pub fn toJsonSession(self: *const Self) ![]const u8 {
        const messages_json = try self.toJsonArray();
        defer self.allocator.free(messages_json);

        return try std.fmt.allocPrint(
            self.allocator,
            \\{{"session_id":"{s}","model":"TODO","permission_mode":"workspace-write","workspace_root":".","created_at":"{s}","updated_at":"{s}","token_usage":{{"input":{},"output":{},"cache_read":{},"cache_creation":{}}},"messages":{s}}}
        ,
            .{
                self.getSessionId(),
                self.getCreatedAt(),
                self.getUpdatedAt(),
                self.token_usage.input,
                self.token_usage.output,
                self.token_usage.cache_read,
                self.token_usage.cache_creation,
                messages_json,
            },
        );
    }

    pub fn clear(self: *Self) void {
        for (self.messages[0..self.message_count]) |msg| {
            self.allocator.free(msg.content);
        }
        self.message_count = 0;
    }

    pub fn messageCount(self: *const Self) usize {
        return self.message_count;
    }

    pub fn getTokenUsage(self: *const Self) TokenUsage {
        return self.token_usage;
    }

    pub fn addTokenUsage(self: *Self, input: u64, output: u64) void {
        self.token_usage.input += input;
        self.token_usage.output += output;
    }
};

fn getCurrentTimestamp(allocator: std.mem.Allocator) []const u8 {
    // Simple timestamp: just use epoch seconds
    const now = std.time.timestamp();
    return std.fmt.allocPrint(allocator, "{d}", .{now}) catch "unknown";
}

test "ConversationContext: add messages and serialize" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = ConversationContext.init(allocator);
    defer ctx.deinit();

    try ctx.addUserMessage("Hello");
    try ctx.addAssistantMessage("Hi there!");

    try std.testing.expectEqual(@as(usize, 2), ctx.messageCount());

    const json = try ctx.toJsonArray();
    defer allocator.free(json);

    try std.testing.expect(json.len > 2);
    try std.testing.expectEqual(@as(u8, '['), json[0]);
    try std.testing.expectEqual(@as(u8, ']'), json[json.len - 1]);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"role\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"role\":\"assistant\"") != null);
}

test "ConversationContext: clear" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = ConversationContext.init(allocator);
    defer ctx.deinit();

    try ctx.addUserMessage("test");
    try std.testing.expectEqual(@as(usize, 1), ctx.messageCount());

    ctx.clear();
    try std.testing.expectEqual(@as(usize, 0), ctx.messageCount());
}

test "TokenUsage: tracking" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = ConversationContext.init(allocator);
    defer ctx.deinit();

    ctx.addTokenUsage(100, 50);
    ctx.addTokenUsage(200, 100);

    const usage = ctx.getTokenUsage();
    try std.testing.expectEqual(@as(u64, 300), usage.input);
    try std.testing.expectEqual(@as(u64, 150), usage.output);
    try std.testing.expectEqual(@as(u64, 450), usage.total());
}

test "ConversationContext: session JSON" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = ConversationContext.init(allocator);
    defer ctx.deinit();

    try ctx.addUserMessage("test");
    ctx.addTokenUsage(100, 50);

    const session_json = try ctx.toJsonSession();
    defer allocator.free(session_json);

    try std.testing.expect(std.mem.indexOf(u8, session_json, "\"session_id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, session_json, "\"token_usage\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, session_json, "\"messages\"") != null);
}
