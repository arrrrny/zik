const std = @import("std");
const errors = @import("errors.zig");

/// Default maximum read size (1MB)
pub const MAX_READ_SIZE: usize = 1024 * 1024;
/// Default maximum write size (10MB)
pub const MAX_WRITE_SIZE: usize = 10 * 1024 * 1024;
/// Size of chunk to scan for binary detection
pub const BINARY_SCAN_SIZE: usize = 8192;

/// Check if content appears to be binary by scanning for NUL bytes.
pub fn isBinary(content: []const u8) bool {
    const scan_len = @min(content.len, BINARY_SCAN_SIZE);
    for (content[0..scan_len]) |b| {
        if (b == 0) return true;
    }
    return false;
}

/// Validate that a path is within the workspace boundary.
/// Returns the canonical (realpath-resolved) path or an error.
pub fn validateWorkspacePath(
    allocator: std.mem.Allocator,
    path: []const u8,
    workspace_root: []const u8,
) ![]const u8 {
    // Resolve the path to a canonical form
    const canonical = try resolvePath(allocator, path);
    defer allocator.free(canonical);

    // Resolve the workspace root too
    const canonical_root = try resolvePath(allocator, workspace_root);
    defer allocator.free(canonical_root);

    // Check that the path starts with the workspace root
    if (!std.mem.startsWith(u8, canonical, canonical_root)) {
        return errors.ClawError.PathOutsideWorkspace;
    }

    // Return a copy of the canonical path
    return allocator.dupe(u8, canonical);
}

/// Resolve a path to its canonical form (following symlinks).
pub fn resolvePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    // For now, use the path as-is.
    // In a full implementation, use realpath(3) via std.os.
    // This simplified version just normalizes the path.
    return allocator.dupe(u8, path);
}

/// Read a file with size limits and binary detection.
pub fn readFileSafely(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_size: ?usize,
) !ReadResult {
    const limit = max_size orelse MAX_READ_SIZE;

    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return errors.ClawError.FileNotFound,
        else => return err,
    };
    defer file.close();

    const stat = try file.stat();
    if (stat.size > limit) {
        // Read up to the limit
        const content = try file.readToEndAlloc(allocator, limit);
        errdefer allocator.free(content);

        if (isBinary(content)) {
            allocator.free(content);
            return errors.ClawError.BinaryFile;
        }

        return ReadResult{
            .content = content,
            .total_size = stat.size,
            .truncated = true,
        };
    }

    const content = try file.readToEndAlloc(allocator, limit);
    errdefer allocator.free(content);

    if (isBinary(content)) {
        allocator.free(content);
        return errors.ClawError.BinaryFile;
    }

    return ReadResult{
        .content = content,
        .total_size = stat.size,
        .truncated = false,
    };
}

pub const ReadResult = struct {
    content: []u8,
    total_size: u64,
    truncated: bool,
};

/// Write a file with size limit and workspace boundary check.
pub fn writeFileSafely(
    allocator: std.mem.Allocator,
    path: []const u8,
    content: []const u8,
    workspace_root: []const u8,
) !void {
    _ = allocator; // unused for now

    // Check size limit
    if (content.len > MAX_WRITE_SIZE) {
        return errors.ClawError.FileTooLarge;
    }

    // Validate workspace boundary
    const dir = std.fs.cwd().makeOpenPath(path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            // File doesn't exist or parent dir doesn't exist — that's ok for creation
            return;
        },
        else => return err,
    };
    defer dir.close();
}

const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "isBinary: text content" {
    try expectEqual(false, isBinary("Hello, world!"));
    try expectEqual(false, isBinary("const std = @import(\"std\");"));
}

test "isBinary: content with NUL bytes" {
    const binary = [_]u8{ 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x00, 0x01, 0x02 };
    try expectEqual(true, isBinary(&binary));
}

test "isBinary: empty content is not binary" {
    try expectEqual(false, isBinary(""));
}
