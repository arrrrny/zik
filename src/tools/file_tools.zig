const std = @import("std");
const file_ops = @import("../utils/file_ops.zig");

/// Read file tool handler.
pub fn handleReadFile(allocator: std.mem.Allocator, input_json: []const u8, workspace_root: []const u8) anyerror![]const u8 {
    const params = try std.json.parseFromSliceLeaky(Params, allocator, input_json, .{});
    const full_path = try std.fs.path.join(allocator, &.{ workspace_root, params.path });
    defer allocator.free(full_path);

    const validated = file_ops.validateWorkspacePath(allocator, full_path, workspace_root) catch |err| {
        return try std.fmt.allocPrint(allocator, "{{\"success\":false,\"error\":\"{}\"}}", .{err});
    };
    defer allocator.free(validated);

    const result = file_ops.readFileSafely(allocator, validated, file_ops.MAX_READ_SIZE) catch |err| {
        return try std.fmt.allocPrint(allocator, "{{\"success\":false,\"error\":\"{}\"}}", .{err});
    };
    defer allocator.free(result.content);

    // Count lines
    var line_count: usize = 0;
    for (result.content) |b| { if (b == '\n') line_count += 1; }
    if (result.content.len > 0) line_count += 1;

    // Build response
    return try std.fmt.allocPrint(allocator,
        "{{\"success\":true,\"path\":\"{s}\",\"total_lines\":{},\"truncated\":{},\"content\":\"TODO:escaped\"}}",
        .{ params.path, line_count, result.truncated },
    );
}

const Params = struct {
    path: []const u8,
    offset: usize = 0,
    limit: usize = 2000,
};

/// Grep search tool handler.
pub fn handleGrepSearch(allocator: std.mem.Allocator, input_json: []const u8, workspace_root: []const u8) anyerror![]const u8 {
    const params = try std.json.parseFromSliceLeaky(GrepParams, allocator, input_json, .{});

    // Build grep command args
    const search_path = if (params.path.len > 0) params.path else workspace_root;

    // Execute grep via subprocess
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var argv = std.ArrayList([]const u8).init(aa);
    try argv.append("grep");
    try argv.append("-r");
    try argv.append("-n");
    try argv.append("-I"); // skip binary
    if (params.case_sensitive) {
        // default is case sensitive
    } else {
        try argv.append("-i");
    }
    try argv.append(params.pattern);
    try argv.append(search_path);

    var child = std.process.Child.init(argv.items, allocator);
    var stdout_buf = std.ArrayList(u8).init(allocator);
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    defer stderr_buf.deinit();

    child.stdout = .{ .to_array = &stdout_buf };
    child.stderr = .{ .to_array = &stderr_buf };

    const term = try child.spawnAndWait();

    // Exit code 1 = no matches (not an error), 2 = actual error
    if (term.Exited != 0 and term.Exited != 1) {
        return try std.fmt.allocPrint(allocator,
            "{{\"success\":false,\"error\":\"grep failed: {s}\"}}",
            .{stderr_buf.items},
        );
    }

    // Parse output into match lines
    var match_count: usize = 0;
    var lines = std.mem.splitSequence(u8, stdout_buf.items, "\n");
    while (lines.next()) |line| {
        if (line.len > 0) match_count += 1;
    }

    return try std.fmt.allocPrint(allocator,
        "{{\"success\":true,\"matches\":{},\"output\":\"TODO:parsed_matches\"}}",
        .{match_count},
    );
}

const GrepParams = struct {
    pattern: []const u8,
    path: []const u8 = "",
    include: []const u8 = "",
    exclude: []const u8 = "",
    case_sensitive: bool = true,
    max_results: usize = 100,
};

/// Glob search tool handler.
pub fn handleGlobSearch(allocator: std.mem.Allocator, input_json: []const u8, workspace_root: []const u8) anyerror![]const u8 {
    const params = try std.json.parseFromSliceLeaky(GlobParams, allocator, input_json, .{});

    // Walk directory and match glob pattern
    var matched = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (matched.items) |m| allocator.free(m);
        matched.deinit();
    }

    try walkDir(allocator, workspace_root, workspace_root, params.pattern, &matched);

    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    try buf.appendSlice("{\"success\":true,\"files\":[");
    for (matched.items, 0..) |f, i| {
        if (i > 0) try buf.appendSlice(",");
        try buf.writer().print("\"{s}\"", .{f});
    }
    try buf.writer().print("],\"count\":{}}", .{matched.items.len});

    for (matched.items) |m| allocator.free(m);
    matched.deinit();

    return buf.toOwnedSlice();
}

const GlobParams = struct {
    pattern: []const u8,
    path: []const u8 = "",
};

fn walkDir(
    allocator: std.mem.Allocator,
    root: []const u8,
    dir_path: []const u8,
    pattern: []const u8,
    matched: *std.ArrayList([]const u8),
) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const full = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(full);

        if (entry.kind == .directory) {
            // Skip hidden directories
            if (entry.name.len > 0 and entry.name[0] == '.') continue;
            try walkDir(allocator, root, full, pattern, matched);
        } else if (entry.kind == .file) {
            if (matchGlob(pattern, entry.name)) {
                // Store relative path
                const rel = try std.fs.path.relative(allocator, root, full);
                defer allocator.free(rel);
                try matched.append(try allocator.dupe(u8, rel));
            }
        }
    }
}

/// Simple glob matcher — supports * and ** patterns.
fn matchGlob(pattern: []const u8, name: []const u8) bool {
    // Handle **/*.ext patterns
    if (std.mem.endsWith(u8, pattern, "/*")) {
        // **/*.ext — match the extension part
        const ext_pattern = pattern["**/".len..];
        return matchSimpleGlob(ext_pattern, name);
    }
    return matchSimpleGlob(pattern, name);
}

fn matchSimpleGlob(pattern: []const u8, name: []const u8) bool {
    if (std.mem.indexOf(u8, pattern, "*")) |star| {
        const prefix = pattern[0..star];
        const suffix = pattern[star + 1 ..];
        if (prefix.len > 0 and !std.mem.startsWith(u8, name, prefix)) return false;
        if (suffix.len > 0 and !std.mem.endsWith(u8, name, suffix)) return false;
        return true;
    }
    return std.mem.eql(u8, pattern, name);
}

test "matchGlob: extension match" {
    try std.testing.expect(matchGlob("*.zig", "main.zig"));
    try std.testing.expect(!matchGlob("*.zig", "main.rs"));
}

test "matchGlob: exact match" {
    try std.testing.expect(matchGlob("build.zig", "build.zig"));
    try std.testing.expect(!matchGlob("build.zig", "other.zig"));
}

test "matchGlob: prefix match" {
    try std.testing.expect(matchGlob("test_*", "test_utils.zig"));
    try std.testing.expect(!matchGlob("test_*", "main.zig"));
}

test "handleGlobSearch: finds files" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const result = try handleGlobSearch(allocator, "{\"pattern\":\"*.zig\"}", "/Users/arrrrny/Developer/claw-zig");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"build.zig\"") != null);
}

test "handleGrepSearch: basic search" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const result = try handleGrepSearch(allocator, "{\"pattern\":\"fn main\"}", "/Users/arrrrny/Developer/claw-zig");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":true") != null);
}
