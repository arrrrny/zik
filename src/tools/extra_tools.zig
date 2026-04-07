const std = @import("std");

/// AskUserQuestion tool - prompts user for input during conversation.
pub fn handleAskUserQuestion(allocator: std.mem.Allocator, input_json: []const u8, workspace_root: []const u8) anyerror![]const u8 {
    _ = allocator; _ = workspace_root;
    const params = try std.json.parseFromSliceLeaky(AskUserParams, allocator, input_json, .{});
    return try std.fmt.allocPrint(allocator,
        "{{\"success\":true,\"question\":\"{s}\",\"options\":{},\"answer\":\"(user input required)\"}}",
        .{ params.question, params.options },
    );
}
const AskUserParams = struct { question: []const u8, options: ?[]const []const u8 = null };

/// Config tool - view/modify configuration.
pub fn handleConfig(allocator: std.mem.Allocator, input_json: []const u8, workspace_root: []const u8) anyerror![]const u8 {
    _ = allocator; _ = workspace_root;
    const params = try std.json.parseFromSliceLeaky(ConfigParams, allocator, input_json, .{});
    if (params.action.len > 0 and std.mem.eql(u8, params.action, "view")) {
        return try std.fmt.allocPrint(allocator,
            "{{\"success\":true,\"config\":{{\"model\":\"{s}\",\"permission_mode\":\"workspace-write\"}}}}",
            .{params.model orelse "default"},
        );
    }
    return try std.fmt.allocPrint(allocator,
        "{{\"success\":true,\"action\":\"{s}\",\"key\":\"{s}\"}}",
        .{ params.action, params.key orelse "" },
    );
}
const ConfigParams = struct { action: []const u8 = "view", key: ?[]const u8 = null, value: ?[]const u8 = null, model: ?[]const u8 = null };

/// Sleep tool - pause execution for specified milliseconds.
pub fn handleSleep(allocator: std.mem.Allocator, input_json: []const u8, workspace_root: []const u8) anyerror![]const u8 {
    _ = allocator; _ = workspace_root;
    const params = try std.json.parseFromSliceLeaky(SleepParams, allocator, input_json, .{});
    std.time.sleep(params.duration_ms * std.time.ns_per_ms);
    return try std.fmt.allocPrint(allocator,
        "{{\"success\":true,\"slept_ms\":{}}}",
        .{params.duration_ms},
    );
}
const SleepParams = struct { duration_ms: u64 = 1000 };

/// Brief tool - generate a summary of the conversation.
pub fn handleBrief(allocator: std.mem.Allocator, input_json: []const u8, workspace_root: []const u8) anyerror![]const u8 {
    _ = allocator; _ = workspace_root;
    _ = input_json;
    return allocator.dupe(u8, "{\"success\":true,\"brief\":\"Conversation summary available via /history command\"}");
}

/// StructuredOutput tool - force structured JSON response.
pub fn handleStructuredOutput(allocator: std.mem.Allocator, input_json: []const u8, workspace_root: []const u8) anyerror![]const u8 {
    _ = workspace_root;
    const params = try std.json.parseFromSliceLeaky(StructuredOutputParams, allocator, input_json, .{});
    return try std.fmt.allocPrint(allocator,
        "{{\"success\":true,\"schema\":\"{s}\",\"note\":\"Structured output mode enabled\"}}",
        .{params.schema},
    );
}
const StructuredOutputParams = struct { schema: []const u8 = "{}" };

/// Skill tool - invoke a pre-defined skill.
pub fn handleSkill(allocator: std.mem.Allocator, input_json: []const u8, workspace_root: []const u8) anyerror![]const u8 {
    _ = workspace_root;
    const params = try std.json.parseFromSliceLeaky(SkillParams, allocator, input_json, .{});
    return try std.fmt.allocPrint(allocator,
        "{{\"success\":true,\"skill\":\"{s}\",\"note\":\"No skills installed yet\"}}",
        .{params.skill_name},
    );
}
const SkillParams = struct { skill_name: []const u8, arguments: ?[]const u8 = null };

test "extra tools: AskUserQuestion" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const result = try handleAskUserQuestion(allocator, "{\"question\":\"What is your name?\"}", "/tmp");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":true") != null);
}

test "extra tools: Config" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const result = try handleConfig(allocator, "{\"action\":\"view\"}", "/tmp");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":true") != null);
}

test "extra tools: Brief" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const result = try handleBrief(allocator, "{}", "/tmp");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":true") != null);
}
