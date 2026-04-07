/// Shared error types for the claw CLI.
pub const ClawError = error{
    /// File not found
    FileNotFound,
    /// File is binary (not text)
    BinaryFile,
    /// File exceeds size limit
    FileTooLarge,
    /// Path is outside workspace boundary
    PathOutsideWorkspace,
    /// Symlink target escapes workspace
    SymlinkEscape,
    /// Operation denied by permission mode
    PermissionDenied,
    /// API authentication failed
    AuthFailed,
    /// API rate limit exceeded
    RateLimitExceeded,
    /// API request failed
    ApiRequestFailed,
    /// Invalid response from API
    InvalidResponse,
    /// Session not found
    SessionNotFound,
    /// Configuration parse error
    ConfigParseError,
    /// Tool execution error
    ToolError,
    /// Process execution timeout
    ProcessTimeout,
    /// Process execution failed
    ProcessError,
};

/// Format a ClawError as a user-friendly message.
pub fn formatError(err: ClawError) []const u8 {
    return switch (err) {
        error.FileNotFound => "File not found",
        error.BinaryFile => "File appears to be binary and cannot be displayed as text",
        error.FileTooLarge => "File exceeds maximum size limit",
        error.PathOutsideWorkspace => "Access denied: path is outside the workspace",
        error.SymlinkEscape => "Access denied: symlink target is outside the workspace",
        error.PermissionDenied => "Operation denied by current permission mode",
        error.AuthFailed => "Authentication failed: check your API key configuration",
        error.RateLimitExceeded => "API rate limit exceeded — please wait and try again",
        error.ApiRequestFailed => "API request failed — check your network connection",
        error.InvalidResponse => "Invalid response from API",
        error.SessionNotFound => "Session not found",
        error.ConfigParseError => "Failed to parse configuration file",
        error.ToolError => "Tool execution failed",
        error.ProcessTimeout => "Command execution timed out",
        error.ProcessError => "Command execution failed",
    };
}

const std = @import("std");

test "ClawError formatting" {
    try std.testing.expectEqualStrings(
        "File not found",
        formatError(error.FileNotFound),
    );
    try std.testing.expectEqualStrings(
        "Operation denied by current permission mode",
        formatError(error.PermissionDenied),
    );
}
