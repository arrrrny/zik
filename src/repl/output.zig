const std = @import("std");

/// Streaming response output handler.
pub const StreamOutput = struct {
    stdout: std.fs.File,
    total_chars: usize,
    print_buf: [1024]u8,

    const Self = @This();

    pub fn init() Self {
        return .{
            .stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO },
            .total_chars = 0,
            .print_buf = undefined,
        };
    }

    /// Print a streaming chunk of text — uses raw posix write for immediate display.
    pub fn writeChunk(self: *Self, text: []const u8) !void {
        _ = try std.posix.write(self.stdout.handle, text);
        self.total_chars += text.len;
    }

    /// Print a newline after response is complete.
    pub fn finish(self: *Self) !void {
        if (self.total_chars > 0) {
            try self.stdout.writeAll("\n");
        }
        self.total_chars = 0;
    }

    /// Print a full response (non-streaming mode).
    pub fn writeFull(self: *Self, text: []const u8) !void {
        _ = try std.posix.write(self.stdout.handle, text);
        _ = try std.posix.write(self.stdout.handle, "\n");
    }

    /// Print formatted text — uses raw posix write.
    pub fn print(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.bufPrint(&self.print_buf, fmt, args);
        _ = try std.posix.write(self.stdout.handle, text);
    }

    /// Flush stdout — use raw writeAll on fd directly to avoid fsync issues on TTY.
    pub fn flush(self: *Self) !void {
        _ = self;
    }

    /// Print JSON output for scripting mode.
    pub fn writeJson(self: *Self, allocator: std.mem.Allocator, value: anytype) !void {
        _ = allocator;
        var buf: [8192]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try std.json.stringify(value, .{ .whitespace = .indent_2 }, fbs.writer());
        try self.stdout.writeAll(fbs.getWritten());
        try self.stdout.writeAll("\n");
    }
};

test "StreamOutput: write and finish" {
    var output = StreamOutput.init();
    try output.writeChunk("Hello");
    try output.writeChunk(", world!");
    try output.finish();
    try std.testing.expect(output.total_chars == 0);
}

test "StreamOutput: print" {
    var output = StreamOutput.init();
    try output.print("count={d}", .{42});
}
