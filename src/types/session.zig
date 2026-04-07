/// Session represents a persistent conversation context across CLI invocations.
pub const Session = struct {
    /// Unique session identifier
    id: []const u8,
    /// Session creation timestamp (ISO 8601)
    created_at: []const u8,
    /// Last modification timestamp (ISO 8601)
    updated_at: []const u8,
    /// Conversation history
    messages: []Message,
    /// Active model identifier
    current_model: []const u8,
    /// Current permission setting
    permission_mode: PermissionMode,
    /// Workspace root directory
    workspace_root: []const u8,
    /// Cumulative token counts
    token_usage: TokenUsage,
    /// Cumulative cost estimate (in USD cents)
    cost: u64,

    pub const Message = struct {
        role: []const u8,
        content: []const u8,
        timestamp: []const u8,
        tokens_used: ?u32 = null,
    };

    pub const TokenUsage = struct {
        input: u64 = 0,
        output: u64 = 0,
        cache_read: u64 = 0,
        cache_creation: u64 = 0,

        pub fn total(self: TokenUsage) u64 {
            return self.input + self.output + self.cache_read + self.cache_creation;
        }
    };

    pub const PermissionMode = enum {
        read_only,
        workspace_write,
        danger_full_access,
    };
};

const std = @import("std");

test "Session token usage totals" {
    const usage = Session.TokenUsage{
        .input = 1000,
        .output = 500,
        .cache_read = 200,
        .cache_creation = 100,
    };

    try std.testing.expectEqual(@as(u64, 1800), usage.total());
}
