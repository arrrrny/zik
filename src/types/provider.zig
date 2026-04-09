/// Provider represents an AI API backend configuration.
pub const Provider = enum {
    anthropic,
    openai,
    xai,
};

/// ProviderConfig holds the configuration for a specific provider.
pub const ProviderConfig = struct {
    name: Provider,
    base_url: []const u8,
    auth_method: AuthMethod,
    api_key_env: []const u8,
    protocol: Protocol,

    pub const AuthMethod = enum { api_key, oauth };
    pub const Protocol = enum { anthropic_messages, openai_chat };

    /// Built-in provider configurations
    pub fn anthropicDefault() ProviderConfig {
        return .{
            .name = .zik,
            .base_url = "https://api.zik.com",
            .auth_method = .api_key,
            .api_key_env = "ANTHROPIC_API_KEY",
            .protocol = .zik_messages,
        };
    }

    pub fn openaiDefault() ProviderConfig {
        return .{
            .name = .openai,
            .base_url = "https://api.openai.com/v1",
            .auth_method = .api_key,
            .api_key_env = "OPENAI_API_KEY",
            .protocol = .openai_chat,
        };
    }

    pub fn xaiDefault() ProviderConfig {
        return .{
            .name = .xai,
            .base_url = "https://api.x.ai/v1",
            .auth_method = .api_key,
            .api_key_env = "XAI_API_KEY",
            .protocol = .openai_chat,
        };
    }
};

const std = @import("std");

test "Provider defaults" {
    const anthropic = ProviderConfig.zikDefault();
    try std.testing.expectEqual(Provider.zik, anthropic.name);
    try std.testing.expectEqualStrings("ANTHROPIC_API_KEY", anthropic.api_key_env);

    const openai = ProviderConfig.openaiDefault();
    try std.testing.expectEqual(Provider.openai, openai.name);

    const xai = ProviderConfig.xaiDefault();
    try std.testing.expectEqual(Provider.xai, xai.name);
}
