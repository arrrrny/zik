const std = @import("std");
const ConversationContext = @import("../repl/context.zig").ConversationContext;

/// Session persistence — saves/loads conversation state to disk.
pub const SessionPersistence = struct {
    allocator: std.mem.Allocator,
    session_dir: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .session_dir = ".claw/sessions",
        };
    }

    /// Save session to a JSON file.
    pub fn save(self: *Self, session_id: []const u8, messages_json: []const u8, model: []const u8) !void {
        // Ensure directory exists
        std.fs.cwd().makePath(self.session_dir) catch {};

        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.json", .{ self.session_dir, session_id });
        defer self.allocator.free(path);

        const file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch |err| {
            std.debug.print("Failed to create session file: {}\n", .{err});
            return;
        };
        defer file.close();

        const content = try std.fmt.allocPrint(self.allocator,
            "{{\"session_id\":\"{s}\",\"model\":\"{s}\",\"messages\":{s},\"saved_at\":\"now\"}}",
            .{ session_id, model, messages_json },
        );
        defer self.allocator.free(content);

        try file.writeAll(content);
    }

    /// Load the latest session.
    pub fn loadLatest(self: *Self, allocator: std.mem.Allocator) !?[]const u8 {
        var dir = std.fs.cwd().openDir(self.session_dir, .{ .iterate = true }) catch return null;
        defer dir.close();

        var latest_time: i128 = 0;
        var latest_name: []const u8 = "";

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
                const stat = try dir.statFile(entry.name);
                if (stat.mtime > latest_time) {
                    latest_time = stat.mtime;
                    latest_name = try allocator.dupe(u8, entry.name);
                }
            }
        }

        if (latest_name.len == 0) return null;

        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.session_dir, latest_name });
        defer allocator.free(path);
        allocator.free(latest_name);

        const file = std.fs.cwd().openFile(path, .{}) catch return null;
        defer file.close();

        return file.readToEndAlloc(allocator, 1024 * 1024);
    }

    /// Load a specific session by ID.
    pub fn load(self: *Self, allocator: std.mem.Allocator, session_id: []const u8) !?[]const u8 {
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ self.session_dir, session_id });
        defer allocator.free(path);

        const file = std.fs.cwd().openFile(path, .{}) catch return null;
        defer file.close();

        return file.readToEndAlloc(allocator, 1024 * 1024);
    }
};

test "SessionPersistence: save and load" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var persistence = SessionPersistence.init(allocator);

    // Save a test session
    try persistence.save("test-session", "[{\"role\":\"user\",\"content\":\"hello\"}]", "test-model");

    // Load it back
    const loaded = try persistence.load(allocator, "test-session");
    try std.testing.expect(loaded != null);
    if (loaded) |data| {
        defer allocator.free(data);
        try std.testing.expect(std.mem.indexOf(u8, data, "test-session") != null);
    }

    // Cleanup
    std.fs.cwd().deleteFile(".claw/sessions/test-session.json") catch {};
}
