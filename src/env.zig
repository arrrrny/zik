const std = @import("std");

/// Provider type for env detection
pub const Provider = enum { anthropic, openai, xai };

/// Environment variable reader for API credentials and configuration.
pub const EnvReader = struct {
    /// Get the value of an environment variable, or null if not set.
    pub fn getEnv(key: []const u8) ?[]const u8 {
        return std.posix.getenv(key);
    }

    /// Detect which provider is configured based on environment variables.
    pub fn detectProvider() ?Provider {
        // Check in order: Anthropic → OpenAI → xAI
        if (getEnv("ANTHROPIC_API_KEY") != null or getEnv("ANTHROPIC_AUTH_TOKEN") != null)
            return .anthropic;
        if (getEnv("OPENAI_API_KEY") != null)
            return .openai;
        if (getEnv("XAI_API_KEY") != null)
            return .xai;
        return null;
    }

    /// Get the Anthropic API key, or null if not set.
    pub fn getAnthropicApiKey() ?[]const u8 {
        return getEnv("ANTHROPIC_API_KEY") orelse getEnv("ANTHROPIC_AUTH_TOKEN");
    }

    /// Get the Anthropic base URL, defaulting to the official API.
    pub fn getAnthropicBaseUrl() []const u8 {
        return getEnv("ANTHROPIC_BASE_URL") orelse "https://api.anthropic.com";
    }

    /// Get the OpenAI API key, or null if not set.
    pub fn getOpenaiApiKey() ?[]const u8 {
        return getEnv("OPENAI_API_KEY");
    }

    /// Get the OpenAI base URL, defaulting to the official API.
    pub fn getOpenaiBaseUrl() []const u8 {
        return getEnv("OPENAI_BASE_URL") orelse "https://api.openai.com/v1";
    }

    /// Get the xAI API key, or null if not set.
    pub fn getXaiApiKey() ?[]const u8 {
        return getEnv("XAI_API_KEY");
    }

    /// Get the xAI base URL, defaulting to the official API.
    pub fn getXaiBaseUrl() []const u8 {
        return getEnv("XAI_BASE_URL") orelse "https://api.x.ai/v1";
    }

    /// Get the default model from env, or fallback to working free models.
    pub fn getDefaultModel() []const u8 {
        return getEnv("ZIK_MODEL") orelse
            getEnv("ANTHROPIC_DEFAULT_SONNET_MODEL") orelse
            getEnv("ANTHROPIC_DEFAULT_MODEL") orelse
            "minimax-m2.5";
    }

    /// Get the HTTP proxy URL, or null if not set.
    pub fn getHttpProxy() ?[]const u8 {
        return getEnv("HTTPS_PROXY") orelse getEnv("http_proxy") orelse getEnv("HTTP_PROXY");
    }

    /// Get the no-proxy list, or null if not set.
    pub fn getNoProxy() ?[]const u8 {
        return getEnv("NO_PROXY");
    }
};

test "EnvReader: detectProvider with no env vars" {
    // In test environment, env vars may or may not be set.
    // Just verify the function doesn't crash.
    _ = EnvReader.detectProvider();
}

test "EnvReader: getEnv returns null for unknown key" {
    try std.testing.expectEqual(null, EnvReader.getEnv("__CLAW_TEST_UNKNOWN__"));
}

test "EnvReader: default URLs" {
    try std.testing.expectEqualStrings(
        "https://api.anthropic.com",
        EnvReader.getAnthropicBaseUrl(),
    );
}
