const std = @import("std");
const EnvReader = @import("../env.zig").EnvReader;

/// HTTP client wrapper using Zig stdlib's std.http.Client.
/// Supports proxy configuration and streaming responses.
pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,
    proxy_url: ?[]const u8 = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .client = std.http.Client{ .allocator = allocator },
            .proxy_url = EnvReader.getHttpProxy(),
        };
    }

    pub fn deinit(self: *Self) void {
        self.client.deinit();
    }

    /// Perform a POST request with optional streaming response callback.
    /// If stream_callback is provided, response body is read incrementally.
    /// Otherwise, full body is returned.
    pub fn post(
        self: *Self,
        url: []const u8,
        headers: std.http.Headers,
        body: []const u8,
        stream_callback: ?*const fn (chunk: []const u8, user_data: *anyopaque) void,
        user_data: ?*anyopaque,
    ) !Response {
        const uri = try std.Uri.parse(url);
        var server_header_buffer: [1024]u8 = undefined;

        var request = try self.client.open(
            .POST,
            uri,
            .{
                .server_header_buffer = &server_header_buffer,
                .extra_headers = &headers,
            },
        );
        defer request.deinit();

        try request.sendHeaders();
        try request.writeAll(body);
        try request.finish();

        try request.wait();

        if (request.response.status.class() != .success) {
            const err_body = try request.readAllAlloc(self.allocator, 4096);
            return Response{
                .status = request.response.status,
                .body = err_body,
                .success = false,
            };
        }

        if (stream_callback) |cb| {
            // Stream response body incrementally
            var buf: [4096]u8 = undefined;
            var total_read: usize = 0;
            while (true) {
                const n = try request.read(&buf);
                if (n == 0) break;
                cb(buf[0..n], user_data.?);
                total_read += n;
            }
            return Response{
                .status = request.response.status,
                .body = try self.allocator.dupe(u8, &.{ 0 }),
                .success = true,
                .streamed = true,
                .bytes_read = total_read,
            };
        } else {
            // Read full response
            const response_body = try request.readAllAlloc(self.allocator, 1024 * 1024);
            return Response{
                .status = request.response.status,
                .body = response_body,
                .success = true,
            };
        }
    }
};

pub const Response = struct {
    status: std.http.Status,
    body: []const u8,
    success: bool,
    streamed: bool = false,
    bytes_read: usize = 0,
};

/// Create standard API headers for a request.
pub fn createApiHeaders(
    allocator: std.mem.Allocator,
    content_type: []const u8,
    auth_token: []const u8,
    anthropic_version: ?[]const u8,
) !std.http.Headers {
    var headers = std.http.Headers.init(allocator);
    errdefer headers.deinit();

    try headers.append("Content-Type", content_type);
    try headers.append("Authorization", try std.fmt.allocPrint(allocator, "Bearer {s}", .{auth_token}));

    if (anthropic_version) |v| {
        try headers.append("anthropic-version", v);
    }

    return headers;
}

test "HttpClient init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = HttpClient.init(allocator);
    defer client.deinit();

    try std.testing.expectEqual(allocator, client.allocator);
}

test "createApiHeaders: Anthropic format" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const headers = try createApiHeaders(allocator, "application/json", "sk-test", "2023-06-01");
    defer headers.deinit();

    try std.testing.expect(headers.count() >= 3);
}

test "createApiHeaders: OpenAI format" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const headers = try createApiHeaders(allocator, "application/json", "sk-openai", null);
    defer headers.deinit();

    try std.testing.expect(headers.count() >= 2);
}
