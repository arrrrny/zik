const std = @import("std");

/// Built-in model alias resolution.
pub const AliasResolver = struct {
    allocator: std.mem.Allocator,
    built_in: std.StringHashMap([]const u8),
    user_aliases: *std.StringHashMap([]const u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, user_aliases: *std.StringHashMap([]const u8)) Self {
        var built_in = std.StringHashMap([]const u8).init(allocator);
        built_in.put("opus", "claude-opus-4-6") catch unreachable;
        built_in.put("sonnet", "claude-sonnet-4-6");
        built_in.put("haiku", "claude-haiku-4-5-20251213");
        built_in.put("grok", "grok-3");
        built_in.put("grok-3", "grok-3");
        built_in.put("grok-mini", "grok-3-mini");
        built_in.put("grok-3-mini", "grok-3-mini");

        return .{
            .allocator = allocator,
            .built_in = built_in,
            .user_aliases = user_aliases,
        };
    }

    pub fn deinit(self: *Self) void {
        self.built_in.deinit();
    }

    /// Resolve an alias. Checks user-defined first, then built-in.
    /// If input is already a full model ID, returns as-is.
    pub fn resolve(self: *const Self, query: []const u8) []const u8 {
        if (self.user_aliases.get(query)) |resolved| return resolved;
        if (self.built_in.get(query)) |resolved| return resolved;
        return query;
    }
};

test "AliasResolver built-in resolution" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var user_aliases = std.StringHashMap([]const u8).init(allocator);
    defer user_aliases.deinit();

    var resolver = AliasResolver.init(allocator, &user_aliases);
    defer resolver.deinit();

    try std.testing.expectEqualStrings("claude-sonnet-4-6", resolver.resolve("sonnet"));
    try std.testing.expectEqualStrings("claude-opus-4-6", resolver.resolve("opus"));
    try std.testing.expectEqualStrings("grok-3", resolver.resolve("grok"));
    try std.testing.expectEqualStrings("grok-3-mini", resolver.resolve("grok-mini"));
}

test "AliasResolver user override" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var user_aliases = std.StringHashMap([]const u8).init(allocator);
    defer user_aliases.deinit();

    user_aliases.put("sonnet", "gpt-4.1") catch unreachable;

    var resolver = AliasResolver.init(allocator, &user_aliases);
    defer resolver.deinit();

    try std.testing.expectEqualStrings("gpt-4.1", resolver.resolve("sonnet"));
    try std.testing.expectEqualStrings("claude-opus-4-6", resolver.resolve("opus"));
}

test "AliasResolver passthrough" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var user_aliases = std.StringHashMap([]const u8).init(allocator);
    defer user_aliases.deinit();

    var resolver = AliasResolver.init(allocator, &user_aliases);
    defer resolver.deinit();

    try std.testing.expectEqualStrings("claude-sonnet-4-6", resolver.resolve("claude-sonnet-4-6"));
    try std.testing.expectEqualStrings("gpt-4.1-mini", resolver.resolve("gpt-4.1-mini"));
    try std.testing.expectEqualStrings("llama3.2", resolver.resolve("llama3.2"));
}
