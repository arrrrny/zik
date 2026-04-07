const std = @import("std");

/// ConfigLoader handles loading and merging configuration from multiple sources.
///
/// Config paths in precedence order (later overrides earlier):
/// 1. ~/.claw.json (user-level)
/// 2. ~/.config/claw/settings.json (user config directory)
/// 3. <repo>/.claw.json (project-level)
/// 4. <repo>/.claw/settings.json (project settings)
/// 5. <repo>/.claw/settings.local.json (local overrides)
pub const ConfigLoader = struct {
    allocator: std.mem.Allocator,
    model: ?[]const u8 = null,
    permission_mode: ?PermissionMode = null,
    output_format: OutputFormat = .text,
    aliases: std.StringHashMap([]const u8),

    pub const PermissionMode = enum { read_only, workspace_write, danger_full_access };
    pub const OutputFormat = enum { text, json };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .aliases = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.aliases.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.aliases.deinit();
    }

    /// Load configuration from all sources with correct precedence.
    pub fn discover(self: *Self) !void {
        const home_dir = std.posix.getenv("HOME") orelse "";

        const config_paths = [_][]const u8{
            try std.fmt.allocPrint(self.allocator, "{s}/.claw.json", .{home_dir}),
            try std.fmt.allocPrint(self.allocator, "{s}/.config/claw/settings.json", .{home_dir}),
            try std.fmt.allocPrint(self.allocator, "{s}/.claw.json", .{"."}),
            try std.fmt.allocPrint(self.allocator, "{s}/.claw/settings.json", .{"."}),
            try std.fmt.allocPrint(self.allocator, "{s}/.claw/settings.local.json", .{"."}),
        };
        defer {
            for (config_paths) |p| {
                self.allocator.free(p);
            }
        }

        for (config_paths) |path| {
            self.loadFile(path) catch |err| {
                if (err != error.FileNotFound) return err;
            };
        }
    }

    fn loadFile(self: *Self, path: []const u8) !void {
        const file = std.fs.cwd().openFile(path, .{}) catch return error.FileNotFound;
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        var parsed = try std.json.parseFromSliceLeaky(
            std.json.Value,
            self.allocator,
            content,
            .{ .allocate = .alloc_always },
        );

        if (parsed != .object) return;
        const obj = parsed.object;
        var it = obj.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "model")) {
                if (entry.value_ptr.* == .string) self.model = entry.value_ptr.*.string;
            } else if (std.mem.eql(u8, entry.key_ptr.*, "permission_mode")) {
                if (entry.value_ptr.* == .string) {
                    const s = entry.value_ptr.*.string;
                    if (std.mem.eql(u8, s, "read-only")) self.permission_mode = .read_only;
                    if (std.mem.eql(u8, s, "workspace-write")) self.permission_mode = .workspace_write;
                    if (std.mem.eql(u8, s, "danger-full-access")) self.permission_mode = .danger_full_access;
                }
            } else if (std.mem.eql(u8, entry.key_ptr.*, "output_format")) {
                if (entry.value_ptr.* == .string) {
                    if (std.mem.eql(u8, entry.value_ptr.*.string, "json")) self.output_format = .json;
                }
            } else if (std.mem.eql(u8, entry.key_ptr.*, "aliases")) {
                if (entry.value_ptr.* == .object) {
                    var ait = entry.value_ptr.*.object.iterator();
                    while (ait.next()) |ae| {
                        if (ae.value_ptr.* == .string) {
                            const key = try self.allocator.dupe(u8, ae.key_ptr.*);
                            const val = try self.allocator.dupe(u8, ae.value_ptr.*.string);
                            _ = self.aliases.fetchPut(key, val);
                        }
                    }
                }
            }
        }
    }
};

test "ConfigLoader init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var loader = ConfigLoader.init(allocator);
    defer loader.deinit();

    try std.testing.expect(loader.model == null);
    try std.testing.expectEqual(ConfigLoader.OutputFormat.text, loader.output_format);
}

test "ConfigLoader discover with no config files" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var loader = ConfigLoader.init(allocator);
    defer loader.deinit();

    try loader.discover();
    try std.testing.expect(loader.model == null);
}
