/// Message represents a single turn in the conversation.
pub const Message = struct {
    /// Message origin
    role: Role,
    /// Message content
    content: []const u8,
    /// When the message was created (ISO 8601)
    timestamp: []const u8,
    /// Token count for this message
    tokens_used: ?u32 = null,
    /// Tool call records (for assistant messages)
    tool_calls: []ToolCall = &.{},
    /// Tool results (for tool messages)
    tool_results: []ToolResult = &.{},

    pub const Role = enum {
        user,
        assistant,
        system,
        tool,
    };
};

/// ToolCall represents a record of a tool invocation by the assistant.
pub const ToolCall = struct {
    /// Unique call identifier
    id: []const u8,
    /// Name of the tool invoked
    tool_name: []const u8,
    /// Tool input parameters (JSON string)
    input: []const u8,
    /// Tool output/result (JSON string)
    output: []const u8,
    /// Execution status
    status: Status = .pending,
    /// Execution time in milliseconds
    duration_ms: u64 = 0,

    pub const Status = enum {
        pending,
        success,
        tool_error,
        denied,
    };
};

/// ToolResult holds the result of a tool execution.
pub const ToolResult = struct {
    tool_call_id: []const u8,
    content: []const u8,
};

const std = @import("std");

test "Message creation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const content = try allocator.dupe(u8, "Hello, world!");
    defer allocator.free(content);

    const msg = Message{
        .role = .user,
        .content = content,
        .timestamp = "2026-04-07T00:00:00Z",
    };

    try std.testing.expectEqual(Message.Role.user, msg.role);
    try std.testing.expectEqualStrings("Hello, world!", msg.content);
}

test "ToolCall status tracking" {
    const tc = ToolCall{
        .id = "call-1",
        .tool_name = "read_file",
        .input = "{\"path\": \"main.zig\"}",
        .output = "{}",
        .status = .success,
        .duration_ms = 42,
    };

    try std.testing.expectEqual(ToolCall.Status.success, tc.status);
    try std.testing.expectEqual(@as(u64, 42), tc.duration_ms);
}
