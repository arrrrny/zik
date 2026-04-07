const std = @import("std");
const PermissionEnforcer = @import("../security/permission_enforcer.zig");
const file_tools = @import("file_tools.zig");
const write_file = @import("write_file.zig");
const bash_tool = @import("bash.zig");
const todo_write = @import("todo_write.zig");
const web_tools = @import("web_tools.zig");
const extra_tools = @import("extra_tools.zig");

/// Tool definition
pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
    required_permission: PermissionEnforcer.PermissionMode,
    handler: *const fn (allocator: std.mem.Allocator, input: []const u8, workspace_root: []const u8) anyerror![]const u8,
};

/// ToolResult from execution
pub const ToolResult = struct {
    success: bool,
    output: []const u8,
    err: ?[]const u8 = null,
    duration_ms: u64 = 0,
};

/// ToolRegistry maintains the mapping of tool names to implementations.
pub const ToolRegistry = struct {
    allocator: std.mem.Allocator,
    tools: std.StringHashMap(ToolDef),
    enforcer: PermissionEnforcer,
    workspace_root: []const u8,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        mode: PermissionEnforcer.PermissionMode,
        workspace_root: []const u8,
    ) Self {
        return .{
            .allocator = allocator,
            .tools = std.StringHashMap(ToolDef).init(allocator),
            .enforcer = PermissionEnforcer{ .mode = mode },
            .workspace_root = workspace_root,
        };
    }

    pub fn deinit(self: *Self) void {
        self.tools.deinit();
    }

    /// Register a new tool.
    pub fn register(self: *Self, tool: ToolDef) !void {
        try self.tools.put(tool.name, tool);
    }

    /// Unregister a tool by name.
    pub fn unregister(self: *Self, name: []const u8) void {
        _ = self.tools.fetchRemove(name);
    }

    /// Get a tool definition by name.
    pub fn get(self: *const Self, name: []const u8) ?ToolDef {
        return self.tools.get(name);
    }

    /// Execute a tool by name with the given input.
    pub fn execute(self: *Self, name: []const u8, input: []const u8) ToolResult {
        const tool = self.get(name) orelse {
            return .{
                .success = false,
                .output = "",
                .err = "Tool not found",
            };
        };

        // Check permission
        const perm = self.enforcer.checkTool(name, tool.required_permission);
        if (!perm.allowed) {
            return .{
                .success = false,
                .output = "",
                .err = perm.reason,
            };
        }

        // Execute the tool
        const start = std.time.milliTimestamp();
        const output = tool.handler(self.allocator, input, self.workspace_root) catch |err| {
            return .{
                .success = false,
                .output = "",
                .err = @errorName(err),
                .duration_ms = @as(u64, @intCast(std.time.milliTimestamp() - start)),
            };
        };

        return .{
            .success = true,
            .output = output,
            .duration_ms = @as(u64, @intCast(std.time.milliTimestamp() - start)),
        };
    }
};

/// Register all MVP tools into a registry.
pub fn registerAllTools(registry: *ToolRegistry) !void {
    try registry.register(.{
        .name = "read_file",
        .description = "Read file contents with chunking and binary detection",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"offset\":{\"type\":\"integer\"},\"limit\":{\"type\":\"integer\"}},\"required\":[\"path\"]}",
        .required_permission = .read_only,
        .handler = file_tools.handleReadFile,
    });

    try registry.register(.{
        .name = "grep_search",
        .description = "Search file contents using regular expressions",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\"},\"path\":{\"type\":\"string\"},\"case_sensitive\":{\"type\":\"boolean\"}},\"required\":[\"pattern\"]}",
        .required_permission = .read_only,
        .handler = file_tools.handleGrepSearch,
    });

    try registry.register(.{
        .name = "glob_search",
        .description = "Find files by name pattern",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\"},\"path\":{\"type\":\"string\"}},\"required\":[\"pattern\"]}",
        .required_permission = .read_only,
        .handler = file_tools.handleGlobSearch,
    });

    try registry.register(.{
        .name = "write_file",
        .description = "Create or update files within the workspace",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"]}",
        .required_permission = .workspace_write,
        .handler = write_file.handleWriteFile,
    });

    try registry.register(.{
        .name = "edit_file",
        .description = "Edit a file by replacing a string segment",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"old_str\":{\"type\":\"string\"},\"new_str\":{\"type\":\"string\"}},\"required\":[\"path\",\"old_str\",\"new_str\"]}",
        .required_permission = .workspace_write,
        .handler = write_file.handleEditFile,
    });

    try registry.register(.{
        .name = "bash",
        .description = "Execute a shell command in the workspace",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"},\"timeout_ms\":{\"type\":\"integer\"},\"run_in_background\":{\"type\":\"boolean\"}},\"required\":[\"command\"]}",
        .required_permission = .danger_full_access,
        .handler = bash_tool.handleBash,
    });

    try registry.register(.{
        .name = "TodoWrite",
        .description = "Manage a todo list during a conversation",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"todos\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"content\":{\"type\":\"string\"},\"status\":{\"type\":\"string\"},\"priority\":{\"type\":\"string\"}},\"required\":[\"content\",\"status\"]}}},\"required\":[\"todos\"]}",
        .required_permission = .read_only,
        .handler = todo_write.handleTodoWrite,
    });

    try registry.register(.{
        .name = "WebFetch",
        .description = "Fetch content from a URL",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\"},\"max_length\":{\"type\":\"integer\"}},\"required\":[\"url\"]}",
        .required_permission = .read_only,
        .handler = web_tools.handleWebFetch,
    });

    try registry.register(.{
        .name = "WebSearch",
        .description = "Search the web for information",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"},\"max_results\":{\"type\":\"integer\"}},\"required\":[\"query\"]}",
        .required_permission = .read_only,
        .handler = web_tools.handleWebSearch,
    });

    try registry.register(.{
        .name = "AskUserQuestion",
        .description = "Ask the user a clarifying question with optional answer options",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"question\":{\"type\":\"string\"},\"options\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}},\"required\":[\"question\"]}",
        .required_permission = .read_only,
        .handler = extra_tools.handleAskUserQuestion,
    });

    try registry.register(.{
        .name = "Config",
        .description = "View or modify CLI configuration",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\"},\"key\":{\"type\":\"string\"},\"value\":{\"type\":\"string\"}},\"required\":[\"action\"]}",
        .required_permission = .read_only,
        .handler = extra_tools.handleConfig,
    });

    try registry.register(.{
        .name = "Sleep",
        .description = "Pause execution for specified milliseconds",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"duration_ms\":{\"type\":\"integer\"}},\"required\":[]}",
        .required_permission = .read_only,
        .handler = extra_tools.handleSleep,
    });

    try registry.register(.{
        .name = "Brief",
        .description = "Generate a brief summary of the conversation",
        .input_schema = "{\"type\":\"object\",\"properties\":{},\"required\":[]}",
        .required_permission = .read_only,
        .handler = extra_tools.handleBrief,
    });

    try registry.register(.{
        .name = "StructuredOutput",
        .description = "Force structured JSON response according to a schema",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"schema\":{\"type\":\"string\"}},\"required\":[]}",
        .required_permission = .read_only,
        .handler = extra_tools.handleStructuredOutput,
    });

    try registry.register(.{
        .name = "Skill",
        .description = "Invoke a pre-defined skill",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"skill_name\":{\"type\":\"string\"},\"arguments\":{\"type\":\"string\"}},\"required\":[\"skill_name\"]}",
        .required_permission = .read_only,
        .handler = extra_tools.handleSkill,
    });
}

test "ToolRegistry: register and execute file tools" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var registry = ToolRegistry.init(allocator, .read_only, "/Users/arrrrny/Developer/claw-zig");
    defer registry.deinit();

    try registerAllTools(&registry);

    // Test read_file
    const read_result = registry.execute("read_file", "{\"path\":\"build.zig\"}");
    try std.testing.expect(read_result.success);

    // Test grep_search
    const grep_result = registry.execute("grep_search", "{\"pattern\":\"fn build\"}");
    try std.testing.expect(grep_result.success);

    // Test glob_search
    const glob_result = registry.execute("glob_search", "{\"pattern\":\"*.zig\"}");
    try std.testing.expect(glob_result.success);
}

test "ToolRegistry: permission denied for write" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var registry = ToolRegistry.init(allocator, .read_only, "/workspace");
    defer registry.deinit();

    try registry.register(.{
        .name = "write_file",
        .description = "Write a file",
        .input_schema = "{}",
        .required_permission = .workspace_write,
        .handler = file_tools.handleReadFile, // stub
    });

    const result = registry.execute("write_file", "{}");
    try std.testing.expect(!result.success);
}

test "ToolRegistry: unknown tool" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var registry = ToolRegistry.init(allocator, .read_only, "/workspace");
    defer registry.deinit();

    const result = registry.execute("nonexistent", "{}");
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("Tool not found", result.err.?);
}
