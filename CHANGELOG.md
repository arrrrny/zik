# Changelog

All notable changes to zik will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- **55+ slash commands** — full CLI command suite for coding agent workflows
- **Real-time streaming** — token-by-token display via popen + POSIX pipe
- **Configurable models** — default `minimax-m2.5`, supports `stepfun`, any proxy model via `ZIK_MODEL` env var
- **Auto-display commands** — type `/` to instantly show all available commands
- **Command filtering & autocomplete** — type `/co` then Tab to filter and autocomplete
- **Three themes** — `dark` (default), `light`, `minimal` with colored prompts and highlighted commands
- **Session persistence** — auto-saves to `.claw/sessions/`, resume with `/resume` or `--resume`
- **Auto-detect build/test** — `/build` and `/test` detect Zig, Cargo, npm, Go projects
- **Git integration** — `/diff`, `/git <args>`, `/commit <msg>`
- **System diagnostics** — `/diagnostics` checks API, project type, git status
- **Token tracking** — `/cost`, `/usage`, `/tokens` with cost estimates
- **16 AI tools** — read_file, write_file, edit_file, grep, glob, bash, TodoWrite, WebFetch, WebSearch, AskUserQuestion, Config, Sleep, Brief, StructuredOutput, Skill

### Changed
- Default model from `claude-sonnet-4-6` to `minimax-m2.5` (free, generous credits)
- Slash command count from 5 to 67

### Technical
- 40 source files, ~4,850 lines of Zig
- 1.6MB binary (target: <15MB)
- Zero external dependencies
- Compatible with Anthropic-compatible proxy servers
- All tests passing
