# zik — AI Coding Agent CLI

A blazing-fast, zero-dependency AI coding assistant written in Zig. Connects to any Anthropic-compatible API proxy for real-time code assistance.

```
  ___      _ _
 / __\___ _| | |_
 \__ \ _\/ | | __|
 / __/\ \ | | |_
 \____\/ \_|\_\\__|
        /__/
```

## Quick Start

```bash
# Install (add to PATH)
cp zig-out/bin/zik /usr/local/bin/

# Run
zik                           # Start REPL
zik prompt "explain my code"  # One-shot prompt
```

## Configuration

### API Setup (Required)

Set your API key for the proxy server you're using:

```bash
export ANTHROPIC_AUTH_TOKEN="your-token-here"
export ANTHROPIC_BASE_URL="http://your-proxy:port"
```

### Model Selection

Models are configurable via environment variables or CLI flags:

```bash
# Default: minimax-m2.5 (free, generous credits)
zik prompt "hello"

# Override via CLI
zik --model stepfun prompt "hello"

# Override via env var
export ZIK_MODEL=stepfun
zik prompt "hello"
```

**Model fallback chain**: `ZIK_MODEL` → `ANTHROPIC_DEFAULT_SONNET_MODEL` → `ANTHROPIC_DEFAULT_MODEL` → `minimax-m2.5`

### Tested Models

| Model | Status | Notes |
|-------|--------|-------|
| `minimax-m2.5` | ✅ | Default, free credits, fast |
| `stepfun` | ✅ | Maps to step-3.5-flash:free |

## REPL Usage

Start the interactive REPL:

```bash
zik
```

### Prompt

```
zik> <type your message here>
```

### Slash Commands

Type `/` to see all available commands. Type a prefix like `/co` then press **Tab** to filter and autocomplete.

#### Session Management

| Command | Description |
|---------|-------------|
| `/help` | Show all commands |
| `/exit`, `/quit` | Exit REPL (auto-saves session) |
| `/resume` | Resume latest session |
| `/resume <id>` | Resume specific session |
| `/clear` | Clear conversation history |
| `/reset` | Reset session state |
| `/session` | Show session details |
| `/export` | Export session to JSON |

#### Model & Configuration

| Command | Description |
|---------|-------------|
| `/model` | Show current model |
| `/model <name>` | Change model |
| `/config` | Show effective configuration |
| `/permissions` | Permission mode status |
| `/theme` | Show current theme |
| `/theme dark` | Dark theme (colored) |
| `/theme light` | Light theme (colored) |
| `/theme minimal` | No colors |
| `/cost` | Token usage and cost |
| `/usage` | Token statistics |
| `/tokens` | Detailed token breakdown |

#### Development Workflow

| Command | Description |
|---------|-------------|
| `/build` | Auto-detect and run build (zig/cargo/npm/go) |
| `/test` | Auto-detect and run tests |
| `/format` | Auto-detect and run formatter |
| `/lint` | Auto-detect and run linter |
| `/run <cmd>` | Execute any shell command |
| `/git <args>` | Run git commands |
| `/commit <msg>` | Stage and commit all changes |
| `/diff` | Show git workspace changes |

#### Code Assistance

| Command | Description |
|---------|-------------|
| `/files` | List workspace files |
| `/search` | Search code for pattern |
| `/explain` | Explain selected code |
| `/fix` | Fix errors in workspace |
| `/refactor` | Refactor code |
| `/review` | Code review |
| `/context` | Show current context |
| `/history` | Message history |
| `/compact` | Compact conversation |
| `/summary` | Conversation summary |

#### Diagnostics & System

| Command | Description |
|---------|-------------|
| `/doctor` | Health check |
| `/diagnostics` | Full system diagnostics |
| `/version` | Version info |
| `/init` | Workspace initialization |
| `/log` | Log viewing |
| `/profile` | Profile configuration |

#### Advanced

| Command | Description |
|---------|-------------|
| `/stop` | Stop current operation |
| `/retry` | Retry last operation |
| `/undo` | Undo last operation |
| `/plan` | Enter planning mode |
| `/mcp` | MCP server management |
| `/plugin` | Plugin management |
| `/skills` | Skills management |
| `/sandbox` | Sandbox mode |
| `/output-style` | Response formatting |
| `/max-tokens` | Token limit |
| `/temperature` | Temperature control |
| `/effort` | Effort mode |
| `/vim` | Vim mode toggle |

### Command Filtering & Autocomplete

Type a slash command prefix and press **Tab**:

```
zik> /co<TAB>
  Matching Commands:
  /cost        Token usage and estimated cost
  /config      Show effective configuration
  /compact     Compact conversation (keep last 10)
  /context     Show current context/state
  /commit      Stage and commit all changes
zik> /co
```

If only one match, Tab autocompletes it:

```
zik> /cost<TAB>
zik> /cost
```

### Themes

Three built-in themes with colored prompts and highlighted commands:

```
/theme dark      # Bold cyan prompt, yellow commands (default)
/theme light     # Bold blue prompt, magenta commands
/theme minimal   # Plain text, no ANSI codes
```

## CLI Options

```
zik [OPTIONS]              Launch interactive REPL
zik prompt "<message>"     One-shot prompt
zik "<message>"            Shorthand prompt

Options:
  -h, --help                  Show help
  -V, --version               Show version
  --acp                       Run as ACP server
  -m, --model <model>         Override model
  --permission-mode <mode>    Override permission mode
  --output-format <format>    Output format (text, json)
  --resume <session>          Resume a session
```

## Session Persistence

Sessions are automatically saved to `.claw/sessions/` on exit:

```bash
# Resume latest
zik --resume latest

# Resume specific session
zik --resume <session-id>
```

## Architecture

- **Zero external dependencies** — pure Zig using only stdlib
- **Real-time streaming** — token-by-token via popen + POSIX pipe
- **~1.6MB binary** — well under 15MB target
- **40 source files, ~4,850 LOC**
- **16 AI tools** — file ops, search, bash, web, and more
- **67 slash commands** — complete CLI command suite

## Building from Source

```bash
zig build                    # Build debug
zig build -Doptimize=ReleaseSafe  # Build release
zig build test               # Run tests
./zig-out/bin/zik            # Run
```

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for all changes.

## License

Proprietary.
