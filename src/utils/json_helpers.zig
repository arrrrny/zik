const std = @import("std");

/// Parse a JSON string into a value of type T.
pub fn parseJson(allocator: std.mem.Allocator, comptime T: type, json: []const u8) !T {
    return try std.json.parseFromSliceLeaky(T, allocator, json, .{});
}

/// Serialize a value to a JSON string.
/// Caller must free the returned string.
pub fn toJson(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    try std.json.stringify(value, .{}, out.writer());
    return out.toOwnedSlice();
}

/// Pretty-print a JSON value to a string.
pub fn toJsonPretty(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    try std.json.stringify(value, .{ .whitespace = .indent_2 }, out.writer());
    return out.toOwnedSlice();
}

/// Deep-merge two JSON objects. Fields in `override` take precedence.
/// Returns a new allocated object. Caller must free.
pub fn mergeJson(
    allocator: std.mem.Allocator,
    base: std.json.Value,
    override: std.json.Value,
) !std.json.Value {
    if (base != .object or override != .object) {
        // If either is not an object, override wins
        return override;
    }

    var merged = std.json.ObjectMap.init(allocator);
    errdefer merged.deinit();

    // Copy all base fields
    var base_it = base.object.iterator();
    while (base_it.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key);
        try merged.put(key, entry.value_ptr.*);
    }

    // Override with new fields
    var over_it = override.object.iterator();
    while (over_it.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        // If key exists in both and both are objects, recurse
        if (merged.get(key)) |base_val| {
            if (base_val == .object and entry.value_ptr.* == .object) {
                const merged_val = try mergeJson(allocator, base_val, entry.value_ptr.*);
                _ = merged.fetchPut(key, merged_val);
                continue;
            }
        }
        errdefer allocator.free(key);
        _ = merged.fetchPut(key, entry.value_ptr.*);
    }

    return .{ .object = merged };
}

test "toJson and parse roundtrip" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const data = .{ .name = "claw", .version = 1 };
    const json = try toJson(allocator, data);
    defer allocator.free(json);

    const parsed = try parseJson(allocator, struct { name: []const u8, version: u32 }, json);
    try std.testing.expectEqualStrings("claw", parsed.name);
    try std.testing.expectEqual(@as(u32, 1), parsed.version);
}

test "toJsonPretty produces indented output" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const data = .{ .a = 1, .b = "hello" };
    const json = try toJsonPretty(allocator, data);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\n") != null);
}
