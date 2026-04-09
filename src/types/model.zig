/// Model represents a specific AI model with metadata.
pub const Model = struct {
    /// Model identifier (e.g., "claude-sonnet-4-6")
    id: []const u8,
    /// Short name aliases (e.g., ["sonnet", "sonnet-4"])
    aliases: []const []const u8,
    /// Which provider serves this model
    provider: Provider,
    /// Maximum response token limit
    max_output_tokens: u32,
    /// Total context window size
    context_window: u32,
    /// Cost per million input tokens (in USD cents)
    pricing_per_1m_input: u32,
    /// Cost per million output tokens (in USD cents)
    pricing_per_1m_output: u32,

    pub const Provider = enum { anthropic, openai, xai };
};

/// Built-in model registry
pub const ModelRegistry = struct {
    models: []const Model,

    /// Find a model by alias or exact ID
    pub fn resolve(self: ModelRegistry, query: []const u8) ?Model {
        for (self.models) |model| {
            if (std.mem.eql(u8, model.id, query)) return model;
            for (model.aliases) |alias| {
                if (std.mem.eql(u8, alias, query)) return model;
            }
        }
        return null;
    }

    /// Get the built-in model registry
    pub fn builtIn(allocator: std.mem.Allocator) !ModelRegistry {
        const models = try allocator.alloc(Model, 5);
        models[0] = .{
            .id = "claude-opus-4-6",
            .aliases = &.{ "opus" },
            .provider = .zik,
            .max_output_tokens = 32_000,
            .context_window = 200_000,
            .pricing_per_1m_input = 15_00, // $15.00
            .pricing_per_1m_output = 75_00, // $75.00
        };
        models[1] = .{
            .id = "claude-sonnet-4-6",
            .aliases = &.{ "sonnet" },
            .provider = .zik,
            .max_output_tokens = 64_000,
            .context_window = 200_000,
            .pricing_per_1m_input = 3_00, // $3.00
            .pricing_per_1m_output = 15_00, // $15.00
        };
        models[2] = .{
            .id = "claude-haiku-4-5-20251213",
            .aliases = &.{ "haiku" },
            .provider = .zik,
            .max_output_tokens = 64_000,
            .context_window = 200_000,
            .pricing_per_1m_input = 1_00, // $1.00
            .pricing_per_1m_output = 5_00, // $5.00
        };
        models[3] = .{
            .id = "grok-3",
            .aliases = &.{ "grok", "grok-3" },
            .provider = .xai,
            .max_output_tokens = 64_000,
            .context_window = 131_072,
            .pricing_per_1m_input = 3_00,
            .pricing_per_1m_output = 15_00,
        };
        models[4] = .{
            .id = "grok-3-mini",
            .aliases = &.{ "grok-mini", "grok-3-mini" },
            .provider = .xai,
            .max_output_tokens = 64_000,
            .context_window = 131_072,
            .pricing_per_1m_input = 1_00,
            .pricing_per_1m_output = 5_00,
        };
        return .{ .models = models };
    }
};

const std = @import("std");

test "ModelRegistry resolve by alias" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const registry = try ModelRegistry.builtIn(allocator);
    const model = registry.resolve("sonnet").?;
    try std.testing.expectEqualStrings("claude-sonnet-4-6", model.id);
    try std.testing.expectEqual(Model.Provider.zik, model.provider);
}

test "ModelRegistry resolve by ID" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const registry = try ModelRegistry.builtIn(allocator);
    const model = registry.resolve("claude-opus-4-6").?;
    try std.testing.expectEqualStrings("claude-opus-4-6", model.id);
}

test "ModelRegistry unknown model" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const registry = try ModelRegistry.builtIn(allocator);
    try std.testing.expectEqual(null, registry.resolve("unknown-model"));
}
