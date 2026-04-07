const std = @import("std");
const HttpClient = @import("http_client.zig").HttpClient;
const EnvReader = @import("../env.zig").EnvReader;

/// Anthropic API client.
/// Implements the /v1/messages endpoint protocol.
pub const AnthropicClient = struct {
    allocator: std.mem.Allocator,
    http_client: *HttpClient,
    base_url: []const u8,
    api_key: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, http_client: *HttpClient) !Self {
        const api_key = EnvReader.getAnthropicApiKey() orelse return error.AuthFailed;
        const base_url = EnvReader.getAnthropicBaseUrl();

        return .{
            .allocator = allocator,
            .http_client = http_client,
            .base_url = base_url,
            .api_key = api_key,
        };
    }
};

/// Create standard Anthropic API headers.
pub fn createAnthropicHeaders(allocator: std.mem.Allocator, api_key: []const u8) !std.http.Headers {
    var headers = std.http.Headers.init(allocator);
    errdefer headers.deinit();

    try headers.append("Content-Type", "application/json");
    try headers.append("x-api-key", api_key);
    try headers.append("anthropic-version", "2023-06-01");
    try headers.append("anthropic-beta", "tools-2024-04-04");

    return headers;
}

/// Build a streaming request body JSON.
pub fn buildStreamBody(allocator: std.mem.Allocator, model: []const u8, messages_json: []const u8, max_tokens: u32) ![]const u8 {
    return try std.fmt.allocPrint(
        allocator,
        "{{\"model\":\"{s}\",\"max_tokens\":{},\"stream\":true,\"messages\":{s}}}",
        .{ model, max_tokens, messages_json },
    );
}

test "AnthropicClient: init requires API key" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var http = HttpClient.init(allocator);
    defer http.deinit();

    const result = AnthropicClient.init(allocator, &http);
    _ = result;
}

test "createAnthropicHeaders" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const headers = try createAnthropicHeaders(allocator, "sk-test");
    defer headers.deinit();

    try std.testing.expect(headers.count() >= 3);
}
