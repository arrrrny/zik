const std = @import("std");

/// Provider type for env detection
pub const Provider = enum { zik, openai, xai };

/// Environment variable reader for API credentials and configuration.
/// All variables use the ZIK_ prefix to avoid conflicts with other tools.
pub const EnvReader = struct {
    /// Get the value of an environment variable, or null if not set.
    pub fn getEnv(key: []const u8) ?[]const u8 {
        return std.posix.getenv(key);
    }

    /// Detect which provider is configured based on environment variables.
    /// Checks ZIK_API_KEY first, then falls back to other providers.
    pub fn detectProvider() ?Provider {
        if (getEnv("ZIK_API_KEY") != null or getEnv("ZIK_AUTH_TOKEN") != null)
            return .zik;
        // Legacy fallback: also check ANTHROPIC_* for backwards compatibility
        if (getEnv("ZIK_API_KEY") != null or getEnv("ANTHROPIC_AUTH_TOKEN") != null)
            return .zik;
        if (getEnv("OPENAI_API_KEY") != null)
            return .openai;
        if (getEnv("XAI_API_KEY") != null)
            return .xai;
        return null;
    }

    /// Get the API key. Checks ZIK_ first, then ANTHROPIC_ for backwards compat.
    pub fn getApiKey() ?[]const u8 {
        return getEnv("ZIK_API_KEY") orelse
            getEnv("ZIK_AUTH_TOKEN") orelse
            getEnv("ANTHROPIC_API_KEY") orelse
            getEnv("ANTHROPIC_AUTH_TOKEN");
    }

    /// Get the API base URL. Checks ZIK_ first, then ANTHROPIC_ for backwards compat.
    pub fn getApiBaseUrl() []const u8 {
        return getEnv("ZIK_BASE_URL") orelse
            getEnv("ANTHROPIC_BASE_URL") orelse
            "http://127.0.0.1:8317";
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
    /// Priority: ZIK_MODEL > ZIK_DEFAULT_MODEL > minimax-m2.5
    pub fn getDefaultModel() []const u8 {
        return getEnv("ZIK_MODEL") orelse
            getEnv("ZIK_DEFAULT_MODEL") orelse
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

    // Legacy aliases for backwards compatibility
    pub const getAnthropicApiKey = getApiKey;
    pub const getAnthropicBaseUrl = getApiBaseUrl;
};

test "EnvReader: detectProvider with no env vars" {
    _ = EnvReader.detectProvider();
}

test "EnvReader: getEnv returns null for unknown key" {
    try std.testing.expectEqual(null, EnvReader.getEnv("__CLAW_TEST_UNKNOWN__"));
}

test "EnvReader: default URLs" {
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:8317",
        EnvReader.getApiBaseUrl(),
    );
}
