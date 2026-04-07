const std = @import("std");
const file_ops = @import("../utils/file_ops.zig");
const errors = @import("../errors.zig");

/// Read file tool — reads file contents with chunking, binary detection, and size limits.
pub const ReadFileTool = struct {
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    max_read_size: usize = file_ops.MAX_READ_SIZE,
    default_limit: usize = 2000, // lines

    const Self = @This();

    /// Execute the read_file tool.
    /// Input is a JSON string: {"path": "src/main.zig", "offset": 0, "limit": 2000}
    pub fn run(self: *const Self, input_json: []const u8) ![]const u8 {
        const params = try std.json.parseFromSliceLeaky(Params, self.allocator, input_json, .{});

        // Resolve path relative to workspace
        const full_path = try std.fs.path.join(self.allocator, &.{ self.workspace_root, params.path });
        defer self.allocator.free(full_path);

        // Validate workspace boundary
        const validated = file_ops.validateWorkspacePath(
            self.allocator,
            full_path,
            self.workspace_root,
        ) catch |err| {
            return self.errorResponse(@errorName(err));
        };
        defer self.allocator.free(validated);

        // Read the file
        const result = file_ops.readFileSafely(self.allocator, validated, self.max_read_size) catch |err| {
            return self.errorResponse(@errorName(err));
        };
        defer self.allocator.free(result.content);

        // Count lines
        var line_count: usize = 0;
        for (result.content) |b| {
            if (b == '\n') line_count += 1;
        }
        if (result.content.len > 0) line_count += 1;

        // Apply offset/limit
        const start_line = params.offset;
        const end_line = @min(start_line + params.limit, line_count);

        // Find byte ranges for the requested lines
        var current_line: usize = 0;
        var start_byte: usize = 0;
        var end_byte: usize = 0;
        var found_start = false;

        for (result.content, 0..) |b, i| {
            if (current_line == start_line and !found_start) {
                start_byte = i;
                found_start = true;
            }
            if (b == '\n') {
                current_line += 1;
                if (current_line == end_line) {
                    end_byte = i + 1;
                    break;
                }
            }
        }
        if (end_byte == 0) end_byte = result.content.len;

        const sliced = result.content[start_byte..end_byte];
        const lines_read = @min(params.limit, line_count -| start_line);

        // Build JSON response
        var buf: [8192]u8 = undefined;
        var pos: usize = 0;

        inline fn addStr(s: []const u8) void {
            @memcpy(buf[pos..][0..s.len], s);
            pos += s.len;
        }
        _ = addStr;

        // Build response manually
        const prefix = try std.fmt.allocPrint(
            self.allocator,
            "{{\"success\":true,\"path\":\"{s}\",\"total_lines\":{},\"lines_read\":{},\"truncated\":{},\"content\":\"",
            .{ params.path, line_count, lines_read, result.truncated },
        );
        defer self.allocator.free(prefix);

        // We need to escape the content for JSON
        var escaped = std.ArrayList(u8).init(self.allocator);
        defer escaped.deinit(self.allocator);
        try escapeJson(escaped.items, sliced, &escaped);

        const suffix = "\"}";

        const total_len = prefix.len + escaped.items.len + suffix.len;
        const response = try self.allocator.alloc(u8, total_len);
        @memcpy(response[0..prefix.len], prefix);
        @memcpy(response[prefix.len..][0..escaped.items.len], escaped.items);
        @memcpy(response[prefix.len + escaped.items.len..], suffix);

        return response;
    }

    fn escapeJson(src: []const u8, dest: *std.ArrayList(u8)) !void {
        for (src) |b| {
            switch (b) {
                '"' => try dest.appendSlice(dest.allocator, "\\\""),
                '\\' => try dest.appendSlice(dest.allocator, "\\\\"),
                '\n' => try dest.appendSlice(dest.allocator, "\\n"),
                '\r' => try dest.appendSlice(dest.allocator, "\\r"),
                '\t' => try dest.appendSlice(dest.allocator, "\\t"),
                0...31 => {
                    const hex = try std.fmt.allocPrint(dest.allocator, "\\u{:04x}", .{b});
                    try dest.appendSlice(dest.allocator, hex);
                },
                else => try dest.append(dest.allocator, b),
            }
        }
    }

    fn errorResponse(self: *const Self, err_name: []const u8) []const u8 {
        const friendly = errors.formatError(@as(errors.ClawError, @errorFromName(err_name) catch error.ToolError));
        return std.fmt.allocPrint(
            self.allocator,
            "{{\"success\":false,\"error\":\"{s}\",\"error_code\":\"{s}\"}}",
            .{ friendly, err_name },
        ) catch @panic("OOM");
    }

    const Params = struct {
        path: []const u8,
        offset: usize = 0,
        limit: usize = 2000,
    };
};

fn escapeJson(src: []const u8, dest: *std.ArrayList(u8)) !void {
    for (src) |b| {
        switch (b) {
            '"' => try dest.appendSlice(dest.allocator, "\\\""),
            '\\' => try dest.appendSlice(dest.allocator, "\\\\"),
            '\n' => try dest.appendSlice(dest.allocator, "\\n"),
            '\r' => try dest.appendSlice(dest.allocator, "\\r"),
            '\t' => try dest.appendSlice(dest.allocator, "\\t"),
            0...31 => {
                const hex = try std.fmt.allocPrint(dest.allocator, "\\u{:04x}", .{b});
                try dest.appendSlice(dest.allocator, hex);
            },
            else => try dest.append(dest.allocator, b),
        }
    }
}

test "ReadFileTool: error for missing path" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const tool = ReadFileTool{
        .allocator = allocator,
        .workspace_root = "/tmp",
    };

    // Empty path should fail
    const result = tool.run("{}") catch |err| {
        try std.testing.expect(err == error.ToolError);
        return;
    };
    _ = result;
}
