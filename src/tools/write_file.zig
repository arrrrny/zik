const std = @import("std");
const file_ops = @import("../utils/file_ops.zig");

/// Write file tool handler.
pub fn handleWriteFile(allocator: std.mem.Allocator, input_json: []const u8, workspace_root: []const u8) anyerror![]const u8 {
    const params = try std.json.parseFromSliceLeaky(WriteParams, allocator, input_json, .{});

    if (params.path.len == 0) {
        return try std.fmt.allocPrint(allocator,
            "{{\"success\":false,\"error\":\"path is required\"}}",
            .{},
        );
    }

    const full_path = try std.fs.path.join(allocator, &.{ workspace_root, params.path });
    defer allocator.free(full_path);

    // Validate workspace boundary
    const validated = file_ops.validateWorkspacePath(allocator, full_path, workspace_root) catch |err| {
        return try std.fmt.allocPrint(allocator,
            "{{\"success\":false,\"error\":\"{}\"}}",
            .{err},
        );
    };
    defer allocator.free(validated);

    // Check size limit
    if (params.content.len > file_ops.MAX_WRITE_SIZE) {
        return try std.fmt.allocPrint(allocator,
            "{{\"success\":false,\"error\":\"FileTooLarge\",\"max_size\":{}}}",
            .{file_ops.MAX_WRITE_SIZE},
        );
    }

    // Create parent directories if needed
    const last_sep = std.mem.lastIndexOf(u8, params.path, "/");
    if (last_sep) |sep| {
        const parent = params.path[0..sep];
        const parent_full = try std.fs.path.join(allocator, &.{ workspace_root, parent });
        defer allocator.free(parent_full);
        std.fs.cwd().makePath(parent_full) catch {};
    }

    // Write the file
    const file = std.fs.cwd().createFile(validated, .{ .truncate = true }) catch |err| {
        return try std.fmt.allocPrint(allocator,
            "{{\"success\":false,\"error\":\"{}\"}}",
            .{err},
        );
    };
    defer file.close();

    try file.writeAll(params.content);

    const operation = "created"; // TODO: detect if file existed before

    return try std.fmt.allocPrint(allocator,
        "{{\"success\":true,\"path\":\"{s}\",\"bytes_written\":{},\"operation\":\"{s}\"}}",
        .{ params.path, params.content.len, operation },
    );
}

/// Edit file tool handler (line-range based editing).
pub fn handleEditFile(allocator: std.mem.Allocator, input_json: []const u8, workspace_root: []const u8) anyerror![]const u8 {
    const params = try std.json.parseFromSliceLeaky(EditParams, allocator, input_json, .{});

    const full_path = try std.fs.path.join(allocator, &.{ workspace_root, params.path });
    defer allocator.free(full_path);

    const validated = file_ops.validateWorkspacePath(allocator, full_path, workspace_root) catch |err| {
        return try std.fmt.allocPrint(allocator,
            "{{\"success\":false,\"error\":\"{}\"}}",
            .{err},
        );
    };
    defer allocator.free(validated);

    // Read existing content
    const existing = file_ops.readFileSafely(allocator, validated, file_ops.MAX_READ_SIZE) catch |err| {
        return try std.fmt.allocPrint(allocator,
            "{{\"success\":false,\"error\":\"{}\"}}",
            .{err},
        );
    };
    defer allocator.free(existing.content);

    // Apply edit — simple find/replace for MVP
    var new_content = std.ArrayList(u8).init(allocator);
    defer new_content.deinit();

    if (params.old_str.len > 0 and params.new_str.len > 0) {
        // Find and replace
        if (std.mem.indexOf(u8, existing.content, params.old_str)) |idx| {
            try new_content.appendSlice(allocator, existing.content[0..idx]);
            try new_content.appendSlice(allocator, params.new_str);
            try new_content.appendSlice(allocator, existing.content[idx + params.old_str.len ..]);
        } else {
            return try std.fmt.allocPrint(allocator,
                "{{\"success\":false,\"error\":\"old_str not found in file\"}}",
                .{},
            );
        }
    } else {
        return try std.fmt.allocPrint(allocator,
            "{{\"success\":false,\"error\":\"old_str and new_str are required\"}}",
            .{},
        );
    }

    // Write back
    const file = std.fs.cwd().createFile(validated, .{ .truncate = true }) catch |err| {
        return try std.fmt.allocPrint(allocator,
            "{{\"success\":false,\"error\":\"{}\"}}",
            .{err},
        );
    };
    defer file.close();

    try file.writeAll(new_content.items);

    return try std.fmt.allocPrint(allocator,
        "{{\"success\":true,\"path\":\"{s}\",\"bytes_written\":{}}}",
        .{ params.path, new_content.items.len },
    );
}

const WriteParams = struct {
    path: []const u8,
    content: []const u8,
};

const EditParams = struct {
    path: []const u8,
    old_str: []const u8,
    new_str: []const u8,
    line_number: ?usize = null,
};

test "handleWriteFile: writes file within workspace" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Use a temp dir within the current workspace
    const workspace = "/Users/arrrrny/Developer/claw-zig";

    const result = try handleWriteFile(
        allocator,
        "{\"path\":\".claw/test_write.txt\",\"content\":\"hello from zig\"}",
        workspace,
    );
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"bytes_written\":14") != null);

    // Clean up
    std.fs.cwd().deleteFile(".claw/test_write.txt") catch {};
}

test "handleWriteFile: rejects empty path" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const result = try handleWriteFile(allocator, "{\"path\":\"\",\"content\":\"test\"}", "/tmp");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":false") != null);
}
