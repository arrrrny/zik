const std = @import("std");

/// SSE parser using fixed-size buffers (Zig 0.15 compatible).
pub const SSEParser = struct {
    allocator: std.mem.Allocator,
    on_event: *const fn (event_type: []const u8, data: []const u8, user_data: *anyopaque) void,
    user_data: *anyopaque,
    event_buf: [1024]u8,
    event_len: usize,
    data_buf: [8192]u8,
    data_len: usize,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        on_event: *const fn (event_type: []const u8, data: []const u8, user_data: *anyopaque) void,
        user_data: *anyopaque,
    ) Self {
        return .{
            .allocator = allocator,
            .on_event = on_event,
            .user_data = user_data,
            .event_buf = undefined,
            .event_len = 0,
            .data_buf = undefined,
            .data_len = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    fn reset(self: *Self) void {
        self.event_len = 0;
        self.data_len = 0;
    }

    pub fn parseChunk(self: *Self, chunk: []const u8) !void {
        var lines = std.mem.splitSequence(u8, chunk, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, "\r");
            if (trimmed.len == 0) {
                if (self.data_len > 0 or self.event_len > 0) {
                    self.dispatchEvent();
                    self.reset();
                }
                continue;
            }

            if (std.mem.startsWith(u8, trimmed, "event: ")) {
                const src = trimmed["event: ".len..];
                const available = self.event_buf.len - self.event_len;
                if (available >= src.len) {
                    @memcpy(self.event_buf[self.event_len..][0..src.len], src);
                    self.event_len += src.len;
                }
            } else if (std.mem.startsWith(u8, trimmed, "data: ")) {
                const data = trimmed["data: ".len..];
                if (std.mem.eql(u8, data, "[DONE]")) continue;
                const available = self.data_buf.len - self.data_len;
                if (available >= data.len) {
                    @memcpy(self.data_buf[self.data_len..][0..data.len], data);
                    self.data_len += data.len;
                }
            }
        }
    }

    fn dispatchEvent(self: *Self) void {
        self.on_event(self.event_buf[0..self.event_len], self.data_buf[0..self.data_len], self.user_data);
    }
};

/// Extract text from Anthropic content_block_delta.
pub fn extractDeltaText(data: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
    const parsed = try std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        data,
        .{ .allocate = .alloc_always },
    );

    if (parsed != .object) return null;
    const obj = parsed.object;

    if (obj.get("delta")) |delta| {
        if (delta == .object) {
            if (delta.object.get("text")) |text| {
                if (text == .string) return text.string;
            }
        }
    }
    return null;
}

/// Extract text from OpenAI choice delta.
pub fn extractOpenAIChoiceDelta(data: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
    const parsed = try std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        data,
        .{ .allocate = .alloc_always },
    );

    if (parsed != .object) return null;
    const obj = parsed.object;

    if (obj.get("choices")) |choices| {
        if (choices == .array and choices.array.items.len > 0) {
            const first = choices.array.items[0];
            if (first == .object) {
                if (first.object.get("delta")) |delta| {
                    if (delta == .object) {
                        if (delta.object.get("content")) |content| {
                            if (content == .string) return content.string;
                        }
                    }
                }
            }
        }
    }
    return null;
}

test "extractDeltaText: Anthropic delta" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const json = "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"world\"}}";
    const text = try extractDeltaText(json, allocator);

    try std.testing.expect(text != null);
    try std.testing.expectEqualStrings("world", text.?);
}

test "extractOpenAIChoiceDelta: OpenAI delta" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const json = "{\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}";
    const text = try extractOpenAIChoiceDelta(json, allocator);

    try std.testing.expect(text != null);
    try std.testing.expectEqualStrings("hello", text.?);
}
