/// Configuration represents runtime settings loaded from merged config files.
pub const Configuration = struct {
    /// Default model identifier (optional)
    model: ?[]const u8 = null,
    /// Default permission mode (optional)
    permission_mode: ?PermissionMode = null,
    /// Default workspace path (optional)
    workspace_root: ?[]const u8 = null,
    /// User-defined model alias map
    aliases: std.StringHashMap([]const u8),
    /// Proxy configuration (optional)
    proxy: ?ProxyConfig = null,
    /// Response format
    output_format: OutputFormat = .text,
    /// Override for Anthropic endpoint
    anthropic_base_url: ?[]const u8 = null,
    /// Override for OpenAI endpoint
    openai_base_url: ?[]const u8 = null,

    pub const PermissionMode = enum {
        read_only,
        workspace_write,
        danger_full_access,
    };

    pub const OutputFormat = enum { text, json };

    pub const ProxyConfig = struct {
        proxy_url: ?[]const u8 = null,
        no_proxy: ?[]const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator) Configuration {
        return .{
            .aliases = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Configuration) void {
        var it = self.aliases.iterator();
        while (it.next()) |entry| {
            self.aliases.allocator.free(entry.key_ptr.*);
            self.aliases.allocator.free(entry.value_ptr.*);
        }
        self.aliases.deinit();
    }
};

const std = @import("std");

test "Configuration init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var config = Configuration.init(allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(?[]const u8, null), config.model);
    try std.testing.expectEqual(Configuration.OutputFormat.text, config.output_format);
}
