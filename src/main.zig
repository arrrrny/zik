const std = @import("std");
const CliArgs = @import("cli/args.zig").CliArgs;
const EnvReader = @import("env.zig").EnvReader;
const REPL = @import("repl/mod.zig").REPL;
const acp = @import("acp/mod.zig");

pub fn main() !void {
    // Use page_allocator for a CLI — memory freed on process exit
    const allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const parsed = try CliArgs.parse(allocator, args);

    switch (parsed.command) {
        .help => printHelp(),
        .version => std.debug.print("zik 0.1.0 (Zig rewrite — MVP in progress)\n", .{}),
        .prompt => {
            if (parsed.prompt_text) |text| {
                try runPrompt(allocator, text, parsed);
            }
        },
        .shorthand => {
            if (parsed.prompt_text) |text| {
                try runPrompt(allocator, text, parsed);
            }
        },
        .repl => {
            if (EnvReader.detectProvider() == null) {
                std.debug.print(
                    \\Error: No API key found.
                    \\Set one of:
                    \\  ZIK_API_KEY
                    \\  OPENAI_API_KEY (+ OPENAI_BASE_URL)
                    \\  XAI_API_KEY
                    \\
                , .{});
                std.posix.exit(2);
            }

            var repl = try REPL.init(allocator, EnvReader.resolveModelAlias(parsed.model orelse EnvReader.getDefaultModel()), null, parsed.resume_session);
            defer repl.deinit();

            if (parsed.output_format == .json) {
                repl.output_format = .json;
            }

            try repl.run();
        },
        .acp => {
            std.debug.print("zik ACP server v0.1.0 (protocol v{d})\n", .{acp.PROTOCOL_VERSION});
        },
    }
}

/// Run a one-shot prompt (non-interactive).
fn runPrompt(allocator: std.mem.Allocator, text: []const u8, parsed: CliArgs) !void {
    if (EnvReader.detectProvider() == null) {
        std.debug.print(
            \\Error: No API key found.
            \\Set one of: ZIK_API_KEY, ZIK_BASE_URL
            \\
        , .{});
        std.posix.exit(2);
    }

    var repl = try REPL.init(allocator, EnvReader.resolveModelAlias(parsed.model orelse EnvReader.getDefaultModel()), null, parsed.resume_session);
    defer repl.deinit();

    if (parsed.output_format == .json) {
        repl.output_format = .json;
    }

    // Single turn, no REPL loop
    try repl.processTurn(text);
}

fn printHelp() void {
    std.debug.print(
        \\zik — AI coding agent CLI (Zig rewrite)
        \\
        \\Usage:
        \\  zik [OPTIONS]              Launch interactive REPL
        \\  zik prompt "<message>"     One-shot prompt
        \\  zik "<message>"            Shorthand prompt
        \\
        \\Options:
        \\  -h, --help                  Show this help message
        \\  -V, --version               Show version information
        \\  --acp                       Run as ACP server (JSON-RPC over stdio)
        \\  -m, --model <model>         Override the model to use
        \\  --permission-mode <mode>    Override permission mode
        \\  --output-format <format>    Output format (text, json)
        \\  --resume <session>          Resume a session
        \\
        \\REPL Commands:
        \\  /help                       Show available commands
        \\  /status                     Show session status
        \\  /model                      Show current model
        \\  /model <name>               Change model
        \\  /clear                      Clear conversation history
        \\  /exit                       Exit the REPL
        \\
        \\Permission Modes:
        \\  read-only          Only read operations allowed
        \\  workspace-write    Read + write within workspace
        \\  danger-full-access All operations allowed
        \\
        \\Environment Variables:
        \\  ZIK_API_KEY     Anthropic API key
        \\  OPENAI_API_KEY        OpenAI-compatible API key
        \\  OPENAI_BASE_URL       OpenAI-compatible endpoint
        \\  XAI_API_KEY           xAI/Grok API key
        \\
    , .{});
}
