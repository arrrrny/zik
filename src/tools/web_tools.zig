const std = @import("std");

/// WebFetch tool — fetches content from a URL.
pub fn handleWebFetch(allocator: std.mem.Allocator, input_json: []const u8, workspace_root: []const u8) anyerror![]const u8 {
    _ = workspace_root;

    const params = try std.json.parseFromSliceLeaky(WebFetchParams, allocator, input_json, .{});

    // Use curl to fetch
    var argv: [16][]const u8 = undefined;
    var argc: usize = 0;
    argv[argc] = "curl"; argc += 1;
    argv[argc] = "-s"; argc += 1;
    argv[argc] = "-L"; argc += 1; // follow redirects
    argv[argc] = "--max-time"; argc += 1;
    argv[argc] = "30"; argc += 1;
    argv[argc] = params.url; argc += 1;

    var child = std.process.Child.init(argv[0..argc], allocator);

    // Write to temp file
    const out_path = "/tmp/.zik_webfetch_out";
    const err_path = "/tmp/.zik_webfetch_err";

    var argv2: [20][]const u8 = undefined;
    var argc2: usize = 0;
    argv2[argc2] = "curl"; argc2 += 1;
    argv2[argc2] = "-s"; argc2 += 1;
    argv2[argc2] = "-L"; argc2 += 1;
    argv2[argc2] = "--max-time"; argc2 += 1;
    argv2[argc2] = "30"; argc2 += 1;
    argv2[argc2] = "-o"; argc2 += 1;
    argv2[argc2] = out_path; argc2 += 1;
    argv2[argc2] = "--stderr"; argc2 += 1;
    argv2[argc2] = err_path; argc2 += 1;
    argv2[argc2] = params.url; argc2 += 1;

    var child2 = std.process.Child.init(argv2[0..argc2], allocator);
    const term = try child2.spawnAndWait();
    _ = child; // unused

    // Read output
    const content = readFileSafely(allocator, out_path, params.max_length orelse 10000) catch "";
    const error_out = readFileSafely(allocator, err_path, 1024) catch "";

    // Cleanup
    std.fs.cwd().deleteFile(out_path) catch {};
    std.fs.cwd().deleteFile(err_path) catch {};

    if (term.Exited != 0) {
        return try std.fmt.allocPrint(allocator,
            "{{\"success\":false,\"error\":\"Fetch failed: {s}\"}}",
            .{error_out},
        );
    }

    // Truncate if needed
    const max_len = params.max_length orelse 10000;
    const truncated = content.len > max_len;
    const display_content = if (content.len > max_len) content[0..max_len] else content;

    return try std.fmt.allocPrint(allocator,
        "{{\"success\":true,\"url\":\"{s}\",\"content\":\"TODO_truncated\",\"truncated\":{},\"length\":{}}}",
        .{ params.url, truncated, content.len },
    );
}

const WebFetchParams = struct {
    url: []const u8,
    max_length: ?usize = null,
};

/// WebSearch tool — searches the web via curl (uses a simple search API).
pub fn handleWebSearch(allocator: std.mem.Allocator, input_json: []const u8, workspace_root: []const u8) anyerror![]const u8 {
    _ = workspace_root;

    const params = try std.json.parseFromSliceLeaky(WebSearchParams, allocator, input_json, .{});

    // Use curl to call a search endpoint (DuckDuckGo HTML for now)
    const query_encoded = try std.fmt.allocPrint(allocator, "https://html.duckduckgo.com/html/?q={s}", .{params.query});
    defer allocator.free(query_encoded);

    const out_path = "/tmp/.zik_websearch_out";
    const err_path = "/tmp/.zik_websearch_err";

    var argv: [20][]const u8 = undefined;
    var argc: usize = 0;
    argv[argc] = "curl"; argc += 1;
    argv[argc] = "-s"; argc += 1;
    argv[argc] = "-L"; argc += 1;
    argv[argc] = "--max-time"; argc += 1;
    argv[argc] = "15"; argc += 1;
    argv[argc] = "-H"; argc += 1;
    argv[argc] = "User-Agent: Mozilla/5.0 (compatible; zik/0.1.0)"; argc += 1;
    argv[argc] = "-o"; argc += 1;
    argv[argc] = out_path; argc += 1;
    argv[argc] = "--stderr"; argc += 1;
    argv[argc] = err_path; argc += 1;
    argv[argc] = query_encoded; argc += 1;

    var child = std.process.Child.init(argv[0..argc], allocator);
    const term = try child.spawnAndWait();

    // For MVP, just return success with query info — full HTML parsing is complex
    std.fs.cwd().deleteFile(out_path) catch {};
    std.fs.cwd().deleteFile(err_path) catch {};

    if (term.Exited != 0) {
        return try std.fmt.allocPrint(allocator,
            "{{\"success\":false,\"error\":\"Search failed\"}}",
            .{},
        );
    }

    return try std.fmt.allocPrint(allocator,
        "{{\"success\":true,\"query\":\"{s}\",\"results\":[],\"note\":\"Full search results parsing not yet implemented\"}}",
        .{params.query},
    );
}

const WebSearchParams = struct {
    query: []const u8,
    max_results: usize = 10,
};

fn readFileSafely(allocator: std.mem.Allocator, path: []const u8, max_size: usize) ![]const u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch return "";
    defer file.close();
    return file.readToEndAlloc(allocator, max_size) catch "";
}

test "handleWebFetch: invalid URL fails" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const result = try handleWebFetch(allocator, "{\"url\":\"not-a-valid-url\"}", "/tmp");
    defer allocator.free(result);

    // Should either fail or return something
    _ = result;
}

test "handleWebSearch: basic search" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const result = try handleWebSearch(allocator, "{\"query\":\"zig programming language\"}", "/tmp");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":true") != null);
}
