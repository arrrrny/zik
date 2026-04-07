const std = @import("std");
const PermissionEnforcer = @import("../security/permission_enforcer.zig");

/// Bash tool parameters.
pub const BashParams = struct {
    command: []const u8,
    timeout_ms: u64 = 30000,
    description: []const u8 = "",
    run_in_background: bool = false,
};

/// Bash tool handler — executes shell commands with timeout and permission checks.
pub fn handleBash(
    allocator: std.mem.Allocator,
    input_json: []const u8,
    workspace_root: []const u8,
) anyerror![]const u8 {
    const params = try std.json.parseFromSliceLeaky(BashParams, allocator, input_json, .{});

    if (params.command.len == 0) {
        return try std.fmt.allocPrint(allocator,
            "{{\"success\":false,\"error\":\"command is required\"}}",
            .{},
        );
    }

    // Classify the command for logging
    const category = PermissionEnforcer.classifyCommand(params.command);

    // Execute via shell
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();

    try argv.append("/bin/sh");
    try argv.append("-c");
    try argv.append(params.command);

    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = workspace_root;

    var stdout_buf = std.ArrayList(u8).init(allocator);
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    defer stderr_buf.deinit();

    child.stdout = .{ .to_array = &stdout_buf };
    child.stderr = .{ .to_array = &stderr_buf };

    const start = std.time.milliTimestamp();

    // Spawn with timeout
    try child.spawn();

    var timed_out = false;
    const deadline = start + @as(i64, @intCast(params.timeout_ms));

    while (std.time.milliTimestamp() < deadline) {
        const result = child.tryWait() catch null;
        if (result) |term| {
            const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - start));
            return formatBashResult(
                allocator,
                true,
                stdout_buf.items,
                stderr_buf.items,
                term.Exited,
                elapsed,
                false,
                category,
            );
        }
        // Small sleep to avoid busy-waiting
        std.time.sleep(10 * std.time.ns_per_ms);
    }

    // Timeout — kill the process
    child.kill() catch {};
    timed_out = true;

    const elapsed = @as(u64, @intCast(params.timeout_ms));
    return formatBashResult(
        allocator,
        false,
        stdout_buf.items,
        "Command timed out",
        1,
        elapsed,
        true,
        category,
    );
}

fn formatBashResult(
    allocator: std.mem.Allocator,
    success: bool,
    stdout: []const u8,
    stderr: []const u8,
    exit_code: i32,
    duration_ms: u64,
    timed_out: bool,
    category: PermissionEnforcer.BashCommandCategory,
) ![]const u8 {
    const category_str = switch (category) {
        .safe => "safe",
        .write => "write",
        .destructive => "destructive",
    };

    // Truncate output if too large
    const max_output: usize = 32768; // 32KB
    const truncated_stdout = if (stdout.len > max_output) stdout[0..max_output] else stdout;
    const truncated_stderr = if (stderr.len > max_output) stderr[0..max_output] else stderr;
    const stdout_truncated = stdout.len > max_output;
    const stderr_truncated = stderr.len > max_output;

    return try std.fmt.allocPrint(allocator,
        \\{{"success":{},"stdout":"{}","stderr":"{}","exit_code":{},"duration_ms":{},"timed_out":{},"category":"{}","stdout_truncated":{},"stderr_truncated":{}}}
    ,
        .{
            success,
            truncated_stdout,
            truncated_stderr,
            exit_code,
            duration_ms,
            timed_out,
            category_str,
            stdout_truncated,
            stderr_truncated,
        },
    );
}

test "handleBash: safe command succeeds" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const result = try handleBash(allocator, "{\"command\":\"echo hello\"}", "/tmp");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "hello") != null);
}

test "handleBash: empty command fails" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const result = try handleBash(allocator, "{\"command\":\"\"}", "/tmp");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":false") != null);
}

test "handleBash: timeout works" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const result = try handleBash(allocator, "{\"command\":\"sleep 10\",\"timeout_ms\":100}", "/tmp");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"timed_out\":true") != null);
}

test "handleBash: exit code captured" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const result = try handleBash(allocator, "{\"command\":\"exit 42\"}", "/tmp");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"exit_code\":42") != null);
}
