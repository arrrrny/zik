/// Tool represents a capability that the AI assistant can invoke.
pub const Tool = struct {
    /// Unique tool name (snake_case)
    name: []const u8,
    /// Human-readable description
    description: []const u8,
    /// JSON Schema defining accepted input parameters
    input_schema: []const u8,
    /// Minimum permission level needed
    required_permission: PermissionMode,

    pub const PermissionMode = enum {
        read_only,
        workspace_write,
        danger_full_access,
    };
};

/// ToolResult represents the outcome of a tool execution.
pub const ToolResult = struct {
    /// Whether the tool executed successfully
    success: bool,
    /// Tool output (JSON string)
    output: []const u8,
    /// Error message (if success is false)
    err: ?[]const u8 = null,
    /// Execution time in milliseconds
    duration_ms: u64 = 0,
    /// Permission check result
    permission_check: PermissionCheckResult = .{
        .required = .read_only,
        .granted = true,
    },

    pub const PermissionMode = enum {
        read_only,
        workspace_write,
        danger_full_access,
    };

    pub const PermissionCheckResult = struct {
        required: PermissionMode,
        granted: bool,
    };
};

const std = @import("std");

test "Tool definition" {
    const read_file = Tool{
        .name = "read_file",
        .description = "Read file contents with chunking support",
        .input_schema = "{\"type\": \"object\", \"properties\": {\"path\": {\"type\": \"string\"}}, \"required\": [\"path\"]}",
        .required_permission = .read_only,
    };

    try std.testing.expectEqualStrings("read_file", read_file.name);
    try std.testing.expectEqual(Tool.PermissionMode.read_only, read_file.required_permission);
}

test "ToolResult success" {
    const result = ToolResult{
        .success = true,
        .output = "{\"content\": \"file contents\"}",
    };

    try std.testing.expect(result.success);
    try std.testing.expect(result.err == null);
}
