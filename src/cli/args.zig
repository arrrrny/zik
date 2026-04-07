const std = @import("std");

/// Parsed CLI arguments.
pub const CliArgs = struct {
    /// Command to run: .repl, .prompt, or .shorthand
    command: Command = .repl,
    /// Prompt message (for .prompt and .shorthand)
    prompt_text: ?[]const u8 = null,
    /// Model override
    model: ?[]const u8 = null,
    /// Permission mode override
    permission_mode: ?PermissionMode = null,
    /// Output format
    output_format: OutputFormat = .text,
    /// Session to resume
    resume_session: ?[]const u8 = null,

    pub const Command = enum { repl, prompt, shorthand, help, version };
    pub const PermissionMode = enum { read_only, workspace_write, danger_full_access };
    pub const OutputFormat = enum { text, json };

    /// Parse command-line arguments.
    /// Caller owns the allocator; returned strings are borrowed from args.
    pub fn parse(allocator: std.mem.Allocator, args: [][:0]u8) !CliArgs {
        _ = allocator; // unused for now — borrowing from args
        var result = CliArgs{};

        var i: usize = 1; // skip argv[0] (program name)
        while (i < args.len) : (i += 1) {
            const arg: []const u8 = args[i];

            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                result.command = .help;
                return result;
            }
            if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
                result.command = .version;
                return result;
            }
            if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
                i += 1;
                if (i < args.len) {
                    result.model = args[i];
                }
                continue;
            }
            if (std.mem.eql(u8, arg, "--permission-mode")) {
                i += 1;
                if (i < args.len) {
                    result.permission_mode = permissionModeFromStr(args[i]);
                }
                continue;
            }
            if (std.mem.eql(u8, arg, "--output-format")) {
                i += 1;
                if (i < args.len) {
                    if (std.mem.eql(u8, args[i], "json")) {
                        result.output_format = .json;
                    }
                }
                continue;
            }
            if (std.mem.eql(u8, arg, "--resume")) {
                i += 1;
                if (i < args.len) {
                    result.resume_session = args[i];
                }
                continue;
            }
            if (std.mem.eql(u8, arg, "prompt")) {
                result.command = .prompt;
                // Next arg is the prompt text
                i += 1;
                if (i < args.len) {
                    result.prompt_text = args[i];
                }
                continue;
            }

            // Unknown flag — treat as shorthand prompt
            if (arg.len > 0 and arg[0] != '-') {
                result.command = .shorthand;
                result.prompt_text = arg;
            }
        }

        return result;
    }
};

pub fn permissionModeFromStr(s: []const u8) ?CliArgs.PermissionMode {
    if (std.mem.eql(u8, s, "read-only")) return .read_only;
    if (std.mem.eql(u8, s, "workspace-write")) return .workspace_write;
    if (std.mem.eql(u8, s, "danger-full-access")) return .danger_full_access;
    return null;
}

const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "CliArgs: no args = repl" {
    const args = &[_][]const u8{"claw"};
    const parsed = try CliArgs.parse(std.testing.allocator, args);
    try expectEqual(CliArgs.Command.repl, parsed.command);
}

test "CliArgs: prompt command" {
    const args = &[_][]const u8{ "claw", "prompt", "hello world" };
    const parsed = try CliArgs.parse(std.testing.allocator, args);
    try expectEqual(CliArgs.Command.prompt, parsed.command);
    try expectEqualStrings("hello world", parsed.prompt_text.?);
}

test "CliArgs: shorthand prompt" {
    const args = &[_][]const u8{ "claw", "explain this code" };
    const parsed = try CliArgs.parse(std.testing.allocator, args);
    try expectEqual(CliArgs.Command.shorthand, parsed.command);
    try expectEqualStrings("explain this code", parsed.prompt_text.?);
}

test "CliArgs: --model flag" {
    const args = &[_][]const u8{ "claw", "--model", "opus" };
    const parsed = try CliArgs.parse(std.testing.allocator, args);
    try expectEqualStrings("opus", parsed.model.?);
}

test "CliArgs: --output-format json" {
    const args = &[_][]const u8{ "claw", "--output-format", "json" };
    const parsed = try CliArgs.parse(std.testing.allocator, args);
    try expectEqual(CliArgs.OutputFormat.json, parsed.output_format);
}

test "CliArgs: --resume latest" {
    const args = &[_][]const u8{ "claw", "--resume", "latest" };
    const parsed = try CliArgs.parse(std.testing.allocator, args);
    try expectEqualStrings("latest", parsed.resume_session.?);
}

test "CliArgs: --permission-mode" {
    const args = &[_][]const u8{ "claw", "--permission-mode", "read-only" };
    const parsed = try CliArgs.parse(std.testing.allocator, args);
    try expectEqual(CliArgs.PermissionMode.read_only, parsed.permission_mode.?);
}
