const std = @import("std");

/// TodoWrite tool — manages a todo list during a conversation.
pub fn handleTodoWrite(allocator: std.mem.Allocator, input_json: []const u8, workspace_root: []const u8) anyerror![]const u8 {
    _ = workspace_root;

    const params = try std.json.parseFromSliceLeaky(TodoParams, allocator, input_json, .{});

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;

    inline fn add(s: []const u8) void {
        const len = s.len;
        @memcpy(buf[pos..][0..len], s);
        pos += len;
    }

    add("{\"success\":true,\"todos\":[");

    for (params.todos, 0..) |todo, i| {
        if (i > 0) add(",");
        add("{\"content\":\"");
        add(todo.content);
        add("\",\"status\":\"");
        add(todo.status.toString());
        if (todo.priority) |p| {
            add("\",\"priority\":\"");
            add(p.toString());
        }
        add("\"}");
    }

    add("]}");

    return allocator.dupe(u8, buf[0..pos]);
}

const TodoStatus = enum { pending, in_progress, completed };
const TodoPriority = enum { high, medium, low };

fn toString(self: TodoStatus) []const u8 {
    return switch (self) {
        .pending => "pending",
        .in_progress => "in_progress",
        .completed => "completed",
    };
}

fn toString(self: TodoPriority) []const u8 {
    return switch (self) {
        .high => "high",
        .medium => "medium",
        .low => "low",
    };
}

const TodoItem = struct {
    content: []const u8,
    status: TodoStatus,
    priority: ?TodoPriority = null,
};

const TodoParams = struct {
    todos: []TodoItem,
};

test "handleTodoWrite: basic todos" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const result = try handleTodoWrite(allocator, "{\"todos\":[{\"content\":\"test\",\"status\":\"pending\"}]}", "/tmp");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"success\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"content\":\"test\"") != null);
}
