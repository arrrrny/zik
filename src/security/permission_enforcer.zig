const std = @import("std");
const errors = @import("../errors.zig").ClawError;

/// Permission mode for tool access control.
pub const PermissionMode = enum {
    read_only,
    workspace_write,
    danger_full_access,
};

/// PermissionCheckResult indicates whether an operation is allowed.
pub const PermissionCheckResult = struct {
    allowed: bool,
    requires_prompt: bool,
    reason: []const u8,
};

/// BashCommandCategory classifies a command by its risk level.
pub const BashCommandCategory = enum {
    safe,         // read-only: ls, cat, grep, etc.
    write,        // modifies files: echo >, touch, mkdir
    destructive,  // potentially dangerous: rm -rf, sudo, git reset
};

/// PermissionEnforcer controls which operations are allowed based on the current permission mode.
pub const PermissionEnforcer = struct {
    mode: PermissionMode,

    pub fn checkTool(
        self: PermissionEnforcer,
        tool_name: []const u8,
        required_permission: PermissionMode,
    ) PermissionCheckResult {
        if (mode == .danger_full_access) {
            return .{ .allowed = true, .requires_prompt = false, reason = "full access" };
        }

        if (mode == .workspace_write and required_permission == .read_only) {
            return .{ .allowed = true, .requires_prompt = false, reason = "read-only tool in write mode" };
        }

        if (mode == .workspace_write and required_permission == .workspace_write) {
            return .{ .allowed = true, .requires_prompt = false, reason = "write allowed in workspace" };
        }

        if (mode == .read_only and required_permission == .read_only) {
            return .{ .allowed = true, .requires_prompt = false, reason = "read-only tool in read-only mode" };
        }

        // Permission insufficient — check if we should prompt
        if (mode == .workspace_write and required_permission == .danger_full_access) {
            return .{ .allowed = false, .requires_prompt = true, reason = "dangerous operation requires approval" };
        }

        if (mode == .read_only and required_permission != .read_only) {
            return .{ .allowed = false, .requires_prompt = false, reason = "operation denied in read-only mode" };
        }

        return .{ .allowed = false, .requires_prompt = false, reason = "permission denied" };
    }

    /// Check if a bash command is allowed in the current mode.
    pub fn checkBash(
        self: PermissionEnforcer,
        command: []const u8,
    ) PermissionCheckResult {
        const category = classifyCommand(command);

        return switch (self.mode) {
            .danger_full_access => .{ .allowed = true, .requires_prompt = false, reason = "full access" },
            .workspace_write => switch (category) {
                .safe => .{ .allowed = true, .requires_prompt = false, reason = "safe command" },
                .write => .{ .allowed = false, .requires_prompt = true, reason = "write command requires approval" },
                .destructive => .{ .allowed = false, .requires_prompt = true, reason = "destructive command requires approval" },
            },
            .read_only => switch (category) {
                .safe => .{ .allowed = true, .requires_prompt = false, reason = "safe command" },
                .write, .destructive => .{ .allowed = false, .requires_prompt = false, reason = "write/destructive commands denied in read-only mode" },
            },
        };
    }

    /// Classify a bash command by risk level.
    pub fn classifyCommand(command: []const u8) BashCommandCategory {
        // Check for obviously dangerous patterns
        if (std.mem.indexOf(u8, command, "rm -rf") != null) return .destructive;
        if (std.mem.indexOf(u8, command, "rm -r ") != null) return .destructive;
        if (std.mem.indexOf(u8, command, "sudo ") != null) return .destructive;
        if (std.mem.indexOf(u8, command, "git reset --hard") != null) return .destructive;
        if (std.mem.indexOf(u8, command, "dd ") != null) return .destructive;
        if (std.mem.indexOf(u8, command, "mkfs") != null) return .destructive;

        // Check for write patterns
        if (std.mem.indexOf(u8, command, "> ") != null) return .write;
        if (std.mem.indexOf(u8, command, ">> ") != null) return .write;
        if (std.mem.indexOf(u8, command, "touch ") != null) return .write;
        if (std.mem.indexOf(u8, command, "mkdir ") != null) return .write;
        if (std.mem.indexOf(u8, command, "mv ") != null) return .write;
        if (std.mem.indexOf(u8, command, "cp ") != null) return .write;

        // Default: safe
        return .safe;
    }
};

const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "PermissionEnforcer: danger-full-access allows everything" {
    const enforcer = PermissionEnforcer{ .mode = .danger_full_access };

    const read_result = enforcer.checkTool("read_file", .read_only);
    try expectEqual(true, read_result.allowed);

    const write_result = enforcer.checkTool("write_file", .workspace_write);
    try expectEqual(true, write_result.allowed);
}

test "PermissionEnforcer: read-only blocks writes" {
    const enforcer = PermissionEnforcer{ .mode = .read_only };

    const result = enforcer.checkTool("write_file", .workspace_write);
    try expectEqual(false, result.allowed);
    try expectEqual(false, result.requires_prompt); // denied outright, not prompted
}

test "PermissionEnforcer: read-only allows reads" {
    const enforcer = PermissionEnforcer{ .mode = .read_only };

    const result = enforcer.checkTool("read_file", .read_only);
    try expectEqual(true, result.allowed);
}

test "Bash classification: destructive" {
    try expectEqual(BashCommandCategory.destructive, PermissionEnforcer.classifyCommand("rm -rf /"));
    try expectEqual(BashCommandCategory.destructive, PermissionEnforcer.classifyCommand("sudo apt install"));
    try expectEqual(BashCommandCategory.destructive, PermissionEnforcer.classifyCommand("git reset --hard HEAD"));
}

test "Bash classification: write" {
    try expectEqual(BashCommandCategory.write, PermissionEnforcer.classifyCommand("echo hello > file.txt"));
    try expectEqual(BashCommandCategory.write, PermissionEnforcer.classifyCommand("mkdir new_dir"));
    try expectEqual(BashCommandCategory.write, PermissionEnforcer.classifyCommand("touch new_file.txt"));
}

test "Bash classification: safe" {
    try expectEqual(BashCommandCategory.safe, PermissionEnforcer.classifyCommand("ls -la"));
    try expectEqual(BashCommandCategory.safe, PermissionEnforcer.classifyCommand("cat file.txt"));
    try expectEqual(BashCommandCategory.safe, PermissionEnforcer.classifyCommand("grep -r pattern ."));
}

test "Bash check: read-only blocks write commands" {
    const enforcer = PermissionEnforcer{ .mode = .read_only };
    const result = enforcer.checkBash("rm -rf /");
    try expectEqual(false, result.allowed);
}

test "Bash check: workspace-write prompts on destructive" {
    const enforcer = PermissionEnforcer{ .mode = .workspace_write };
    const result = enforcer.checkBash("rm -rf /");
    try expectEqual(false, result.allowed);
    try expectEqual(true, result.requires_prompt);
}
