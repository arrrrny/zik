/// PermissionMode controls which operations the assistant can perform
/// without explicit user approval.
pub const PermissionMode = enum {
    /// Only read operations allowed; writes and bash with side effects
    /// blocked or require approval
    read_only,
    /// Read + write within workspace boundary allowed; bash still
    /// requires approval for destructive commands
    workspace_write,
    /// All operations allowed without prompts (user accepts risk)
    danger_full_access,

    /// Parse from CLI flag string
    pub fn fromStr(s: []const u8) ?PermissionMode {
        if (std.mem.eql(u8, s, "read-only")) return .read_only;
        if (std.mem.eql(u8, s, "workspace-write")) return .workspace_write;
        if (std.mem.eql(u8, s, "danger-full-access")) return .danger_full_access;
        return null;
    }

    /// Convert to CLI flag string
    pub fn toString(self: PermissionMode) []const u8 {
        return switch (self) {
            .read_only => "read-only",
            .workspace_write => "workspace-write",
            .danger_full_access => "danger-full-access",
        };
    }
};

const std = @import("std");

test "PermissionMode fromStr" {
    try std.testing.expectEqual(PermissionMode.read_only, PermissionMode.fromStr("read-only").?);
    try std.testing.expectEqual(PermissionMode.workspace_write, PermissionMode.fromStr("workspace-write").?);
    try std.testing.expectEqual(PermissionMode.danger_full_access, PermissionMode.fromStr("danger-full-access").?);
    try std.testing.expectEqual(null, PermissionMode.fromStr("invalid"));
}

test "PermissionMode toString" {
    try std.testing.expectEqualStrings("read-only", PermissionMode.read_only.toString());
    try std.testing.expectEqualStrings("workspace-write", PermissionMode.workspace_write.toString());
    try std.testing.expectEqualStrings("danger-full-access", PermissionMode.danger_full_access.toString());
}
