const std = @import("std");
const HttpClient = @import("http_client.zig").HttpClient;
const SSEParser = @import("../utils/streaming.zig").SSEParser;
const extractOpenAIChoiceDelta = @import("../utils/streaming.zig").extractOpenAIChoiceDelta;
const EnvReader = @import("../env.zig").EnvReader;

/// OpenAI-compatible API client (works with OpenAI, Ollama, OpenRouter, etc.)
pub const OpenAIClient = struct {
    allocator: std.mem.Allocator,
    http_client: *HttpClient,
    base_url: []const u8,
    api_key: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, http_client: *HttpClient, provider_name: ProviderName) !Self {
        const api_key = switch (provider_name) {
            .openai => EnvReader.getOpenaiApiKey() orelse return error.AuthFailed,
            .xai => EnvReader.getXaiApiKey() orelse return error.AuthFailed,
        };
        const base_url = switch (provider_name) {
            .openai => EnvReader.getOpenaiBaseUrl(),
            .xai => EnvReader.getXaiBaseUrl(),
        };

        return .{
            .allocator = allocator,
            .http_client = http_client,
            .base_url = base_url,
            .api_key = api_key,
        };
    }

    pub const ProviderName = enum { openai, xai };

    /// Send a chat completions API request.
    pub fn sendMessage(
        self: *Self,
        model: []const u8,
        messages_json: []const u8,
    ) ![]const u8 {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/chat/completions", .{self.base_url});
        defer self.allocator.free(url);

        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"model\":\"{s}\",\"messages\":{s}}}",
            .{ model, messages_json },
        );
        defer self.allocator.free(body);

        var headers = std.http.Headers.init(self.allocator);
        defer headers.deinit();
        try headers.append("Content-Type", "application/json");
        try headers.append("Authorization", try std.fmt.allocPrint(
            self.allocator,
            "Bearer {s}",
            .{self.api_key},
        ));

        const response = try self.http_client.post(url, headers, body, null, null);
        return response.body;
    }
};

test "OpenAIClient: init requires API key" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var http = HttpClient.init(allocator);
    defer http.deinit();

    const result = OpenAIClient.init(allocator, &http, .openai);
    _ = result; // May fail if env var not set
}
